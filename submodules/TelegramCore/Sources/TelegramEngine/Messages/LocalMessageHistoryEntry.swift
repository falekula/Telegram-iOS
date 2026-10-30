import Foundation

/// Per-account limits for the text journal, independent of inline retained messages.
public struct LocalMessageHistoryLimits: Codable, Equatable {
    public static let recordRange = 1 ... 10_000
    public static let megabyteRange = 1 ... 64
    public static let defaultSettings = LocalMessageHistoryLimits(recordCount: 500, megabytes: 4)

    public let recordCount: Int
    public let megabytes: Int
    public var byteCount: Int { self.megabytes * 1024 * 1024 }

    public init(recordCount: Int, megabytes: Int) {
        self.recordCount = min(Self.recordRange.upperBound, max(Self.recordRange.lowerBound, recordCount))
        self.megabytes = min(Self.megabyteRange.upperBound, max(Self.megabyteRange.lowerBound, megabytes))
    }

    private enum CodingKeys: String, CodingKey { case recordCount, megabytes }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(recordCount: try values.decodeIfPresent(Int.self, forKey: .recordCount) ?? 500, megabytes: try values.decodeIfPresent(Int.self, forKey: .megabytes) ?? 4)
    }
}

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

    /// The same UTF-8 accounting used by the journal's storage limit, excluding media.
    public var storageByteCount: Int {
        return self.text.utf8.count + (self.updatedText?.utf8.count ?? 0)
            + self.chatTitle.utf8.count + self.author.utf8.count + 256
    }
}

struct LocalMessageHistoryState: Codable {
    var entries: [LocalMessageHistoryEntry] = []

    mutating func append(_ entry: LocalMessageHistoryEntry, limits: LocalMessageHistoryLimits = .defaultSettings) {
        // State replay may deliver the same update more than once.
        if let previous = self.entries.last(where: { $0.peerId == entry.peerId && $0.messageId == entry.messageId }),
           previous.deleted == entry.deleted, previous.text == entry.text,
           previous.updatedText == entry.updatedText, previous.hadMedia == entry.hadMedia {
            return
        }
        self.entries.append(entry)
        self.trim(to: limits)
    }

    mutating func trim(to limits: LocalMessageHistoryLimits) {
        // One linear pass instead of repeatedly shifting a potentially large journal.
        var size = self.entries.reduce(0) { $0 + Self.byteCount($1) }
        var removedCount = 0
        while removedCount < self.entries.count && (self.entries.count - removedCount > limits.recordCount || size > limits.byteCount) {
            size -= Self.byteCount(self.entries[removedCount])
            removedCount += 1
        }
        if removedCount != 0 {
            self.entries.removeFirst(removedCount)
        }
    }

    private static func byteCount(_ entry: LocalMessageHistoryEntry) -> Int {
        return entry.storageByteCount
    }
}
