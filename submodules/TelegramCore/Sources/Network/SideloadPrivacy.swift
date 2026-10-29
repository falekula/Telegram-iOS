import Foundation

// Privacy policy for this personal sideload build. Sending a message can still
// reveal activity on Telegram's servers; no client can promise invisibility then.
enum SideloadPrivacy {
    static let hideReadReceipts = true
    static let hideOnline = true
    static let scheduleOutgoingMessages = true

    static func outgoingScheduleDelay(mediaBytes: Int64?) -> Int32 {
        // Telegram immediately sends schedule_date < 10 seconds in the future.
        // Keep at least 12 even for small media (the old AyuGram 6s minimum is
        // unsafe with the current API). Cap long delays at 5 minutes.
        guard let mediaBytes = mediaBytes, mediaBytes > 0 else { return 12 }
        return Int32(min(300.0, max(12.0, ceil(Double(mediaBytes) / 1048576.0 * 4.5))))
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
