import Foundation
import Postbox

/// Local-only metadata: never serialized into an outgoing Telegram message.
public final class LocalMessageStateAttribute: MessageAttribute {
    public let deleted: Bool
    public let retainedMedia: Bool
    public let previousTexts: [String]

    public init(deleted: Bool = false, retainedMedia: Bool = false, previousTexts: [String] = []) {
        self.deleted = deleted
        self.retainedMedia = retainedMedia
        self.previousTexts = Array(previousTexts.suffix(30))
    }

    public init(decoder: PostboxDecoder) {
        self.deleted = decoder.decodeBoolForKey("d", orElse: false)
        self.retainedMedia = decoder.decodeBoolForKey("m", orElse: false)
        self.previousTexts = decoder.decodeStringArrayForKey("v")
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeBool(self.deleted, forKey: "d")
        encoder.encodeBool(self.retainedMedia, forKey: "m")
        encoder.encodeStringArray(self.previousTexts, forKey: "v")
    }
}
