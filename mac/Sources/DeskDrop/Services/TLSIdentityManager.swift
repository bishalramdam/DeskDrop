import CryptoKit
import Foundation
import Security

struct TLSIdentityBundle {
    let identity: SecIdentity
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
    private static let p12Passphrase = "deskdrop-local-tls"

    static func loadOrCreateIdentity() throws -> TLSIdentityBundle {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let tlsDir = appSupport.appendingPathComponent("DeskDrop/tls", isDirectory: true)
        try FileManager.default.createDirectory(at: tlsDir, withIntermediateDirectories: true)

        let keyURL = tlsDir.appendingPathComponent("server.key.pem")
        let certURL = tlsDir.appendingPathComponent("server.cert.pem")
        let p12URL = tlsDir.appendingPathComponent("server.p12")

        if !FileManager.default.fileExists(atPath: p12URL.path) {
            try generateSelfSignedP12(keyURL: keyURL, certURL: certURL, p12URL: p12URL)
        }

        let p12Data = try Data(contentsOf: p12URL)
        if let bundle = importP12(data: p12Data) {
            return bundle
        }

        // Regenerate once if existing p12 is corrupted or unreadable.
        try? FileManager.default.removeItem(at: p12URL)
        try generateSelfSignedP12(keyURL: keyURL, certURL: certURL, p12URL: p12URL)
        let freshData = try Data(contentsOf: p12URL)
        guard let freshBundle = importP12(data: freshData) else {
            throw NSError(domain: "DeskDrop.TLS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to load TLS identity"])
        }
        return freshBundle
    }

    private static func generateSelfSignedP12(keyURL: URL, certURL: URL, p12URL: URL) throws {
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
        try runProcess(genReq)

        let exportP12 = Process()
        exportP12.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        exportP12.arguments = [
            "pkcs12", "-export",
            "-inkey", keyURL.path,
            "-in", certURL.path,
            "-out", p12URL.path,
            "-passout", "pass:\(p12Passphrase)"
        ]
        try runProcess(exportP12)

        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12URL.path)
    }

    private static func runProcess(_ process: Process) throws {
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errData = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? "openssl failed"
            throw NSError(domain: "DeskDrop.TLS", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private static func importP12(data: Data) -> TLSIdentityBundle? {
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: p12Passphrase]
        _ = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard let dicts = items as? [[String: Any]],
              let first = dicts.first,
              let identityObj = first[kSecImportItemIdentity as String] else {
            return nil
        }
        let identity = identityObj as! SecIdentity

        var certRef: SecCertificate?
        SecIdentityCopyCertificate(identity, &certRef)
        guard let cert = certRef else { return nil }
        let derData = SecCertificateCopyData(cert) as Data
        let digest = SHA256.hash(data: derData)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return TLSIdentityBundle(identity: identity, certFingerprintHex: hex)
    }
}
