import AppKit
import Foundation
import UserNotifications

@MainActor
final class DropStore: NSObject, ObservableObject {
    @Published var items: [DropItem] = []
    @Published var listeningPort: UInt16?
    @Published var serverError: String?
    @Published var isListening = false
    @Published var statusNote: String?

    @Published var autoCopyToClipboard: Bool {
        didSet { UserDefaults.standard.set(autoCopyToClipboard, forKey: "autoCopyToClipboard") }
    }
    @Published var bleBeaconEnabled: Bool {
        didSet {
            UserDefaults.standard.set(bleBeaconEnabled, forKey: "bleBeaconEnabled")
            if bleBeaconEnabled && isListening {
                bleBeacon.start()
            } else {
                bleBeacon.stop()
            }
        }
    }
    @Published var autoStopOnIdle: Bool {
        didSet {
            UserDefaults.standard.set(autoStopOnIdle, forKey: "autoStopOnIdle")
            if autoStopOnIdle && isListening {
                resetIdleTimer()
            } else {
                idleTimerTask?.cancel()
            }
        }
    }

    let storage = DropStorage()
    private let bleBeacon = BLEBeacon()
    private var server: DropServer?
    private var idleTimerTask: Task<Void, Never>?

    private static let idleTimeoutSeconds: UInt64 = 120 // 2 minutes
    private static let notificationCategoryId = "DESKDROP_ITEM"
    private static let actionCopy = "ACTION_COPY"
    private static let actionCopyPath = "ACTION_COPY_PATH"
    private static let actionReveal = "ACTION_REVEAL"

    override init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "autoCopyToClipboard") == nil {
            defaults.set(true, forKey: "autoCopyToClipboard")
        }
        if defaults.object(forKey: "autoStopOnIdle") == nil {
            defaults.set(true, forKey: "autoStopOnIdle")
        }
        self.autoCopyToClipboard = defaults.bool(forKey: "autoCopyToClipboard")
        self.bleBeaconEnabled = defaults.bool(forKey: "bleBeaconEnabled")
        self.autoStopOnIdle = defaults.bool(forKey: "autoStopOnIdle")
        super.init()

        self.items = storage.loadHistory()
        configureNotifications()
        startListening()
    }

    func toggleListening() {
        if isListening {
            stopListening(reason: "Stopped")
        } else {
            startListening()
        }
    }

    func startListening() {
        statusNote = nil
        serverError = nil
        isListening = true

        if server == nil {
            server = DropServer(
                preferredPort: 51234,
                onStatusChange: { [weak self] port, error in
                    Task { @MainActor [weak self] in
                        self?.listeningPort = port
                        self?.serverError = error
                    }
                },
                onActivity: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.resetIdleTimer()
                    }
                },
                onReceive: { [weak self] payload in
                    guard let self else { return false }
                    return await self.handleIncoming(payload)
                }
            )
        }

        server?.start()
        if bleBeaconEnabled {
            bleBeacon.start()
        }
        resetIdleTimer()
    }

    func stopListening(reason: String = "Stopped") {
        idleTimerTask?.cancel()
        idleTimerTask = nil
        isListening = false
        listeningPort = nil
        statusNote = reason
        server?.stop()
        bleBeacon.stop()
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

    private func resetIdleTimer() {
        idleTimerTask?.cancel()
        guard isListening, autoStopOnIdle else { return }
        idleTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleTimeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.isListening, self.autoStopOnIdle else { return }
            self.stopListening(reason: "Auto-stopped after 2m inactivity")
        }
    }

    private func handleIncoming(_ payload: DropPayload) async -> Bool {
        resetIdleTimer()
        switch payload {
        case .text(let text):
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
            recordItem(item, notificationTitle: "Text Received", notificationBody: preview)
            return true

        case .file(let data, let filename, let mimeType):
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
                let notifTitle = isImage ? "Screenshot / Image" : "File Received"
                let notifBody = "\(savedURL.lastPathComponent) (\(item.formattedSize))" +
                    (autoCopyToClipboard ? " • Copied" : "")
                recordItem(item, notificationTitle: notifTitle, notificationBody: notifBody)
                return true
            } catch {
                return false
            }
        }
    }

    private func recordItem(_ item: DropItem, notificationTitle: String, notificationBody: String) {
        items.insert(item, at: 0)
        if items.count > 30 {
            items = Array(items.prefix(30))
        }
        storage.saveHistory(items)
        postNotification(item: item, title: notificationTitle, body: notificationBody)
    }

    private func configureNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let copyAction = UNNotificationAction(
            identifier: Self.actionCopy,
            title: "Copy",
            options: []
        )
        let copyPathAction = UNNotificationAction(
            identifier: Self.actionCopyPath,
            title: "Copy Path",
            options: []
        )
        let revealAction = UNNotificationAction(
            identifier: Self.actionReveal,
            title: "Show in Finder",
            options: [.foreground]
        )

        let category = UNNotificationCategory(
            identifier: Self.notificationCategoryId,
            actions: [copyAction, copyPathAction, revealAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotification(item: DropItem, title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
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
