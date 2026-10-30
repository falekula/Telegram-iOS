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

        let customLimits = LocalMessageHistoryLimits(recordCount: 777, megabytes: 8)
        let persistedLimits = try JSONDecoder().decode(LocalMessageHistoryLimits.self, from: JSONEncoder().encode(customLimits))
        precondition(persistedLimits == customLimits, "Custom limits must survive persistence")
        let defaults = try JSONDecoder().decode(LocalMessageHistoryLimits.self, from: Data("{}".utf8))
        precondition(defaults == .defaultSettings, "Missing fields must migrate to existing defaults")
        let corruptLimits = try JSONDecoder().decode(LocalMessageHistoryLimits.self, from: Data("{\"recordCount\":-1,\"megabytes\":999999}".utf8))
        precondition(corruptLimits.recordCount == 1 && corruptLimits.megabytes == 64, "Stored limits must be bounded before use")
        precondition(LocalMessageHistoryLimits(recordCount: Int.max, megabytes: Int.min).recordCount == 10_000, "Extreme input must not overflow")

        for index in 0 ..< 800 { state.append(entry(index), limits: customLimits) }
        precondition(state.entries.count == 777 && state.entries.first?.messageId == 23, "Custom count must replace the hardcoded 500")
        state.trim(to: LocalMessageHistoryLimits(recordCount: 123, megabytes: 8))
        precondition(state.entries.count == 123 && state.entries.first?.messageId == 677, "Lowering a count keeps the newest snapshots")
        state.trim(to: customLimits)
        precondition(state.entries.count == 123, "Raising limits must not fabricate missing history")

        state = LocalMessageHistoryState()
        let smallStorage = LocalMessageHistoryLimits(recordCount: 1_000, megabytes: 1)
        for index in 0 ..< 100 { state.append(entry(index, text: String(repeating: "я", count: 32768)), limits: smallStorage) }
        precondition(state.entries.count > 0 && state.entries.count < 100 && state.entries.last?.messageId == 99, "Custom byte budget must evict oldest UTF-8 snapshots")
        precondition(state.entries.reduce(0, { $0 + $1.storageByteCount }) <= smallStorage.byteCount, "Displayed storage accounting must match the enforced byte budget")
        print("Local message history tests passed")
    }
}
