import AppKit
import Foundation
import UserNotifications

@MainActor
final class DropStore: NSObject, ObservableObject {
    @Published var items: [DropItem] = []
    @Published var listeningPort: UInt16?
    @Published var localIP: String?
    @Published var serverError: String?
    @Published var isListening = false
    @Published var statusNote: String?

    @Published var pairedDevices: [PairedDevice] = []
    @Published var activePairingCode: String?
    @Published var pairingSecondsLeft: Int = 0
    @Published var pairingQRImage: NSImage?
    @Published var shortFingerprint: String = ""

    @Published var autoCopyToClipboard: Bool {
        didSet { UserDefaults.standard.set(autoCopyToClipboard, forKey: "autoCopyToClipboard") }
    }
    @Published var pauseOnLockSleep: Bool {
        didSet {
            UserDefaults.standard.set(pauseOnLockSleep, forKey: "pauseOnLockSleep")
            evaluateLifecycle()
        }
    }
    @Published var trustedWiFiOnly: Bool {
        didSet {
            UserDefaults.standard.set(trustedWiFiOnly, forKey: "trustedWiFiOnly")
            if trustedWiFiOnly {
                wifiMonitor.requestLocationAccessIfNeeded()
            }
            evaluateLifecycle()
        }
    }
    @Published var trustedSSIDs: [String] {
        didSet {
            UserDefaults.standard.set(trustedSSIDs, forKey: "trustedSSIDs")
            evaluateLifecycle()
        }
    }

    let storage = DropStorage()
    let wifiMonitor = WiFiMonitor()
    private let authManager = AuthManager()
    private var tlsBundle: TLSIdentityBundle?
    private var server: DropServer?
    private var pairingTimerTask: Task<Void, Never>?

    private var manuallyStopped = false
    private var manualStartOverride = false
    private var isScreenLocked = false
    private var isSleeping = false
    private var lastObservedSSID: String?

    private static let notificationCategoryId = "DESKDROP_ITEM"
    private static let actionCopy = "ACTION_COPY"
    private static let actionCopyPath = "ACTION_COPY_PATH"
    private static let actionReveal = "ACTION_REVEAL"

