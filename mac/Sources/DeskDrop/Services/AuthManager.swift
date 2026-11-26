import CryptoKit
import Foundation
import Security

struct PairedDevice: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let tokenHex: String
    let pairedAt: Date
}

struct ActivePairingSession: Sendable {
    let code: String
    let expiresAt: Date
    var failedAttempts: Int = 0
}

final class AuthManager: @unchecked Sendable {
    private let lock = NSLock()
    private let storageURL: URL
    private var devices: [String: PairedDevice] = [:]
    private var activePairing: ActivePairingSession?
    private var seenNonces: [String: Date] = [:]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("DeskDrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("paired_devices.json")
        loadDevices()
    }

    func listDevices() -> [PairedDevice] {
        lock.lock()
        defer { lock.unlock() }
        return devices.values.sorted { $0.pairedAt > $1.pairedAt }
    }

    func revokeDevice(id: String) {
        lock.lock()
        devices.removeValue(forKey: id)
        saveDevicesLocked()
        lock.unlock()
    }

    func startPairingSession(ttlSeconds: TimeInterval = 60) -> ActivePairingSession {
        let code = generateSixDigitCode()
        let session = ActivePairingSession(code: code, expiresAt: Date().addingTimeInterval(ttlSeconds))
        lock.lock()
        activePairing = session
        lock.unlock()
        return session
    }

    func stopPairingSession() {
        lock.lock()
        activePairing = nil
        lock.unlock()
    }

    func currentPairingSession() -> ActivePairingSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = activePairing, session.expiresAt > Date() else {
            activePairing = nil
            return nil
        }
        return session
    }

    enum PairAttemptResult {
        case success(PairedDevice)
        case invalidCode(remainingAttempts: Int)
        case notInPairingMode
    }

    func completePairing(code: String, deviceName: String) -> PairAttemptResult {
        lock.lock()
        defer { lock.unlock() }

        guard var session = activePairing, session.expiresAt > Date() else {
            activePairing = nil
            return .notInPairingMode
        }

        let normalizedInput = code.filter(\.isNumber)
        if !constantTimeEquals(normalizedInput, session.code) {
            session.failedAttempts += 1
            if session.failedAttempts >= 5 {
                activePairing = nil
                return .invalidCode(remainingAttempts: 0)
            }
            activePairing = session
            return .invalidCode(remainingAttempts: 5 - session.failedAttempts)
        }

        let deviceId = UUID().uuidString.lowercased()
        let tokenHex = randomHex(byteCount: 32)
        let cleanName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = PairedDevice(
            id: deviceId,
            name: cleanName.isEmpty ? "Android Phone" : String(cleanName.prefix(40)),
            tokenHex: tokenHex,
            pairedAt: Date()
        )
        devices[device.id] = device
        activePairing = nil
        saveDevicesLocked()
        return .success(device)
    }

    func verifyRequest(
        method: String,
        path: String,
        deviceId: String?,
        timestampHeader: String?,
        nonce: String?,
        signatureHex: String?
    ) -> PairedDevice? {
        guard let deviceId,
              let timestampHeader,
              let ts = TimeInterval(timestampHeader),
              let nonce, nonce.count >= 16, nonce.count <= 128,
              let signatureHex,
              let sigData = Data(hexString: signatureHex) else {
            return nil
        }

        let now = Date()
        if abs(now.timeIntervalSince1970 - ts) > 30 {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        guard let device = devices[deviceId],
              let keyData = Data(hexString: device.tokenHex) else {
            return nil
        }

        // Prune expired nonces and reject replays
        seenNonces = seenNonces.filter { now.timeIntervalSince($0.value) <= 60 }
        let nonceKey = "\(deviceId):\(nonce)"
        if seenNonces[nonceKey] != nil {
            return nil
        }

        let message = "\(method.uppercased())\n\(path)\n\(timestampHeader)\n\(nonce)"
        let key = SymmetricKey(data: keyData)
        guard HMAC<SHA256>.isValidAuthenticationCode(sigData, authenticating: Data(message.utf8), using: key) else {
            return nil
        }

        seenNonces[nonceKey] = now
        return device
    }

    private func loadDevices() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let list = try? decoder.decode([PairedDevice].self, from: data) {
            devices = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        }
    }

    private func saveDevicesLocked() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Array(devices.values)) {
            try? data.write(to: storageURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        }
    }

    private func generateSixDigitCode() -> String {
        var val: UInt32 = 0
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &val)
        return String(format: "%06d", val % 1_000_000)
    }

    private func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }
}

private extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(bytes)
    }
}
