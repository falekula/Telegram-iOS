import Foundation
import Postbox

/// Local-only metadata: never serialized into an outgoing Telegram message.
public final class LocalMessageStateAttribute: MessageAttribute {
    public let deleted: Bool
    public let retainedMedia: Bool
    public let previousTexts: [String]
    /// Original sender's timer, even after the local countdown is removed.
    /// `viewOnceTimeout` means one view. Nil includes legacy saved media whose
    /// original timer was discarded by older builds; do not guess its mode.
    public let originalMediaTimeout: Int32?

    public init(deleted: Bool = false, retainedMedia: Bool = false, previousTexts: [String] = [], originalMediaTimeout: Int32? = nil) {
        self.deleted = deleted
        self.retainedMedia = retainedMedia
        self.previousTexts = Array(previousTexts.suffix(30))
        self.originalMediaTimeout = originalMediaTimeout
    }

    public init(decoder: PostboxDecoder) {
        self.deleted = decoder.decodeBoolForKey("d", orElse: false)
        self.retainedMedia = decoder.decodeBoolForKey("m", orElse: false)
        self.previousTexts = Array(decoder.decodeStringArrayForKey("v").suffix(30))
        self.originalMediaTimeout = decoder.decodeOptionalInt32ForKey("t")
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeBool(self.deleted, forKey: "d")
        encoder.encodeBool(self.retainedMedia, forKey: "m")
        encoder.encodeStringArray(self.previousTexts, forKey: "v")
        if let originalMediaTimeout = self.originalMediaTimeout {
            encoder.encodeInt32(originalMediaTimeout, forKey: "t")
        } else {
            encoder.encodeNil(forKey: "t")
        }
    }
}
