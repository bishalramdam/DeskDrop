import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}

@main
struct DeskDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DropStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            Image(nsImage: makeMenuBarIcon(isListening: store.isListening))
        }
        .menuBarExtraStyle(.window)
    }

    private func makeMenuBarIcon(isListening: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let alpha: CGFloat = isListening ? 1.0 : 0.45

            // Back card (bottom-right)
            let backRect = CGRect(x: 6.5, y: 2.5, width: 9.0, height: 8.0)
            let backPath = CGPath(roundedRect: backRect, cornerWidth: 2.2, cornerHeight: 2.2, transform: nil)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(1.5)
            ctx.addPath(backPath)
            ctx.strokePath()

            // Clear overlap gap around front card
            let frontRect = CGRect(x: 2.5, y: 6.5, width: 8.5, height: 9.0)
            let gapPath = CGPath(
                roundedRect: frontRect.insetBy(dx: -1.4, dy: -1.4),
                cornerWidth: 3.0,
                cornerHeight: 3.0,
                transform: nil
            )
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.addPath(gapPath)
            ctx.fillPath()
            ctx.restoreGState()

            // Front card (top-left, solid)
            let frontPath = CGPath(roundedRect: frontRect, cornerWidth: 2.2, cornerHeight: 2.2, transform: nil)
            ctx.setFillColor(NSColor.black.withAlphaComponent(alpha).cgColor)
            ctx.addPath(frontPath)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
