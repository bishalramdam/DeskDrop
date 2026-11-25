import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var store: DropStore
    @State private var copiedId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerSection
            Divider()
            controlsSection
            Divider()
            recentDropsSection
            Divider()
            footerSection
        }
        .padding(12)
        .frame(width: 340)
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.listeningPort != nil ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text("DeskDrop")
                        .font(.headline)
                }
                if let port = store.listeningPort {
                    let ips = NetworkUtils.localIPv4Addresses()
                    let addressText = ips.first.map { "\($0):\(port)" } ?? "localhost:\(port)"
                    Text("Listening on \(addressText) (Bonjour)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if let error = store.serverError {
                    Text("Error: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Starting server...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                store.openReceivedFolder()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Open Received Folder")
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Auto-copy to Clipboard", isOn: $store.autoCopyToClipboard)
                .toggleStyle(.switch)
                .controlSize(.small)
            Toggle("Bluetooth Nearby Beacon", isOn: $store.bleBeaconEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
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
                    Text("Share a screenshot, photo, text, or file from your phone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
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
                .frame(maxHeight: 260)
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
