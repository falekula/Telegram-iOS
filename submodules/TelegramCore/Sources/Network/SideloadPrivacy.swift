import Foundation

// Privacy policy for this personal sideload build. Sending a message can still
// reveal activity on Telegram's servers; no client can promise invisibility then.
enum SideloadPrivacy {
    static let hideReadReceipts = true
    static let hideOnline = true
    static let scheduleOutgoingMessages = true
    static let minimumOutgoingScheduleDelay: Int32 = 15

    static func outgoingScheduleDelay(mediaBytes: Int64?, minimumDelay: Int32 = SideloadPrivacy.minimumOutgoingScheduleDelay) -> Int32 {
        // Telegram immediately sends schedule_date < 10 seconds in the future.
        // The owner's minimum is configurable, with at least five seconds of
        // headroom above that threshold. It cannot cover an arbitrary network stall.
        let boundedMinimum = min(300, max(minimumOutgoingScheduleDelay, minimumDelay))
        guard let mediaBytes = mediaBytes, mediaBytes > 0 else { return boundedMinimum }
        return Int32(min(300.0, max(Double(boundedMinimum), ceil(Double(mediaBytes) / 1048576.0 * 4.5))))
    }

    static func failsAutomaticSendOnServerError(_ name: String, automaticFloodWait: Bool) -> Bool {
        // Automatic scheduled sends opt out of FLOOD_WAIT retries at their call
        // sites. A 500 retry also reuses the serialized date, so repeated server
        // errors can turn a scheduled send into an immediate send. Surface the
        // failure instead; the queue's Retry action builds a fresh schedule.
        guard scheduleOutgoingMessages, !automaticFloodWait else { return false }
        switch name {
        case "messages.sendMessage", "messages.sendMedia", "messages.sendMultiMedia",
             "messages.forwardMessages", "messages.sendInlineBotResult":
            return true
        default:
            return false
        }
    }

    static func suppressesRequest(_ name: String) -> Bool {
        switch name {
        case "account.updateStatus", "messages.setTyping", "messages.setEncryptedTyping",
             "messages.readHistory", "channels.readHistory",
             "messages.readEncryptedHistory", "messages.readDiscussion",
             "messages.readSavedHistory", "messages.readMessageContents",
             "channels.readMessageContents", "messages.readReactions",
             "messages.readMentions", "messages.reportReadMetrics",
             "messages.readPollVotes", "stories.readStories", "stories.incrementStoryViews":
            return true
        default:
            return false
        }
    }
}
