import CryptoKit
import Foundation
import NIOSSL

struct TLSIdentityBundle: @unchecked Sendable {
    let sslContext: NIOSSLContext
    let certFingerprintHex: String

    var shortFingerprint: String {
        let prefix = certFingerprintHex.prefix(12).uppercased()
        return stride(from: 0, to: prefix.count, by: 4).map { idx in
            let start = prefix.index(prefix.startIndex, offsetBy: idx)
            let end = prefix.index(start, offsetBy: min(4, prefix.count - idx))
            return String(prefix[start..<end])
        }.joined(separator: ":")
    }
}

enum TLSIdentityManager {
    static func loadOrCreateIdentity() throws -> TLSIdentityBundle {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let tlsDir = appSupport.appendingPathComponent("DeskDrop/tls", isDirectory: true)
        try FileManager.default.createDirectory(at: tlsDir, withIntermediateDirectories: true)

        let keyURL = tlsDir.appendingPathComponent("server.key.pem")
        let certURL = tlsDir.appendingPathComponent("server.cert.pem")

        if !FileManager.default.fileExists(atPath: keyURL.path) ||
            !FileManager.default.fileExists(atPath: certURL.path) {
            try generateSelfSignedPEM(keyURL: keyURL, certURL: certURL)
        }

        let certs = try NIOSSLCertificate.fromPEMFile(certURL.path)
        guard let cert = certs.first else {
            throw NSError(domain: "DeskDrop.TLS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty TLS certificate"])
        }
        let privateKey = try NIOSSLPrivateKey(file: keyURL.path, format: .pem)
        let config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(cert)],
            privateKey: .privateKey(privateKey)
        )
        let sslContext = try NIOSSLContext(configuration: config)

        let derBytes = try cert.toDERBytes()
        let digest = SHA256.hash(data: Data(derBytes))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return TLSIdentityBundle(sslContext: sslContext, certFingerprintHex: hex)
    }

    private static func generateSelfSignedPEM(keyURL: URL, certURL: URL) throws {
        let hostName = Host.current().localizedName ?? "DeskDropMac"

        let genReq = Process()
        genReq.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        genReq.arguments = [
            "req", "-x509",
            "-newkey", "rsa:2048",
            "-keyout", keyURL.path,
            "-out", certURL.path,
            "-days", "3650",
            "-nodes",
            "-subj", "/CN=DeskDrop (\(hostName))"
        ]
        let pipe = Pipe()
        genReq.standardError = pipe
        genReq.standardOutput = pipe
        try genReq.run()
        genReq.waitUntilExit()
        if genReq.terminationStatus != 0 {
            let errData = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? "openssl failed"
            throw NSError(domain: "DeskDrop.TLS", code: Int(genReq.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg])
        }

        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    }
}
