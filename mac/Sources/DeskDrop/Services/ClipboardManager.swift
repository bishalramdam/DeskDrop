import AppKit
import Foundation

@MainActor
enum ClipboardManager {
    static func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func copyImage(at url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url) else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    static func copyFileURL(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    static func copyFilePath(_ path: String) {
        copyText(path)
    }
}
