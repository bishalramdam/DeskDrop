import Foundation

final class DropStorage: Sendable {
    let receivedDirectory: URL
    let historyFile: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let baseDir = appSupport.appendingPathComponent("DeskDrop", isDirectory: true)
        self.receivedDirectory = baseDir.appendingPathComponent("Received", isDirectory: true)
        self.historyFile = baseDir.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: receivedDirectory, withIntermediateDirectories: true)
    }

    func saveFile(data: Data, suggestedFilename: String?, mimeType: String?) throws -> (url: URL, isImage: Bool) {
        let sanitized = sanitizeFilename(suggestedFilename) ?? defaultFilename(for: mimeType)
        let uniqueURL = uniqueDestinationURL(for: sanitized)
        try data.write(to: uniqueURL, options: .atomic)

        let ext = uniqueURL.pathExtension.lowercased()
        let isImage = ["png", "jpg", "jpeg", "webp", "heic", "gif", "bmp", "tiff"].contains(ext)
            || (mimeType?.lowercased().hasPrefix("image/") ?? false)

        if isImage {
            let latestURL = receivedDirectory.deletingLastPathComponent().appendingPathComponent("latest.\(ext.isEmpty ? "png" : ext)")
            try? FileManager.default.removeItem(at: latestURL)
            try? FileManager.default.createSymbolicLink(at: latestURL, withDestinationURL: uniqueURL)
        }

        return (uniqueURL, isImage)
    }

    func saveHistory(_ items: [DropItem]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Array(items.prefix(30))) {
            try? data.write(to: historyFile, options: .atomic)
        }
    }

    func loadHistory() -> [DropItem] {
        guard let data = try? Data(contentsOf: historyFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DropItem].self, from: data)) ?? []
    }

    private func sanitizeFilename(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        let base = URL(fileURLWithPath: name).lastPathComponent
        let cleaned = base.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty ? nil : cleaned
    }

    private func defaultFilename(for mimeType: String?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: Date())

        let ext: String
        switch mimeType?.lowercased() {
        case "image/png": ext = "png"
        case "image/jpeg", "image/jpg": ext = "jpg"
        case "image/webp": ext = "webp"
        case "image/heic": ext = "heic"
        case "text/plain": ext = "txt"
        default: ext = "bin"
        }
        return "drop_\(stamp).\(ext)"
    }

    private func uniqueDestinationURL(for filename: String) -> URL {
        let fm = FileManager.default
        var candidate = receivedDirectory.appendingPathComponent(filename)
        if !fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(stem)_\(counter)" : "\(stem)_\(counter).\(ext)"
            candidate = receivedDirectory.appendingPathComponent(nextName)
            counter += 1
        }
        return candidate
    }
}
