@main
struct SideloadPrivacyTests {
    static func main() {
        // Real RPC names: all chat read / typing routes must be blocked while
        // authentication, receiving, sending and server privacy configuration stay usable.
        for method in [
            "account.updateStatus", "messages.setTyping", "messages.setEncryptedTyping",
            "messages.readHistory", "channels.readHistory",
            "messages.readEncryptedHistory", "messages.readDiscussion",
            "messages.readSavedHistory", "messages.readMessageContents",
            "channels.readMessageContents", "messages.readReactions", "messages.readPollVotes",
            "messages.readMentions", "messages.reportReadMetrics", "stories.readStories", "stories.incrementStoryViews"
        ] {
            precondition(SideloadPrivacy.suppressesRequest(method), "Leaked activity RPC: \(method)")
        }
        for method in [
            "auth.sendCode", "auth.signIn", "messages.getHistory",
            "updates.getDifference", "messages.sendMessage", "messages.sendMedia",
            "messages.sendEncrypted", "account.setPrivacy"
        ] {
            precondition(!SideloadPrivacy.suppressesRequest(method), "Blocked normal operation: \(method)")
        }
        precondition(SideloadPrivacy.hideReadReceipts)
        precondition(SideloadPrivacy.outgoingScheduleDelay(mediaBytes: nil) == 15)
        precondition(SideloadPrivacy.outgoingScheduleDelay(mediaBytes: 1) >= 15)
        precondition(SideloadPrivacy.outgoingScheduleDelay(mediaBytes: 5 * 1024 * 1024) >= 15)
        precondition(SideloadPrivacy.outgoingScheduleDelay(mediaBytes: nil, minimumDelay: 73) == 73)
        precondition(SideloadPrivacy.outgoingScheduleDelay(mediaBytes: nil, minimumDelay: -1) == 15)
        precondition(SideloadPrivacy.outgoingScheduleDelay(mediaBytes: nil, minimumDelay: Int32.max) == 300)
        precondition(SideloadPrivacy.outgoingScheduleDelay(mediaBytes: Int64.max) <= 300)
        print("Sideload privacy policy tests passed")
    }
}
