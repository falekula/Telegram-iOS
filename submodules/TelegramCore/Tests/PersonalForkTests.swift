import XCTest
import Postbox
import TelegramApi
@testable import TelegramCore

final class PersonalForkTests: XCTestCase {
    private let id = MessageId(peerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(42)), namespace: Namespaces.Message.Cloud, id: 1)

    private func stored(text: String, attributes: [MessageAttribute] = [], media: [Media] = [], incoming: Bool = true, id: MessageId? = nil) -> Message {
        return Message(stableId: 1, stableVersion: 0, id: id ?? self.id, globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: 100, flags: incoming ? [.Incoming] : [], tags: [], globalTags: [], localTags: [], customTags: [], forwardInfo: nil, author: nil, text: text, attributes: attributes, media: media, peers: SimpleDictionary(), associatedMessages: SimpleDictionary(), associatedMessageIds: [], associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:])
    }

    func testActualRpcDescriptionsAreSuppressed() {
        let names = [
            Api.functions.messages.setTyping(flags: 0, peer: .inputPeerSelf, topMsgId: nil, action: .sendMessageTypingAction).0.name,
            Api.functions.messages.readHistory(peer: .inputPeerSelf, maxId: 1).0.name,
            Api.functions.messages.readMessageContents(id: [1]).0.name,
            Api.functions.messages.readMentions(flags: 0, peer: .inputPeerSelf, topMsgId: nil).0.name,
            Api.functions.messages.reportReadMetrics(peer: .inputPeerSelf, metrics: []).0.name,
            Api.functions.stories.readStories(peer: .inputPeerSelf, maxId: 1).0.name,
            Api.functions.stories.incrementStoryViews(peer: .inputPeerSelf, id: [1]).0.name
        ]
        for name in names { XCTAssertTrue(SideloadPrivacy.suppressesRequest(name), name) }
        XCTAssertTrue(SideloadPrivacy.suppressesRequest(Api.functions.account.updateStatus(offline: .boolFalse).0.name))
        XCTAssertTrue(SideloadPrivacy.suppressesRequest(Api.functions.account.updateStatus(offline: .boolTrue).0.name))
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
        let marker = LocalMessageStateAttribute(deleted: true, retainedMedia: true, previousTexts: ["текст", "emoji 👋"], originalMediaTimeout: viewOnceTimeout)
        let encoder = PostboxEncoder()
        marker.encode(encoder)
        let decoded = LocalMessageStateAttribute(decoder: PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())))
        XCTAssertTrue(decoded.deleted)
        XCTAssertTrue(decoded.retainedMedia)
        XCTAssertEqual(decoded.previousTexts, marker.previousTexts)
        XCTAssertEqual(decoded.originalMediaTimeout, viewOnceTimeout)
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

    func testRetainedPlaybackClearsLocalUnplayedStateWithoutRestoringCountdown() {
        let retained = LocalMessageStateAttribute(retainedMedia: true, originalMediaTimeout: viewOnceTimeout)
        // Playback updates and server refreshes pass through this storage hook.
        // They must keep the local played state and discard incoming timers.
        var updated: [MessageAttribute] = [
            ConsumableContentMessageAttribute(consumed: true),
            AutoclearTimeoutMessageAttribute(timeout: viewOnceTimeout, countdownBeginTime: 100),
            AutoremoveTimeoutMessageAttribute(timeout: 5, countdownBeginTime: 100)
        ]
        telegramPostboxSeedConfiguration.mergeMessageAttributes([retained, ConsumableContentMessageAttribute(consumed: false)], &updated)
        XCTAssertEqual(updated.compactMap { $0 as? ConsumableContentMessageAttribute }.first?.consumed, true)
        XCTAssertEqual(updated.compactMap { $0 as? LocalMessageStateAttribute }.first?.originalMediaTimeout, viewOnceTimeout)
        XCTAssertFalse(updated.contains { $0 is AutoclearTimeoutMessageAttribute || $0 is AutoremoveTimeoutMessageAttribute })

        // An ordinary attachment retains its normal server timer.
        var ordinary: [MessageAttribute] = [AutoclearTimeoutMessageAttribute(timeout: 5, countdownBeginTime: nil)]
        telegramPostboxSeedConfiguration.mergeMessageAttributes([], &ordinary)
        XCTAssertTrue(ordinary.first is AutoclearTimeoutMessageAttribute)
    }

    func testHiddenPlaybackReceiptDoesNotResetLocalPlayedIndicatorOnRefresh() {
        var refreshed: [MessageAttribute] = [ConsumableContentMessageAttribute(consumed: false)]
        telegramPostboxSeedConfiguration.mergeMessageAttributes([ConsumableContentMessageAttribute(consumed: true)], &refreshed)
        XCTAssertEqual(refreshed.compactMap { $0 as? ConsumableContentMessageAttribute }.first?.consumed, true)

        var untouched: [MessageAttribute] = [ConsumableContentMessageAttribute(consumed: false)]
        telegramPostboxSeedConfiguration.mergeMessageAttributes([ConsumableContentMessageAttribute(consumed: false)], &untouched)
        XCTAssertEqual(untouched.compactMap { $0 as? ConsumableContentMessageAttribute }.first?.consumed, false)

        var replacedWithText: [MessageAttribute] = []
        telegramPostboxSeedConfiguration.mergeMessageAttributes([ConsumableContentMessageAttribute(consumed: true)], &replacedWithText)
        XCTAssertFalse(replacedWithText.contains { $0 is ConsumableContentMessageAttribute })
    }

    func testPersonalHistoryExcludesBothKindsOfGroup() {
        for namespace in [Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel] {
            let id = MessageId(peerId: PeerId(namespace: namespace, id: PeerId.Id._internalFromInt64Value(42)), namespace: Namespaces.Message.Cloud, id: 1)
            let previous = stored(text: "before", id: id)
            let updated = localStoreMessage(stored(text: "after", id: id))
            let merged = mergedServerMessageUpdate(previous: previous, updated: updated)
            XCTAssertFalse(personalForkIsPersonalChat(previous))
            XCTAssertNil(merged.attributes.compactMap { $0 as? LocalMessageStateAttribute }.first)
            XCTAssertEqual(merged.text, "after")
        }
        XCTAssertTrue(personalForkIsPersonalChat(stored(text: "private")))
        XCTAssertTrue(personalForkIsPersonalPeer(PeerId(namespace: Namespaces.Peer.SecretChat, id: PeerId.Id._internalFromInt64Value(42)), peer: nil))
        let bot = TelegramUser(id: self.id.peerId, accessHash: nil, firstName: "Bot", lastName: nil, username: nil, phone: nil, photo: [], botInfo: BotUserInfo(flags: [], inlinePlaceholder: nil), restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        XCTAssertFalse(personalForkIsPersonalPeer(bot.id, peer: bot))
    }

    func testOriginalTimerDoesNotBecomeAnOrdinaryPhotoAfterRefresh() {
        for timeout in [Int32(5), viewOnceTimeout] {
            let original: [MessageAttribute] = [AutoclearTimeoutMessageAttribute(timeout: timeout, countdownBeginTime: nil)]
            XCTAssertEqual(originalDisappearingMediaTimeout(original), timeout)
            let marker = LocalMessageStateAttribute(retainedMedia: true, originalMediaTimeout: originalDisappearingMediaTimeout(original))
            let previous = stored(text: "", attributes: [marker])
            let merged = mergedServerMessageUpdate(previous: previous, updated: localStoreMessage(stored(text: "")))
            XCTAssertEqual(merged.attributes.compactMap { $0 as? LocalMessageStateAttribute }.first?.originalMediaTimeout, timeout)
        }
        XCTAssertNil(originalDisappearingMediaTimeout([LocalMessageStateAttribute(retainedMedia: true)]))
    }

    func testTimedVoiceRetainsItsResourceButOrdinaryVoiceDoesNot() {
        let voice = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: 7), partialReference: nil, resource: LocalFileMediaResource(fileId: 7), previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "audio/ogg", size: 10, attributes: [.Audio(isVoice: true, duration: 3, title: nil, performer: nil, waveform: nil)], alternativeRepresentations: [])
        let timer = AutoclearTimeoutMessageAttribute(timeout: viewOnceTimeout, countdownBeginTime: nil)
        let timed = stored(text: "", attributes: [timer], media: [voice])
        XCTAssertTrue(shouldRetainEphemeralMedia(timed))
        XCTAssertFalse(shouldRetainEphemeralMedia(stored(text: "", media: [voice])))
        let marker = LocalMessageStateAttribute(retainedMedia: true, originalMediaTimeout: viewOnceTimeout)
        let saved = stored(text: "", attributes: [marker], media: [voice])
        let merged = mergedServerMessageUpdate(previous: saved, updated: localStoreMessage(stored(text: "", media: [TelegramMediaExpiredContent(data: .voiceMessage)])))
        XCTAssertTrue(merged.media.first is TelegramMediaFile)
        XCTAssertEqual(merged.attributes.compactMap { $0 as? LocalMessageStateAttribute }.first?.originalMediaTimeout, viewOnceTimeout)
    }

    func testLegacyMetadataDecodesWithoutInventingTimer() {
        let encoder = PostboxEncoder()
        encoder.encodeBool(true, forKey: "m")
        encoder.encodeStringArray(["old"], forKey: "v")
        let decoded = LocalMessageStateAttribute(decoder: PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())))
        XCTAssertTrue(decoded.retainedMedia)
        XCTAssertNil(decoded.originalMediaTimeout)
        XCTAssertEqual(decoded.previousTexts, ["old"])
    }

    func testGhostScheduleNeverUsesImmediateSendThreshold() {
        XCTAssertEqual(SideloadPrivacy.outgoingScheduleDelay(mediaBytes: nil), 12)
        XCTAssertEqual(SideloadPrivacy.outgoingScheduleDelay(mediaBytes: 1), 12)
        XCTAssertEqual(SideloadPrivacy.outgoingScheduleDelay(mediaBytes: 10 * 1024 * 1024), 45)
        XCTAssertEqual(SideloadPrivacy.outgoingScheduleDelay(mediaBytes: Int64.max), 300)
        let message = EnqueueMessage.message(text: "reply", attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
        let scheduled = personalForkScheduleMessages([(false, message)], peerId: self.id.peerId, now: 100)
        let attribute = scheduled[0].1.attributes.compactMap { $0 as? OutgoingScheduleInfoMessageAttribute }.first
        XCTAssertEqual(attribute?.scheduleTime, 112)
        XCTAssertEqual(attribute?.isPersonalForkAutomatic, true)
    }

    func testGhostScheduleDoesNotRewriteExplicitUserSchedule() {
        for timestamp in [Int32(500), scheduleWhenOnlineTimestamp] {
            let schedule = OutgoingScheduleInfoMessageAttribute(scheduleTime: timestamp, repeatPeriod: nil)
            let message = EnqueueMessage.forward(source: self.id, threadId: nil, grouping: .none, attributes: [schedule], correlationId: nil)
            let result = personalForkScheduleMessages([(false, message)], peerId: self.id.peerId, now: 100)
            let attribute = result[0].1.attributes.compactMap { $0 as? OutgoingScheduleInfoMessageAttribute }.first
            XCTAssertEqual(attribute?.scheduleTime, timestamp)
            XCTAssertEqual(attribute?.isPersonalForkAutomatic, false)
        }
    }

    func testAutomaticScheduleMarkerSurvivesRestart() {
        let schedule = OutgoingScheduleInfoMessageAttribute(scheduleTime: 123, repeatPeriod: nil, isPersonalForkAutomatic: true)
        let encoder = PostboxEncoder()
        schedule.encode(encoder)
        let decoded = OutgoingScheduleInfoMessageAttribute(decoder: PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())))
        XCTAssertTrue(decoded.isPersonalForkAutomatic)
        XCTAssertEqual(decoded.scheduleTime, 123)
        XCTAssertFalse(decoded.withUpdatedScheduleTime(999).isPersonalForkAutomatic)
        let oldEncoder = PostboxEncoder()
        oldEncoder.encodeInt32(456, forKey: "t")
        let legacy = OutgoingScheduleInfoMessageAttribute(decoder: PostboxDecoder(buffer: MemoryBuffer(data: oldEncoder.makeData())))
        XCTAssertFalse(legacy.isPersonalForkAutomatic)
    }

    func testStandaloneShareSchedulesAfterUploadAndRefreshesExpiredAutomaticDate() {
        let schedule = personalForkStandaloneSchedule(attributes: [], mediaBytes: nil, now: 200)
        XCTAssertEqual(schedule?.scheduleTime, 212)
        XCTAssertEqual(schedule?.isPersonalForkAutomatic, true)
        let expired = OutgoingScheduleInfoMessageAttribute(scheduleTime: 112, repeatPeriod: nil, isPersonalForkAutomatic: true)
        let refreshed = personalForkStandaloneSchedule(attributes: [expired], mediaBytes: 10 * 1024 * 1024, now: 200)
        XCTAssertEqual(refreshed?.scheduleTime, 245)
        XCTAssertEqual(refreshed?.isPersonalForkAutomatic, true)
    }

    func testStandaloneSharePreservesExplicitAndWhenOnlineSchedules() {
        for timestamp in [Int32(500), scheduleWhenOnlineTimestamp] {
            let manual = OutgoingScheduleInfoMessageAttribute(scheduleTime: timestamp, repeatPeriod: nil)
            let result = personalForkStandaloneSchedule(attributes: [manual], mediaBytes: Int64.max, now: 200)
            XCTAssertEqual(result?.scheduleTime, timestamp)
            XCTAssertEqual(result?.isPersonalForkAutomatic, false)
        }
    }
}
