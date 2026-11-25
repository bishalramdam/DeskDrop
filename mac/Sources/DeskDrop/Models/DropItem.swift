import Foundation

enum DropKind: String, Codable, Sendable {
    case image
    case text
    case file
}

struct DropItem: Identifiable, Codable, Sendable {
    let id: UUID
    let kind: DropKind
    let title: String
    let filePath: String?
    let textPreview: String?
    let byteCount: Int
    let createdAt: Date

    init(
        id: UUID = UUID(),
        kind: DropKind,
        title: String,
        filePath: String? = nil,
        textPreview: String? = nil,
        byteCount: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.filePath = filePath
        self.textPreview = textPreview
        self.byteCount = byteCount
        self.createdAt = createdAt
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}
