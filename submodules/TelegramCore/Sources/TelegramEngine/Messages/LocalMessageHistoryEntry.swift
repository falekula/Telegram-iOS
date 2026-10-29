import Foundation

/// Text snapshots only; never retains media resources or fetches deleted content.
public struct LocalMessageHistoryEntry: Codable, Equatable {
    public let id: String
    public let peerId: Int64
    public let messageId: Int32
    public let chatTitle: String
    public let author: String
    public let timestamp: Int32
    public let observedAt: Double
    public let deleted: Bool
    public let text: String
    public let updatedText: String?
    public let hadMedia: Bool
}

struct LocalMessageHistoryState: Codable {
    var entries: [LocalMessageHistoryEntry] = []

    mutating func append(_ entry: LocalMessageHistoryEntry) {
        // State replay may deliver the same update more than once.
        if let previous = self.entries.last(where: { $0.peerId == entry.peerId && $0.messageId == entry.messageId }),
           previous.deleted == entry.deleted, previous.text == entry.text,
           previous.updatedText == entry.updatedText, previous.hadMedia == entry.hadMedia {
            return
        }
        self.entries.append(entry)
        // Bound both record count and text storage; evict oldest records first.
        var size = self.entries.reduce(0) { $0 + Self.byteCount($1) }
        while self.entries.count > 500 || size > 4 * 1024 * 1024 {
            size -= Self.byteCount(self.entries.removeFirst())
        }
    }

    private static func byteCount(_ entry: LocalMessageHistoryEntry) -> Int {
        return entry.text.utf8.count + (entry.updatedText?.utf8.count ?? 0)
            + entry.chatTitle.utf8.count + entry.author.utf8.count + 256
    }
}
