import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

enum DropPayload: Sendable {
    case text(String, senderName: String)
    case file(data: Data, filename: String?, mimeType: String?, senderName: String)
}

final class DropServer: @unchecked Sendable {
    private let preferredPort: Int
    private let sslContext: NIOSSLContext
    private let shortFingerprint: String
    private let authManager: AuthManager
    private let onReceive: @Sendable (DropPayload) async -> Bool
    private let onPairSuccess: @Sendable (PairedDevice) -> Void
    private let onStatusChange: @Sendable (UInt16?, String?) -> Void

    private let lock = NSLock()
    private var group: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?
    private var netService: NetService?

    init(
        preferredPort: UInt16 = 51234,
        sslContext: NIOSSLContext,
        shortFingerprint: String,
        authManager: AuthManager,
        onStatusChange: @escaping @Sendable (UInt16?, String?) -> Void,
        onPairSuccess: @escaping @Sendable (PairedDevice) -> Void,
        onReceive: @escaping @Sendable (DropPayload) async -> Bool
    ) {
        self.preferredPort = Int(preferredPort)
        self.sslContext = sslContext
        self.shortFingerprint = shortFingerprint
        self.authManager = authManager
        self.onStatusChange = onStatusChange
        self.onPairSuccess = onPairSuccess
        self.onReceive = onReceive
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return serverChannel != nil
    }

    func start() {
        teardown(notify: false)

        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        lock.lock()
        self.group = elg
        lock.unlock()

        let sslContext = self.sslContext
        let shortFingerprint = self.shortFingerprint
        let authManager = self.authManager
        let onPairSuccess = self.onPairSuccess
        let onReceive = self.onReceive

        let bootstrap = ServerBootstrap(group: elg)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let actualPort = UInt16(channel.localAddress?.port ?? self.preferredPort)
                return channel.pipeline.configureDeskDropPipeline(
                    sslContext: sslContext,
                    port: actualPort,
                    shortFingerprint: shortFingerprint,
                    authManager: authManager,
                    onPairSuccess: onPairSuccess,
                    onReceive: onReceive
                )
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)

        bindWithFallback(bootstrap: bootstrap, group: elg, port: preferredPort)
    }

    private func bindWithFallback(bootstrap: ServerBootstrap, group: MultiThreadedEventLoopGroup, port: Int) {
        bootstrap.bind(host: "0.0.0.0", port: port).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let channel):
                let actualPort = UInt16(channel.localAddress?.port ?? port)
                self.lock.lock()
                self.serverChannel = channel
                self.lock.unlock()
                self.publishBonjour(port: Int32(actualPort))
                self.onStatusChange(actualPort, nil)

            case .failure(let error):
                if port != 0 {
                    self.bindWithFallback(bootstrap: bootstrap, group: group, port: 0)
                } else {
                    self.onStatusChange(nil, error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        teardown(notify: true)
    }

    private func teardown(notify: Bool) {
        lock.lock()
        let ch = serverChannel
        let elg = group
        let svc = netService
        serverChannel = nil
        group = nil
        netService = nil
        lock.unlock()

        if let svc {
            DispatchQueue.main.async {
                svc.stop()
            }
        }
        try? ch?.close().wait()
        try? elg?.syncShutdownGracefully()
        if notify {
            onStatusChange(nil, nil)
        }
    }

    private func publishBonjour(port: Int32) {
        let name = Host.current().localizedName ?? "Mac"
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let existing = self.netService
            self.netService = nil
            self.lock.unlock()
            existing?.stop()

            let service = NetService(domain: "local.", type: "_deskdrop._tcp.", name: name, port: port)
            service.publish()
            self.lock.lock()
            self.netService = service
            self.lock.unlock()
        }
    }

    func republishBonjour() {
        lock.lock()
        let port = serverChannel?.localAddress?.port
        lock.unlock()
        guard let port else { return }
        publishBonjour(port: Int32(port))
    }
}

