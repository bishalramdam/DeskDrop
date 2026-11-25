import AppKit
import Foundation
import UserNotifications

@MainActor
final class DropStore: ObservableObject {
    @Published var items: [DropItem] = []
    @Published var listeningPort: UInt16?
    @Published var serverError: String?
    @Published var autoCopyToClipboard: Bool {
        didSet { UserDefaults.standard.set(autoCopyToClipboard, forKey: "autoCopyToClipboard") }
    }
    @Published var bleBeaconEnabled: Bool {
        didSet {
            UserDefaults.standard.set(bleBeaconEnabled, forKey: "bleBeaconEnabled")
            if bleBeaconEnabled {
                bleBeacon.start()
            } else {
                bleBeacon.stop()
            }
        }
    }

    let storage = DropStorage()
    private let bleBeacon = BLEBeacon()
    private var server: DropServer?

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "autoCopyToClipboard") == nil {
            defaults.set(true, forKey: "autoCopyToClipboard")
        }
        self.autoCopyToClipboard = defaults.bool(forKey: "autoCopyToClipboard")
        self.bleBeaconEnabled = defaults.bool(forKey: "bleBeaconEnabled")
        self.items = storage.loadHistory()

        requestNotificationPermission()
        startServer()
        if bleBeaconEnabled {
            bleBeacon.start()
        }
    }

    func startServer() {
        let srv = DropServer(
            preferredPort: 51234,
            onStatusChange: { [weak self] port, error in
                Task { @MainActor [weak self] in
                    self?.listeningPort = port
                    self?.serverError = error
                }
            },
            onReceive: { [weak self] payload in
                guard let self else { return false }
                return await self.handleIncoming(payload)
            }
        )
        self.server = srv
        srv.start()
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

    private func handleIncoming(_ payload: DropPayload) async -> Bool {
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
            recordItem(item, notificationBody: "Copied text to clipboard")
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
                let subtitle = isImage
                    ? "Screenshot/Image saved & copied"
                    : "Saved \(savedURL.lastPathComponent)"
                recordItem(item, notificationBody: subtitle)
                return true
            } catch {
                return false
            }
        }
    }

    private func recordItem(_ item: DropItem, notificationBody: String) {
        items.insert(item, at: 0)
        if items.count > 30 {
            items = Array(items.prefix(30))
        }
        storage.saveHistory(items)
        NSSound(named: "Glass")?.play()
        postNotification(title: "DeskDrop", body: notificationBody)
    }

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
