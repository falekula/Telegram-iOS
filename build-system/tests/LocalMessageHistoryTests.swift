import Foundation

@main
struct LocalMessageHistoryTests {
    static func entry(_ index: Int, text: String = "before", updated: String? = "after", deleted: Bool = false) -> LocalMessageHistoryEntry {
        return LocalMessageHistoryEntry(id: String(index), peerId: 1, messageId: Int32(index), chatTitle: "Chat", author: "Author", timestamp: 1, observedAt: 2, deleted: deleted, text: text, updatedText: updated, hadMedia: false)
    }

    static func main() throws {
        var state = LocalMessageHistoryState()
        state.append(entry(1))
        state.append(entry(1))
        precondition(state.entries.count == 1, "Duplicate replay must not duplicate history")
        state.append(entry(1, text: "after", updated: "third"))
        state.append(entry(1, text: "third", updated: nil, deleted: true))
        precondition(state.entries.count == 3, "Edits and deletion must preserve their own snapshots")
        let restored = try JSONDecoder().decode(LocalMessageHistoryState.self, from: JSONEncoder().encode(state))
        precondition(restored.entries == state.entries, "Snapshots must survive persistence")
        state = LocalMessageHistoryState()
        for index in 0 ..< 510 { state.append(entry(index)) }
        precondition(state.entries.count == 500 && state.entries.first?.messageId == 10, "Evict oldest by count")
        state = LocalMessageHistoryState()
        for index in 0 ..< 100 { state.append(entry(index, text: String(repeating: "я", count: 32768))) }
        precondition(state.entries.count < 100 && state.entries.last?.messageId == 99, "Bound UTF-8 storage, keeping newest")
        state = LocalMessageHistoryState()
        precondition(state.entries.isEmpty, "Cleared history must start empty")
        print("Local message history tests passed")
    }
}
