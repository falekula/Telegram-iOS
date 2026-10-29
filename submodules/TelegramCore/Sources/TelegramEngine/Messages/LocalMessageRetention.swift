import Foundation
import Postbox
import SwiftSignalKit

func personalForkIsPersonalPeer(_ peerId: PeerId, peer: Peer?) -> Bool {
    if peerId.namespace == Namespaces.Peer.SecretChat { return true }
    guard peerId.namespace == Namespaces.Peer.CloudUser else { return false }
    return (peer as? TelegramUser)?.botInfo == nil
}

public func personalForkIsPersonalChat(_ message: EngineMessage) -> Bool {
    return personalForkIsPersonalChat(message._asMessage())
}

func personalForkIsPersonalChat(_ message: Message) -> Bool {
    return personalForkIsPersonalPeer(message.id.peerId, peer: message.peers[message.id.peerId])
}

func originalDisappearingMediaTimeout(_ attributes: [MessageAttribute]) -> Int32? {
    if let saved = attributes.compactMap({ $0 as? LocalMessageStateAttribute }).first?.originalMediaTimeout {
        return saved
    }
    let timeouts: [Int32] = attributes.compactMap { attribute in
        if let attribute = attribute as? AutoclearTimeoutMessageAttribute { return attribute.timeout }
        if let attribute = attribute as? AutoremoveTimeoutMessageAttribute { return attribute.timeout }
        return nil
    }
    if timeouts.contains(viewOnceTimeout) { return viewOnceTimeout }
    return timeouts.min()
}

private func isRetainableDisappearingMedia(_ media: Media) -> Bool {
    if media is TelegramMediaImage { return true }
    if let file = media as? TelegramMediaFile {
        return file.isVideo || file.isVoice || file.isInstantVideo
    }
    return false
}

func localStoreMessage(_ message: Message) -> StoreMessage {
    let forward = message.forwardInfo.map {
        StoreMessageForwardInfo(authorId: $0.author?.id, sourceId: $0.source?.id, sourceMessageId: $0.sourceMessageId, date: $0.date, authorSignature: $0.authorSignature, psaType: $0.psaType, flags: $0.flags)
    }
    return StoreMessage(id: message.id, customStableId: nil, globallyUniqueId: message.globallyUniqueId, groupingKey: message.groupingKey, threadId: message.threadId, timestamp: message.timestamp, flags: StoreMessageFlags(message.flags), tags: message.tags, globalTags: message.globalTags, localTags: message.localTags, forwardInfo: forward, authorId: message.author?.id, text: message.text, attributes: message.attributes, media: message.media)
}

func prepareRetainedIncomingPhoto(transaction: Transaction, message: StoreMessage) -> StoreMessage {
    guard case let .Id(id) = message.id,
          personalForkIsPersonalPeer(id.peerId, peer: transaction.getPeer(id.peerId)),
          message.flags.contains(.Incoming),
          message.media.contains(where: isRetainableDisappearingMedia),
          !message.media.contains(where: { $0 is TelegramMediaPaidContent }),
          message.attributes.contains(where: { $0 is AutoclearTimeoutMessageAttribute || $0 is AutoremoveTimeoutMessageAttribute }) else { return message }
    let local = message.attributes.compactMap { $0 as? LocalMessageStateAttribute }.first
    var attributes = message.attributes.filter { !($0 is AutoclearTimeoutMessageAttribute) && !($0 is AutoremoveTimeoutMessageAttribute) && !($0 is LocalMessageStateAttribute) }
    attributes.append(LocalMessageStateAttribute(deleted: local?.deleted ?? false, retainedMedia: true, previousTexts: local?.previousTexts ?? [], originalMediaTimeout: originalDisappearingMediaTimeout(message.attributes)))
    trackLocalMessage(transaction: transaction, id: id)
    return message.withUpdatedAttributes(attributes)
}

public func personalForkKeepsMedia(_ message: EngineMessage) -> Bool {
    return shouldRetainEphemeralMedia(message._asMessage())
}

func shouldRetainEphemeralMedia(_ message: Message) -> Bool {
    guard personalForkIsPersonalChat(message), message.flags.contains(.Incoming), message.paidContent == nil else { return false }
    let hasMedia = message.media.contains(where: isRetainableDisappearingMedia)
    return hasMedia && (message.containsSecretMedia || message.attributes.contains { ($0 as? LocalMessageStateAttribute)?.retainedMedia == true })
}

