import XCTest
import Postbox
import TelegramApi
@testable import TelegramCore

final class PersonalForkTests: XCTestCase {
    private let id = MessageId(peerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(42)), namespace: Namespaces.Message.Cloud, id: 1)

    private func stored(text: String, attributes: [MessageAttribute] = [], media: [Media] = [], incoming: Bool = true) -> Message {
        return Message(stableId: 1, stableVersion: 0, id: self.id, globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: 100, flags: incoming ? [.Incoming] : [], tags: [], globalTags: [], localTags: [], customTags: [], forwardInfo: nil, author: nil, text: text, attributes: attributes, media: media, peers: SimpleDictionary(), associatedMessages: SimpleDictionary(), associatedMessageIds: [], associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:])
    }

    func testActualRpcDescriptionsAreSuppressed() {
        let names = [
            Api.functions.messages.setTyping(flags: 0, peer: .inputPeerSelf, topMsgId: nil, action: .sendMessageTypingAction).0.name,
            Api.functions.messages.readHistory(peer: .inputPeerSelf, maxId: 1).0.name,
            Api.functions.messages.readMessageContents(id: [1]).0.name,
            Api.functions.stories.readStories(peer: .inputPeerSelf, maxId: 1).0.name,
            Api.functions.stories.incrementStoryViews(peer: .inputPeerSelf, id: [1]).0.name
        ]
        for name in names { XCTAssertTrue(SideloadPrivacy.suppressesRequest(name), name) }
        XCTAssertTrue(SideloadPrivacy.forcesOfflineStatus(Api.functions.account.updateStatus(offline: .boolFalse).0.name))
        XCTAssertFalse(SideloadPrivacy.suppressesRequest(Api.functions.account.setPrivacy(key: .inputPrivacyKeyStatusTimestamp, rules: [.inputPrivacyValueDisallowAll]).0.name))
    }

    func testEditKeepsPreviousTextAndDeletionMarker() {
        let marker = LocalMessageStateAttribute(deleted: true, previousTexts: ["first"])
        let previous = stored(text: "second", attributes: [marker])
        let updated = localStoreMessage(stored(text: "third"))
        let merged = mergedServerMessageUpdate(previous: previous, updated: updated)
        let local = merged.attributes.compactMap { $0 as? LocalMessageStateAttribute }.first
        XCTAssertEqual(local?.previousTexts, ["first", "second"])
        XCTAssertEqual(local?.deleted, true)
    }

    func testRepeatedRefreshDoesNotInventEdits() {
        let marker = LocalMessageStateAttribute(previousTexts: ["before"])
        let previous = stored(text: "after", attributes: [marker])
        let merged = mergedServerMessageUpdate(previous: previous, updated: localStoreMessage(stored(text: "after")))
        XCTAssertEqual(merged.attributes.compactMap { $0 as? LocalMessageStateAttribute }.first?.previousTexts, ["before"])
    }

    func testLocalMetadataSurvivesDatabaseEncoding() {
        let marker = LocalMessageStateAttribute(deleted: true, retainedMedia: true, previousTexts: ["текст", "emoji 👋"])
        let encoder = PostboxEncoder()
        marker.encode(encoder)
        let decoded = LocalMessageStateAttribute(decoder: PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())))
        XCTAssertTrue(decoded.deleted)
        XCTAssertTrue(decoded.retainedMedia)
        XCTAssertEqual(decoded.previousTexts, marker.previousTexts)
    }

    func testPhotoSurvivesServerExpiryAndRetainsItsResource() {
        let image = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: 9), representations: [], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
        let marker = LocalMessageStateAttribute(retainedMedia: true)
        let previous = stored(text: "", attributes: [marker], media: [image])
        let expired = localStoreMessage(stored(text: "", media: [TelegramMediaExpiredContent(data: .image)]))
        let merged = mergedServerMessageUpdate(previous: previous, updated: expired)
        XCTAssertTrue(merged.media.first is TelegramMediaImage)
        XCTAssertTrue(shouldRetainEphemeralMedia(previous))
        XCTAssertFalse(shouldRetainEphemeralMedia(stored(text: "ordinary", media: [image])))
        XCTAssertFalse(shouldRetainEphemeralMedia(stored(text: "", attributes: [marker], media: [image], incoming: false)))
    }

    func testExplicitClearOverridesMergePreservation() {
        var updated: [MessageAttribute] = [LocalMessageStateAttribute()]
        telegramPostboxSeedConfiguration.mergeMessageAttributes([LocalMessageStateAttribute(deleted: true, previousTexts: ["old"])], &updated)
        XCTAssertEqual(updated.compactMap { $0 as? LocalMessageStateAttribute }.first?.previousTexts, [])
        XCTAssertEqual(updated.compactMap { $0 as? LocalMessageStateAttribute }.first?.deleted, false)
    }
}
