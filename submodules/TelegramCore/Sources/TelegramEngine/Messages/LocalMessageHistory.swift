import Foundation
import Postbox
import SwiftSignalKit

private let localMessageHistoryKey = ValueBoxKey("falekula.local-message-history.v1")

func recordLocalMessageHistory(transaction: Transaction, message: Message, deleted: Bool, updatedText: String? = nil) {
    guard personalForkIsPersonalPeer(message.id.peerId, peer: transaction.getPeer(message.id.peerId)) else { return }
    guard message.id.namespace == Namespaces.Message.Cloud || message.id.namespace == Namespaces.Message.SecretIncoming else {
        return
    }
    if !deleted && message.text == updatedText {
        return
    }
    trackLocalMessage(transaction: transaction, id: message.id)
    var state = transaction.getPreferencesEntry(key: localMessageHistoryKey)?.get(LocalMessageHistoryState.self) ?? LocalMessageHistoryState()
    state.append(LocalMessageHistoryEntry(
        id: UUID().uuidString,
        peerId: message.id.peerId.toInt64(),
        messageId: message.id.id,
        chatTitle: transaction.getPeer(message.id.peerId)?.debugDisplayTitle ?? String(message.id.peerId.toInt64()),
        author: message.author?.debugDisplayTitle ?? "",
        timestamp: message.timestamp,
        observedAt: Date().timeIntervalSince1970,
        deleted: deleted,
        text: message.text,
        updatedText: updatedText,
        hadMedia: !message.media.isEmpty
    ))
    transaction.setPreferencesEntry(key: localMessageHistoryKey, value: PreferencesEntry(state))
}

func migrateLocalMessageHistoryToPersonalChats(transaction: Transaction) {
    guard var state = transaction.getPreferencesEntry(key: localMessageHistoryKey)?.get(LocalMessageHistoryState.self) else { return }
    state.entries.removeAll { entry in
        let peerId = PeerId(entry.peerId)
        return !personalForkIsPersonalPeer(peerId, peer: transaction.getPeer(peerId))
    }
    transaction.setPreferencesEntry(key: localMessageHistoryKey, value: PreferencesEntry(state))
}

extension TelegramEngine.Messages {
    public func localMessageHistory() -> Signal<[LocalMessageHistoryEntry], NoError> {
        return self.account.postbox.preferencesView(keys: [localMessageHistoryKey])
        |> map { preferences in
            let state = preferences.values[localMessageHistoryKey]?.get(LocalMessageHistoryState.self) ?? LocalMessageHistoryState()
            return Array(state.entries.reversed())
        }
        |> distinctUntilChanged
    }

    public func clearLocalMessageHistory() -> Signal<Void, NoError> {
        return self.account.postbox.transaction { transaction in
            clearRetainedMessages(transaction: transaction)
            transaction.setPreferencesEntry(key: localMessageHistoryKey, value: nil)
        }
    }
}