func retainMessageLocally(transaction: Transaction, message: Message, deleted: Bool, ephemeral: Bool = false) -> Bool {
    guard personalForkIsPersonalPeer(message.id.peerId, peer: transaction.getPeer(message.id.peerId)) else { return false }
    guard message.id.namespace == Namespaces.Message.Cloud || message.id.namespace == Namespaces.Message.SecretIncoming else { return false }
    guard !message.media.contains(where: { $0 is TelegramMediaAction || $0 is TelegramMediaExpiredContent }) else { return false }
    let previous = message.attributes.compactMap { $0 as? LocalMessageStateAttribute }.first
    let marker = LocalMessageStateAttribute(deleted: deleted || previous?.deleted == true, retainedMedia: ephemeral || previous?.retainedMedia == true, previousTexts: previous?.previousTexts ?? [], originalMediaTimeout: originalDisappearingMediaTimeout(message.attributes))
    var attributes = message.attributes.filter { !($0 is LocalMessageStateAttribute) }
    if ephemeral {
        attributes.removeAll { $0 is AutoremoveTimeoutMessageAttribute || $0 is AutoclearTimeoutMessageAttribute }
    }
    attributes.append(marker)
    trackLocalMessage(transaction: transaction, id: message.id)
    transaction.updateMessage(message.id, update: { _ in
        return .update(localStoreMessage(message).withUpdatedAttributes(attributes))
    })
    return true
}

private struct RetainedMessageId: Codable, Hashable {
    let peer: Int64
    let namespace: Int32
    let id: Int32
    var messageId: MessageId { MessageId(peerId: PeerId(self.peer), namespace: self.namespace, id: self.id) }
}
private struct RetainedMessagesIndex: Codable {
    var ids: Set<RetainedMessageId> = []
}
private let retainedMessagesKey = ValueBoxKey("falekula.retained-message-index.v1")
private let personalChatMigrationKey = ValueBoxKey("xxxgram.personal-history-migration.v1")

/// Old builds recorded groups too. Remove their local snapshots once on upgrade,
/// preserving ordinary live messages and only deleting already-deleted copies.
func migrateRetainedMessagesToPersonalChats(transaction: Transaction) {
    guard transaction.getPreferencesEntry(key: personalChatMigrationKey) == nil else { return }
    var index = transaction.getPreferencesEntry(key: retainedMessagesKey)?.get(RetainedMessagesIndex.self) ?? RetainedMessagesIndex()
    for key in Array(index.ids) {
        guard !personalForkIsPersonalPeer(key.messageId.peerId, peer: transaction.getPeer(key.messageId.peerId)) else { continue }
        if let message = transaction.getMessage(key.messageId), let marker = message.attributes.compactMap({ $0 as? LocalMessageStateAttribute }).first {
            if marker.deleted {
                transaction.deleteMessages([message.id], forEachMedia: nil)
            } else {
                let attributes = message.attributes.filter { !($0 is LocalMessageStateAttribute) } + [LocalMessageStateAttribute()]
                transaction.updateMessage(message.id, update: { _ in .update(localStoreMessage(message).withUpdatedAttributes(attributes)) })
            }
        }
        index.ids.remove(key)
    }
    transaction.setPreferencesEntry(key: retainedMessagesKey, value: PreferencesEntry(index))
    migrateLocalMessageHistoryToPersonalChats(transaction: transaction)
    transaction.setPreferencesEntry(key: personalChatMigrationKey, value: PreferencesEntry(RetainedMessagesIndex()))
}

func trackLocalMessage(transaction: Transaction, id: MessageId) {
    var index = transaction.getPreferencesEntry(key: retainedMessagesKey)?.get(RetainedMessagesIndex.self) ?? RetainedMessagesIndex()
    index.ids.insert(RetainedMessageId(peer: id.peerId.toInt64(), namespace: id.namespace, id: id.id))
    transaction.setPreferencesEntry(key: retainedMessagesKey, value: PreferencesEntry(index))
}

func clearRetainedMessages(transaction: Transaction) {
    let index = transaction.getPreferencesEntry(key: retainedMessagesKey)?.get(RetainedMessagesIndex.self) ?? RetainedMessagesIndex()
    for key in index.ids {
        guard let message = transaction.getMessage(key.messageId), let marker = message.attributes.compactMap({ $0 as? LocalMessageStateAttribute }).first else { continue }
        if marker.deleted || marker.retainedMedia {
            transaction.deleteMessages([message.id], forEachMedia: nil)
        } else {
            // An explicit empty marker overrides the merge hook without losing live messages.
            let attributes = message.attributes.filter { !($0 is LocalMessageStateAttribute) } + [LocalMessageStateAttribute()]
            transaction.updateMessage(message.id, update: { _ in .update(localStoreMessage(message).withUpdatedAttributes(attributes)) })
        }
    }
    transaction.setPreferencesEntry(key: retainedMessagesKey, value: nil)
}

extension TelegramEngine.Messages {
    public func retainDisappearingPhoto(id: EngineMessage.Id) -> Signal<Void, NoError> {
        return self.account.postbox.transaction { transaction in
            if let message = transaction.getMessage(id), shouldRetainEphemeralMedia(message) {
                _ = retainMessageLocally(transaction: transaction, message: message, deleted: false, ephemeral: true)
            }
        }
    }
}
