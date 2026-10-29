@main
struct SideloadPrivacyTests {
    static func main() {
        // Real RPC names: all chat read / typing routes must be blocked while
        // authentication, receiving, sending and server privacy configuration stay usable.
        for method in [
            "messages.setTyping", "messages.setEncryptedTyping",
            "messages.readHistory", "channels.readHistory",
            "messages.readEncryptedHistory", "messages.readDiscussion",
            "messages.readSavedHistory", "messages.readMessageContents",
            "channels.readMessageContents", "messages.readReactions", "messages.readPollVotes", "stories.readStories", "stories.incrementStoryViews"
        ] {
            precondition(SideloadPrivacy.suppressesRequest(method), "Leaked activity RPC: \(method)")
        }
        for method in [
            "auth.sendCode", "auth.signIn", "messages.getHistory",
            "updates.getDifference", "messages.sendMessage", "messages.sendMedia",
            "messages.sendEncrypted", "account.setPrivacy", "account.updateStatus"
        ] {
            precondition(!SideloadPrivacy.suppressesRequest(method), "Blocked normal operation: \(method)")
        }
        precondition(SideloadPrivacy.hideReadReceipts)
        precondition(SideloadPrivacy.forcesOfflineStatus("account.updateStatus"))
        precondition(!SideloadPrivacy.forcesOfflineStatus("messages.sendMessage"))
        print("Sideload privacy policy tests passed")
    }
}
