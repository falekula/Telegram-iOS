// Privacy policy for this personal sideload build. Sending a message can still
// reveal activity on Telegram's servers; no client can promise invisibility then.
enum SideloadPrivacy {
    static let hideReadReceipts = true
    static let hideOnline = true

    static func forcesOfflineStatus(_ name: String) -> Bool {
        return hideOnline && name == "account.updateStatus"
    }

    static func suppressesRequest(_ name: String) -> Bool {
        switch name {
        case "messages.setTyping", "messages.setEncryptedTyping",
             "messages.readHistory", "channels.readHistory",
             "messages.readEncryptedHistory", "messages.readDiscussion",
             "messages.readSavedHistory", "messages.readMessageContents",
             "channels.readMessageContents", "messages.readReactions",
             "messages.readPollVotes", "stories.readStories", "stories.incrementStoryViews":
            return true
        default:
            return false
        }
    }
}
