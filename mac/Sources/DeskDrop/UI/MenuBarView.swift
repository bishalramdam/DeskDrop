import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var store: DropStore
    @State private var copiedId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerSection

            if let code = store.activePairingCode {
                Divider()
                pairingSection(code: code)
            }

            Divider()
            securityControlsSection

            if !store.pairedDevices.isEmpty {
                Divider()
                pairedDevicesSection
            }

            Divider()
            recentDropsSection
            Divider()
            footerSection
        }
        .padding(12)
        .frame(width: 360)
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.isListening ? (store.listeningPort != nil ? Color.green : Color.orange) : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text("DeskDrop")
                        .font(.headline)
                    Image(systemName: "lock.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .help("TLS + HMAC Authenticated")
                }
                if !store.isListening {
                    Text(store.statusNote ?? "Stopped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let port = store.listeningPort {
                    let ips = NetworkUtils.localIPv4Addresses()
                    let addressText = ips.first.map { "\($0):\(port)" } ?? "localhost:\(port)"
                    Text("HTTPS • \(addressText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if let error = store.serverError {
                    Text("Error: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Starting TLS server...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(store.activePairingCode == nil ? "Pair" : "Cancel") {
                if store.activePairingCode == nil {
                    store.startPairing()
                } else {
                    store.stopPairing()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(store.isListening ? "Stop" : "Start") {
                store.toggleListening()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(store.isListening ? .red : .accentColor)
        }
    }

    private func pairingSection(code: String) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("Scan QR or enter code on phone")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(store.pairingSecondsLeft)s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
            }

            if let qr = store.pairingQRImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 140, height: 140)
                    .padding(8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            let spacedCode = "\(code.prefix(3)) \(code.suffix(3))"
            Text(spacedCode)
                .font(.title3.monospacedDigit().weight(.bold))
                .textSelection(.enabled)

            if !store.shortFingerprint.isEmpty {
                Text("Cert: \(store.shortFingerprint)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var securityControlsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Auto-copy to Clipboard", isOn: $store.autoCopyToClipboard)
                .toggleStyle(.switch)
                .controlSize(.small)

            Toggle("Auto-pause when Mac locked/asleep", isOn: $store.pauseOnLockSleep)
                .toggleStyle(.switch)
                .controlSize(.small)

            Toggle("Trusted Wi-Fi Only", isOn: $store.trustedWiFiOnly)
                .toggleStyle(.switch)
                .controlSize(.small)

            if store.trustedWiFiOnly {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if let ssid = store.wifiMonitor.currentSSID {
                            Text("Wi-Fi: \(ssid)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !store.trustedSSIDs.contains(ssid) {
                                Button("Trust \"\(ssid)\"") {
                                    store.trustCurrentWiFi()
                                }
                                .controlSize(.mini)
                            }
                        } else {
                            Text("Enable Location Services for DeskDrop to read Wi-Fi name")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Refresh") {
                                store.wifiMonitor.requestLocationAccessIfNeeded()
                                store.wifiMonitor.refreshSSID()
                            }
                            .controlSize(.mini)
                        }
                    }

                    if !store.trustedSSIDs.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(store.trustedSSIDs, id: \.self) { ssid in
                                    HStack(spacing: 4) {
                                        Text(ssid)
                                            .font(.caption2)
                                        Button {
                                            store.removeTrustedSSID(ssid)
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 8, weight: .bold))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.14))
                                    .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
    }

    private var pairedDevicesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Paired Devices")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            ForEach(store.pairedDevices) { device in
                HStack {
                    Image(systemName: "iphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(device.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button("Revoke") {
                        store.revokeDevice(device)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .foregroundStyle(.red)
                }
            }
        }
    }

    private var recentDropsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent Drops")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !store.items.isEmpty {
                    Button("Clear") {
                        store.clearHistory()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            if store.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(store.pairedDevices.isEmpty
                         ? "Click Pair above to link your Android phone."
                         : "Share a screenshot, photo, text, or file from your phone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.items) { item in
                            DropItemRow(
                                item: item,
                                isCopied: copiedId == item.id,
                                onCopy: {
                                    store.copyItemContent(item)
                                    flashCopied(item.id)
                                },
                                onCopyPath: {
                                    store.copyItemPath(item)
                                    flashCopied(item.id)
                                },
                                onReveal: {
                                    store.revealInFinder(item)
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 210)
            }
        }
    }

    private var footerSection: some View {
        HStack {
            Button("Open Folder") {
                store.openReceivedFolder()
            }
            .controlSize(.small)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .controlSize(.small)
        }
    }

    private func flashCopied(_ id: UUID) {
        copiedId = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedId == id {
                copiedId = nil
            }
        }
    }
}

private struct DropItemRow: View {
    let item: DropItem
    let isCopied: Bool
    let onCopy: () -> Void
    let onCopyPath: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            thumbnailView
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.formattedSize)
                    Text("•")
                    Text(item.createdAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Button(action: onCopy) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(isCopied ? .green : .primary)
                }
                .buttonStyle(.borderless)
                .help("Copy to Clipboard")

                if item.filePath != nil {
                    Button(action: onCopyPath) {
                        Image(systemName: "link")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy File Path")

                    Button(action: onReveal) {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if item.kind == .image,
           let path = item.filePath,
           let nsImage = NSImage(contentsOfFile: path) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.accentColor.opacity(0.12)
                Image(systemName: item.kind == .text ? "text.alignleft" : "doc")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}
