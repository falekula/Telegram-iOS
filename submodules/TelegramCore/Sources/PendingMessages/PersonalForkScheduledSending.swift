import Foundation
import Postbox
import SwiftSignalKit

public struct PersonalForkSendSettings: Codable, Equatable {
    public static let minimumDelaySeconds: Int32 = SideloadPrivacy.minimumOutgoingScheduleDelay
    public static let maximumDelaySeconds: Int32 = 300
    public static let defaultSettings = PersonalForkSendSettings(delaySeconds: minimumDelaySeconds)
    public let delaySeconds: Int32

    public init(delaySeconds: Int32) {
        self.delaySeconds = min(Self.maximumDelaySeconds, max(Self.minimumDelaySeconds, delaySeconds))
    }

    private enum CodingKeys: String, CodingKey { case delaySeconds }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(delaySeconds: try values.decodeIfPresent(Int32.self, forKey: .delaySeconds) ?? Self.minimumDelaySeconds)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.delaySeconds, forKey: .delaySeconds)
    }
}

private let personalForkSendSettingsKey = ValueBoxKey("xxxgram.send-settings.v1")

func personalForkSendSettings(transaction: Transaction) -> PersonalForkSendSettings {
    return transaction.getPreferencesEntry(key: personalForkSendSettingsKey)?.get(PersonalForkSendSettings.self) ?? .defaultSettings
}

extension TelegramEngine.Messages {
    public func personalForkSendSettings() -> Signal<PersonalForkSendSettings, NoError> {
        return self.account.postbox.preferencesView(keys: [personalForkSendSettingsKey])
        |> map { preferences in
            return preferences.values[personalForkSendSettingsKey]?.get(PersonalForkSendSettings.self) ?? .defaultSettings
        }
        |> distinctUntilChanged
    }

    public func updatePersonalForkSendSettings(delaySeconds: Int32) -> Signal<Bool, NoError> {
        let settings = PersonalForkSendSettings(delaySeconds: delaySeconds)
        return self.account.postbox.transaction { transaction in
            guard let entry = PreferencesEntry(settings), entry.get(PersonalForkSendSettings.self) == settings else { return false }
            transaction.setPreferencesEntry(key: personalForkSendSettingsKey, value: entry)
            return transaction.getPreferencesEntry(key: personalForkSendSettingsKey)?.get(PersonalForkSendSettings.self) == settings
        }
    }
}

/// UI completion must match the queue policy without exposing network filters.
public var personalForkSchedulesOutgoingMessages: Bool {
    return SideloadPrivacy.scheduleOutgoingMessages
}

func personalForkScheduleMessages(_ messages: [(Bool, EnqueueMessage)], peerId: PeerId, now: Int32, minimumDelay: Int32 = SideloadPrivacy.minimumOutgoingScheduleDelay) -> [(Bool, EnqueueMessage)] {
    guard SideloadPrivacy.scheduleOutgoingMessages, peerId.namespace != Namespaces.Peer.SecretChat else { return messages }
    let delay = messages.map { _, message -> Int32 in
        if case let .message(_, _, _, reference, _, _, _, _, _, _) = message,
           let file = reference?.media as? TelegramMediaFile {
            return SideloadPrivacy.outgoingScheduleDelay(mediaBytes: file.size, minimumDelay: minimumDelay)
        }
        return SideloadPrivacy.outgoingScheduleDelay(mediaBytes: nil, minimumDelay: minimumDelay)
    }.max() ?? SideloadPrivacy.outgoingScheduleDelay(mediaBytes: nil, minimumDelay: minimumDelay)
    return messages.map { transformed, message in
        // Leave user-created schedules and reply-template editors untouched.
        if message.attributes.contains(where: { $0 is OutgoingScheduleInfoMessageAttribute || $0 is OutgoingQuickReplyMessageAttribute || $0 is EphemeralOutgoingMessageAttribute }) {
            return (transformed, message)
        }
        return (transformed, message.withUpdatedAttributes { attributes in
            return attributes + [OutgoingScheduleInfoMessageAttribute(scheduleTime: now + delay, repeatPeriod: nil, isPersonalForkAutomatic: true)]
        })
    }
}

/// Uploads can take longer than the initial schedule delay. Rebase only the
/// automatic ghost schedule immediately before building the send RPC, using
/// Telegram's estimated clock. Never convert an expired schedule to direct send.
func refreshPersonalForkSchedule(transaction: Transaction, message: Message, now: Int32, minimumDelay: Int32 = SideloadPrivacy.minimumOutgoingScheduleDelay) -> Message {
    guard let schedule = message.attributes.compactMap({ $0 as? OutgoingScheduleInfoMessageAttribute }).first, schedule.isPersonalForkAutomatic else { return message }
    let configuredDelay = personalForkSendSettings(transaction: transaction).delaySeconds
    let mediaDelay = message.media.compactMap { $0 as? TelegramMediaFile }.map { SideloadPrivacy.outgoingScheduleDelay(mediaBytes: $0.size, minimumDelay: configuredDelay) }.max() ?? configuredDelay
    let scheduleTime = max(schedule.scheduleTime, now + max(minimumDelay, mediaDelay))
    guard scheduleTime != schedule.scheduleTime else { return message }
    let attributes = message.attributes.map { attribute -> MessageAttribute in
        if attribute is OutgoingScheduleInfoMessageAttribute {
            return OutgoingScheduleInfoMessageAttribute(scheduleTime: scheduleTime, repeatPeriod: schedule.repeatPeriod, isPersonalForkAutomatic: true)
        }
        return attribute
    }
    let updated = message.withUpdatedAttributes(attributes).withUpdatedTimestamp(scheduleTime)
    transaction.updateMessage(message.id, update: { _ in .update(localStoreMessage(updated)) })
    return updated
}