private final class DeskDropHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let port: UInt16
    private let shortFingerprint: String
    private let authManager: AuthManager
    private let onPairSuccess: @Sendable (PairedDevice) -> Void
    private let onReceive: @Sendable (DropPayload) async -> Bool

    private var requestHead: HTTPRequestHead?
    private var bodyData = Data()
    private static let maxBodyBytes = 250 * 1024 * 1024 // 250 MB

    init(
        port: UInt16,
        shortFingerprint: String,
        authManager: AuthManager,
        onPairSuccess: @escaping @Sendable (PairedDevice) -> Void,
        onReceive: @escaping @Sendable (DropPayload) async -> Bool
    ) {
        self.port = port
        self.shortFingerprint = shortFingerprint
        self.authManager = authManager
        self.onPairSuccess = onPairSuccess
        self.onReceive = onReceive
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            bodyData.removeAll(keepingCapacity: true)
        case .body(var buffer):
            if bodyData.count + buffer.readableBytes > Self.maxBodyBytes {
                sendJSON(context: context, status: .payloadTooLarge, body: #"{"error":"Payload too large"}"#)
                requestHead = nil
                bodyData.removeAll()
                return
            }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                bodyData.append(contentsOf: bytes)
            }
        case .end:
            guard let head = requestHead else { return }
            let payload = bodyData
            requestHead = nil
            bodyData.removeAll()
            handleRequest(context: context, head: head, body: payload)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func handleRequest(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data) {
        let method = head.method.rawValue.uppercased()
        let path = head.uri.components(separatedBy: "?").first ?? head.uri
        let deviceName = Host.current().localizedName ?? "Mac"
        let escapedMacName = jsonEscape(deviceName)

        if method == "GET" && path == "/info" {
            let pairingActive = authManager.currentPairingSession() != nil
            let json = #"{"app":"DeskDrop","name":"\#(escapedMacName)","port":\#(port),"fp":"\#(shortFingerprint)","pairing":\#(pairingActive),"tls":true}"#
            sendJSON(context: context, status: .ok, body: json)
            return
        }

        if method == "POST" && path == "/pair" {
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let code = obj["code"] as? String else {
                sendJSON(context: context, status: .badRequest, body: #"{"error":"Missing pairing code"}"#)
                return
            }
            let phoneName = (obj["deviceName"] as? String) ?? "Android Phone"
            switch authManager.completePairing(code: code, deviceName: phoneName) {
            case .notInPairingMode:
                sendJSON(context: context, status: .forbidden, body: #"{"error":"Mac is not in pairing mode"}"#)
            case .invalidCode(let remaining):
                sendJSON(context: context, status: .unauthorized, body: #"{"error":"Invalid pairing code","remaining":\#(remaining)}"#)
            case .success(let device):
                onPairSuccess(device)
                let escapedToken = jsonEscape(device.tokenHex)
                let escapedId = jsonEscape(device.id)
                let json = #"{"deviceId":"\#(escapedId)","token":"\#(escapedToken)","name":"\#(escapedMacName)"}"#
                sendJSON(context: context, status: .ok, body: json)
            }
            return
        }

        guard let sender = authManager.verifyRequest(
            method: method,
            path: path,
            deviceId: head.headers.first(name: "x-deskdrop-device"),
            timestampHeader: head.headers.first(name: "x-deskdrop-timestamp"),
            nonce: head.headers.first(name: "x-deskdrop-nonce"),
            signatureHex: head.headers.first(name: "x-deskdrop-sig")
        ) else {
            sendJSON(context: context, status: .unauthorized, body: #"{"error":"Unauthorized"}"#)
            return
        }

        switch (method, path) {
        case ("GET", "/ping"):
            let json = #"{"app":"DeskDrop","name":"\#(escapedMacName)","port":\#(port),"tls":true,"version":"2.0.0"}"#
            sendJSON(context: context, status: .ok, body: json)

        case ("POST", "/drop/text"):
            let contentType = head.headers.first(name: "content-type")?.lowercased() ?? ""
            let text: String?
            if contentType.contains("application/json"),
               let jsonObj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let extracted = jsonObj["text"] as? String {
                text = extracted
            } else {
                text = String(data: body, encoding: .utf8)
            }

            guard let text, !text.isEmpty else {
                sendJSON(context: context, status: .badRequest, body: #"{"error":"Empty text payload"}"#)
                return
            }

            let eventLoop = context.eventLoop
            let channel = context.channel
            Task {
                let ok = await onReceive(.text(text, senderName: sender.name))
                eventLoop.execute {
                    self.sendJSONOnChannel(
                        channel: channel,
                        status: ok ? .ok : .internalServerError,
                        body: ok ? #"{"ok":true,"kind":"text"}"# : #"{"ok":false}"#
                    )
                }
            }

        case ("POST", "/drop/file"):
            guard !body.isEmpty else {
                sendJSON(context: context, status: .badRequest, body: #"{"error":"Empty file payload"}"#)
                return
            }
            let rawName = head.headers.first(name: "x-filename")?.removingPercentEncoding
            let mimeType = head.headers.first(name: "content-type")

            let eventLoop = context.eventLoop
            let channel = context.channel
            Task {
                let ok = await onReceive(.file(data: body, filename: rawName, mimeType: mimeType, senderName: sender.name))
                eventLoop.execute {
                    self.sendJSONOnChannel(
                        channel: channel,
                        status: ok ? .ok : .internalServerError,
                        body: ok ? #"{"ok":true,"kind":"file"}"# : #"{"ok":false}"#
                    )
                }
            }

        default:
            sendJSON(context: context, status: .notFound, body: #"{"error":"Not found"}"#)
        }
    }

    private func jsonEscape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func sendJSON(context: ChannelHandlerContext, status: HTTPResponseStatus, body: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(body.utf8.count)")
        headers.add(name: "Connection", value: "close")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buf = context.channel.allocator.buffer(capacity: body.utf8.count)
        buf.writeString(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)

        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    private func sendJSONOnChannel(channel: Channel, status: HTTPResponseStatus, body: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(body.utf8.count)")
        headers.add(name: "Connection", value: "close")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.write(HTTPServerResponsePart.head(head), promise: nil)

        var buf = channel.allocator.buffer(capacity: body.utf8.count)
        buf.writeString(body)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)

        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}

private extension ChannelPipeline {
    func configureDeskDropPipeline(
        sslContext: NIOSSLContext,
        port: UInt16,
        shortFingerprint: String,
        authManager: AuthManager,
        onPairSuccess: @escaping @Sendable (PairedDevice) -> Void,
        onReceive: @escaping @Sendable (DropPayload) async -> Bool
    ) -> EventLoopFuture<Void> {
        let sync = self.syncOperations
        return self.eventLoop.submit {
            try sync.addHandler(NIOSSLServerHandler(context: sslContext))
        }.flatMap {
            self.configureHTTPServerPipeline()
        }.flatMap {
            self.eventLoop.submit {
                try sync.addHandler(
                    DeskDropHTTPHandler(
                        port: port,
                        shortFingerprint: shortFingerprint,
                        authManager: authManager,
                        onPairSuccess: onPairSuccess,
                        onReceive: onReceive
                    )
                )
            }
        }
    }
}