    override init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "autoCopyToClipboard") == nil {
            defaults.set(true, forKey: "autoCopyToClipboard")
        }
        if defaults.object(forKey: "pauseOnLockSleep") == nil {
            defaults.set(true, forKey: "pauseOnLockSleep")
        }
        self.autoCopyToClipboard = defaults.bool(forKey: "autoCopyToClipboard")
        self.pauseOnLockSleep = defaults.bool(forKey: "pauseOnLockSleep")
        self.trustedWiFiOnly = defaults.bool(forKey: "trustedWiFiOnly")
        self.trustedSSIDs = defaults.stringArray(forKey: "trustedSSIDs") ?? []
        super.init()

        self.items = storage.loadHistory()
        self.pairedDevices = authManager.listDevices()

        do {
            let bundle = try TLSIdentityManager.loadOrCreateIdentity()
            self.tlsBundle = bundle
            self.shortFingerprint = bundle.shortFingerprint
        } catch {
            self.serverError = "TLS setup failed: \(error.localizedDescription)"
        }

        configureNotifications()
        observeLockAndSleep()
        wifiMonitor.onNetworkChange = { [weak self] in
            guard let self else { return }
            self.localIP = NetworkUtils.localIPv4Addresses().first
            if self.wifiMonitor.currentSSID != self.lastObservedSSID {
                self.lastObservedSSID = self.wifiMonitor.currentSSID
                self.manualStartOverride = false
            }
            self.evaluateLifecycle()
            if self.isListening {
                self.server?.republishBonjour()
            }
        }
        self.localIP = NetworkUtils.localIPv4Addresses().first
        self.lastObservedSSID = wifiMonitor.currentSSID
        evaluateLifecycle()
    }

    func toggleListening() {
        if isListening {
            manuallyStopped = true
            manualStartOverride = false
            stopServer(reason: "Stopped manually")
        } else {
            manuallyStopped = false
            manualStartOverride = true
            startServerIfPossible()
        }
    }

    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    func startPairing() {
        if !isListening {
            manuallyStopped = false
            startServerIfPossible()
        }

        let session = authManager.startPairingSession(ttlSeconds: 60)
        activePairingCode = session.code
        pairingSecondsLeft = 60
        updatePairingQR(code: session.code)

        pairingTimerTask?.cancel()
        pairingTimerTask = Task { @MainActor [weak self] in
            while let self, let active = self.authManager.currentPairingSession() {
                let left = max(0, Int(ceil(active.expiresAt.timeIntervalSinceNow)))
                self.pairingSecondsLeft = left
                if left == 0 { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            self.stopPairing()
        }
    }

    func stopPairing() {
        pairingTimerTask?.cancel()
        pairingTimerTask = nil
        authManager.stopPairingSession()
        activePairingCode = nil
        pairingSecondsLeft = 0
        pairingQRImage = nil
    }

    func revokeDevice(_ device: PairedDevice) {
        authManager.revokeDevice(id: device.id)
        pairedDevices = authManager.listDevices()
    }

    func trustCurrentWiFi() {
        wifiMonitor.requestLocationAccessIfNeeded()
        wifiMonitor.refreshSSID()
        guard let ssid = wifiMonitor.currentSSID, !ssid.isEmpty else { return }
        if !trustedSSIDs.contains(ssid) {
            trustedSSIDs.append(ssid)
        }
    }

    func removeTrustedSSID(_ ssid: String) {
        trustedSSIDs.removeAll { $0 == ssid }
    }

    func openReceivedFolder() {
        NSWorkspace.shared.open(storage.receivedDirectory)
    }

    func revealInFinder(_ item: DropItem) {
        guard let path = item.filePath else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyItemContent(_ item: DropItem) {
        switch item.kind {
        case .text:
            if let text = item.textPreview {
                ClipboardManager.copyText(text)
            }
        case .image:
            if let path = item.filePath {
                _ = ClipboardManager.copyImage(at: URL(fileURLWithPath: path))
            }
        case .file:
            if let path = item.filePath {
                ClipboardManager.copyFileURL(URL(fileURLWithPath: path))
            }
        }
    }

    func copyItemPath(_ item: DropItem) {
        if let path = item.filePath {
            ClipboardManager.copyFilePath(path)
        }
    }

    func clearHistory() {
        items.removeAll()
        storage.saveHistory(items)
    }

    private func updatePairingQR(code: String) {
        guard let bundle = tlsBundle else { return }
        let host = NetworkUtils.localIPv4Addresses().first ?? ""
        let port = listeningPort ?? 51234
        let name = Host.current().localizedName ?? "Mac"
        let payload: [String: Any] = [
            "v": 1,
            "h": host,
            "p": Int(port),
            "fp": bundle.certFingerprintHex,
            "c": code,
            "n": name
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let jsonString = String(data: data, encoding: .utf8) {
            pairingQRImage = QRCodeGenerator.generate(from: jsonString, size: 170)
        }
    }

    private func evaluateLifecycle() {
        if manuallyStopped {
            stopServer(reason: "Stopped manually")
            return
        }

        let liveLocked = Self.queryScreenLocked() ?? isScreenLocked
        isScreenLocked = liveLocked

        if pauseOnLockSleep && (isScreenLocked || isSleeping) {
            manualStartOverride = false
            stopServer(reason: "Paused (Mac locked/asleep)")
            return
        }
        if trustedWiFiOnly && !manualStartOverride {
            wifiMonitor.refreshSSID()
            if !wifiMonitor.isOnWiFi {
                stopServer(reason: "Paused (Wi-Fi disconnected)")
                return
            }
            guard let ssid = wifiMonitor.currentSSID, !ssid.isEmpty else {
                stopServer(reason: "Paused (Enable Location to verify Wi-Fi)")
                return
            }
            if !trustedSSIDs.contains(ssid) {
                stopServer(reason: "Paused (Untrusted Wi-Fi: \(ssid))")
                return
            }
        }
        if !isListening || server?.isRunning != true {
            startServerIfPossible()
        }
    }

    private static func queryScreenLocked() -> Bool? {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return nil
        }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool {
            return locked
        }
        if let lockedNum = dict["CGSSessionScreenIsLocked"] as? NSNumber {
            return lockedNum.boolValue
        }
        return false
    }

    private func startServerIfPossible() {
        guard let bundle = tlsBundle else { return }
        statusNote = nil
        serverError = nil
        isListening = true

        if server == nil {
            server = DropServer(
                preferredPort: 51234,
                sslContext: bundle.sslContext,
                shortFingerprint: bundle.shortFingerprint,
                authManager: authManager,
                onStatusChange: { [weak self] port, error in
                    Task { @MainActor [weak self] in
                        self?.listeningPort = port
                        self?.localIP = NetworkUtils.localIPv4Addresses().first
                        self?.serverError = error
                        if let code = self?.activePairingCode {
                            self?.updatePairingQR(code: code)
                        }
                    }
                },
                onPairSuccess: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.pairedDevices = self.authManager.listDevices()
                        self.stopPairing()
                    }
                },
                onReceive: { [weak self] payload in
                    guard let self else { return false }
                    return await self.handleIncoming(payload)
                }
            )
        }
        server?.start()
    }

    private func stopServer(reason: String) {
        stopPairing()
        isListening = false
        listeningPort = nil
        statusNote = reason
        server?.stop()
    }

    private func observeLockAndSleep() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScreenLocked = true
                self?.evaluateLifecycle()
            }
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScreenLocked = false
                self?.evaluateLifecycle()
            }
        }

        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSleeping = true
                self?.evaluateLifecycle()
            }
        }
        wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSleeping = false
                self?.evaluateLifecycle()
            }
        }
    }

    private func handleIncoming(_ payload: DropPayload) async -> Bool {
        switch payload {
        case .text(let text, let senderName):
            let preview = String(text.prefix(4000))
            let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .first ?? "Text snippet"
            let item = DropItem(
                kind: .text,
                title: String(title.prefix(60)),
                textPreview: preview,
                byteCount: text.utf8.count
            )
            if autoCopyToClipboard {
                ClipboardManager.copyText(text)
            }
            let subtitle = autoCopyToClipboard ? "Copied to clipboard" : "Received"
            recordItem(item, notificationTitle: "Text from \(senderName)", notificationSubtitle: subtitle, notificationBody: preview)
            return true

        case .file(let data, let filename, let mimeType, let senderName):
            do {
                let (savedURL, isImage) = try storage.saveFile(
                    data: data,
                    suggestedFilename: filename,
                    mimeType: mimeType
                )
                let kind: DropKind = isImage ? .image : .file
                let item = DropItem(
                    kind: kind,
                    title: savedURL.lastPathComponent,
                    filePath: savedURL.path,
                    byteCount: data.count
                )
                if autoCopyToClipboard {
                    if isImage {
                        _ = ClipboardManager.copyImage(at: savedURL)
                    } else {
                        ClipboardManager.copyFileURL(savedURL)
                    }
                }
                let notifTitle = isImage ? "Image from \(senderName)" : "File from \(senderName)"
                let notifSubtitle = autoCopyToClipboard ? "Copied to clipboard" : "Saved to Received"
                let notifBody = "\(savedURL.lastPathComponent) (\(item.formattedSize))"
                recordItem(item, notificationTitle: notifTitle, notificationSubtitle: notifSubtitle, notificationBody: notifBody)
                return true
            } catch {
                return false
            }
        }
    }

    private func recordItem(_ item: DropItem, notificationTitle: String, notificationSubtitle: String, notificationBody: String) {
        items.insert(item, at: 0)
        if items.count > 30 {
            items = Array(items.prefix(30))
        }
        storage.saveHistory(items)
        postNotification(item: item, title: notificationTitle, subtitle: notificationSubtitle, body: notificationBody)
    }

    private func configureNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let copyAction = UNNotificationAction(identifier: Self.actionCopy, title: "Copy", options: [])
        let copyPathAction = UNNotificationAction(identifier: Self.actionCopyPath, title: "Copy Path", options: [])
        let revealAction = UNNotificationAction(identifier: Self.actionReveal, title: "Show in Finder", options: [.foreground])

        let category = UNNotificationCategory(
            identifier: Self.notificationCategoryId,
            actions: [copyAction, copyPathAction, revealAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotification(item: DropItem, title: String, subtitle: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.notificationCategoryId
        content.userInfo = [
            "kind": item.kind.rawValue,
            "filePath": item.filePath ?? "",
            "text": item.textPreview ?? ""
        ]

        if item.kind == .image, let path = item.filePath {
            let sourceURL = URL(fileURLWithPath: path)
            let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("deskdrop_notif_\(item.id.uuidString).\(ext)")
            try? FileManager.default.copyItem(at: sourceURL, to: tempURL)
            if let attachment = try? UNNotificationAttachment(identifier: item.id.uuidString, url: tempURL) {
                content.attachments = [attachment]
            }
        }

        let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension DropStore: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let kindRaw = userInfo["kind"] as? String ?? ""
        let filePath = userInfo["filePath"] as? String ?? ""
        let text = userInfo["text"] as? String ?? ""
        let actionId = response.actionIdentifier

        Task { @MainActor in
            switch actionId {
            case Self.actionCopy:
                if kindRaw == DropKind.text.rawValue {
                    ClipboardManager.copyText(text)
                } else if kindRaw == DropKind.image.rawValue, !filePath.isEmpty {
                    _ = ClipboardManager.copyImage(at: URL(fileURLWithPath: filePath))
                } else if !filePath.isEmpty {
                    ClipboardManager.copyFileURL(URL(fileURLWithPath: filePath))
                }
            case Self.actionCopyPath:
                if !filePath.isEmpty {
                    ClipboardManager.copyFilePath(filePath)
                }
            case Self.actionReveal, UNNotificationDefaultActionIdentifier:
                if !filePath.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
                }
            default:
                break
            }
            completionHandler()
        }
    }
}
