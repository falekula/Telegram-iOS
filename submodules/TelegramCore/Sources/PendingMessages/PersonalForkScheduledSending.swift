import Foundation
import Postbox

func personalForkScheduleMessages(_ messages: [(Bool, EnqueueMessage)], peerId: PeerId, now: Int32) -> [(Bool, EnqueueMessage)] {
    guard SideloadPrivacy.scheduleOutgoingMessages, peerId.namespace != Namespaces.Peer.SecretChat else { return messages }
    let delay = messages.map { _, message -> Int32 in
        if case let .message(_, _, _, reference, _, _, _, _, _, _) = message,
           let file = reference?.media as? TelegramMediaFile {
            return SideloadPrivacy.outgoingScheduleDelay(mediaBytes: file.size)
        }
        return SideloadPrivacy.outgoingScheduleDelay(mediaBytes: nil)
    }.max() ?? 12
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
func refreshPersonalForkSchedule(transaction: Transaction, message: Message, now: Int32, minimumDelay: Int32 = 12) -> Message {
    guard let schedule = message.attributes.compactMap({ $0 as? OutgoingScheduleInfoMessageAttribute }).first, schedule.isPersonalForkAutomatic else { return message }
    let mediaDelay = message.media.compactMap { $0 as? TelegramMediaFile }.map { SideloadPrivacy.outgoingScheduleDelay(mediaBytes: $0.size) }.max() ?? 12
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
