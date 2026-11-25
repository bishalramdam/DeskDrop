import Foundation
import Network

enum DropPayload: Sendable {
    case text(String)
    case file(data: Data, filename: String?, mimeType: String?)
}

final class DropServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.bishal.DeskDrop.server", qos: .userInitiated)
    private var listener: NWListener?
    private var activeSessions: [ObjectIdentifier: HTTPConnectionSession] = [:]
    private let preferredPort: UInt16
    private let onReceive: @Sendable (DropPayload) async -> Bool
    private let onActivity: @Sendable () -> Void
    private let onStatusChange: @Sendable (UInt16?, String?) -> Void

    init(
        preferredPort: UInt16 = 51234,
        onStatusChange: @escaping @Sendable (UInt16?, String?) -> Void,
        onActivity: @escaping @Sendable () -> Void = {},
        onReceive: @escaping @Sendable (DropPayload) async -> Bool
    ) {
        self.preferredPort = preferredPort
        self.onStatusChange = onStatusChange
        self.onActivity = onActivity
        self.onReceive = onReceive
    }

    func start() {
        stop()
        startListener(port: NWEndpoint.Port(rawValue: preferredPort))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for session in activeSessions.values {
            session.forceClose()
        }
        activeSessions.removeAll()
        onStatusChange(nil, nil)
    }

    private func startListener(port: NWEndpoint.Port?) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let nwListener = try NWListener(using: params, on: port ?? .any)
            let deviceName = Host.current().localizedName ?? "Mac"
            nwListener.service = NWListener.Service(name: deviceName, type: "_deskdrop._tcp")

            nwListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let actualPort = nwListener.port?.rawValue
                    self.onStatusChange(actualPort, nil)
                case .failed(let error):
                    if port != nil {
                        // Preferred port might be busy; fall back to any available port.
                        nwListener.cancel()
                        self.startListener(port: nil)
                    } else {
                        self.onStatusChange(nil, error.localizedDescription)
                    }
                case .cancelled:
                    self.onStatusChange(nil, nil)
                default:
                    break
                }
            }

            nwListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            self.listener = nwListener
            nwListener.start(queue: queue)
        } catch {
            onStatusChange(nil, error.localizedDescription)
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        onActivity()
        connection.start(queue: queue)
        let session = HTTPConnectionSession(
            connection: connection,
            portProvider: { [weak self] in self?.listener?.port?.rawValue ?? self?.preferredPort ?? 51234 },
            onReceive: onReceive
        )
        let id = ObjectIdentifier(session)
        activeSessions[id] = session
        session.onClose = { [weak self] in
            self?.activeSessions.removeValue(forKey: id)
        }
        session.start()
    }
}

private final class HTTPConnectionSession: @unchecked Sendable {
    var onClose: (() -> Void)?

    private let connection: NWConnection
    private let portProvider: () -> UInt16
    private let onReceive: @Sendable (DropPayload) async -> Bool

    private var buffer = Data()
    private var headersParsed = false
    private var method = ""
    private var path = ""
    private var headers: [String: String] = [:]
    private var contentLength = 0
    private var bodyStartIndex = 0
    private var handled = false

    private static let maxBodyBytes = 250 * 1024 * 1024 // 250 MB

    init(
        connection: NWConnection,
        portProvider: @escaping () -> UInt16,
        onReceive: @escaping @Sendable (DropPayload) async -> Bool
    ) {
        self.connection = connection
        self.portProvider = portProvider
        self.onReceive = onReceive
    }

    func start() {
        receiveNextChunk()
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.handled else { return }

            if let data, !data.isEmpty {
                self.buffer.append(data)
            }

            if !self.headersParsed {
                if let range = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                    self.bodyStartIndex = range.upperBound
                    let headerData = self.buffer.subdata(in: 0..<range.lowerBound)
                    guard self.parseHeaders(headerData) else {
                        self.sendResponse(status: "400 Bad Request", body: #"{"error":"Invalid HTTP request"}"#)
                        return
                    }
                    self.headersParsed = true

                    if self.contentLength > Self.maxBodyBytes {
                        self.sendResponse(status: "413 Payload Too Large", body: #"{"error":"Payload too large"}"#)
                        return
                    }

                    if self.headers["expect"]?.lowercased() == "100-continue" {
                        self.connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                    }
                }
            }

            if self.headersParsed {
                let receivedBodyCount = self.buffer.count - self.bodyStartIndex
                if receivedBodyCount >= self.contentLength {
                    self.handled = true
                    let bodyEnd = self.bodyStartIndex + self.contentLength
                    let bodyData = self.buffer.subdata(in: self.bodyStartIndex..<bodyEnd)
                    self.processRequest(body: bodyData)
                    return
                }
            }

            if error != nil || isComplete {
                self.handled = true
                if self.headersParsed && self.contentLength == 0 {
                    self.processRequest(body: Data())
                } else {
                    self.close()
                }
                return
            }

            self.receiveNextChunk()
        }
    }

    private func parseHeaders(_ data: Data) -> Bool {
        guard let raw = String(data: data, encoding: .utf8) else { return false }
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return false }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return false }

        method = String(parts[0]).uppercased()
        path = String(parts[1]).components(separatedBy: "?").first ?? String(parts[1])

        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        contentLength = Int(headers["content-length"] ?? "0") ?? 0
        return true
    }

    private func processRequest(body: Data) {
        switch (method, path) {
        case ("GET", "/ping"):
            let deviceName = Host.current().localizedName ?? "Mac"
            let escapedName = deviceName
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let json = #"{"app":"DeskDrop","name":"\#(escapedName)","port":\#(portProvider()),"version":"1.0.0"}"#
            sendResponse(status: "200 OK", body: json)

        case ("POST", "/drop/text"):
            let text: String?
            if headers["content-type"]?.lowercased().contains("application/json") == true,
               let jsonObj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let extracted = jsonObj["text"] as? String {
                text = extracted
            } else {
                text = String(data: body, encoding: .utf8)
            }

            guard let text, !text.isEmpty else {
                sendResponse(status: "400 Bad Request", body: #"{"error":"Empty text payload"}"#)
                return
            }

            Task {
                let ok = await onReceive(.text(text))
                if ok {
                    sendResponse(status: "200 OK", body: #"{"ok":true,"kind":"text"}"#)
                } else {
                    sendResponse(status: "500 Internal Server Error", body: #"{"ok":false}"#)
                }
            }

        case ("POST", "/drop/file"):
            guard !body.isEmpty else {
                sendResponse(status: "400 Bad Request", body: #"{"error":"Empty file payload"}"#)
                return
            }
            let rawName = headers["x-filename"]?.removingPercentEncoding
            let mimeType = headers["content-type"]
            Task {
                let ok = await onReceive(.file(data: body, filename: rawName, mimeType: mimeType))
                if ok {
                    sendResponse(status: "200 OK", body: #"{"ok":true,"kind":"file"}"#)
                } else {
                    sendResponse(status: "500 Internal Server Error", body: #"{"ok":false}"#)
                }
            }

        default:
            sendResponse(status: "404 Not Found", body: #"{"error":"Not found"}"#)
        }
    }

    private func sendResponse(status: String, body: String) {
        let bodyData = Data(body.utf8)
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var packet = Data(header.utf8)
        packet.append(bodyData)

        connection.send(content: packet, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    func forceClose() {
        handled = true
        close()
    }

    private func close() {
        connection.cancel()
        let callback = onClose
        onClose = nil
        callback?()
    }
}
