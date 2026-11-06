import Foundation

/// Apple stores dates as (nano)seconds since 2001-01-01, not the Unix epoch.
enum AppleDate {
    static let epochOffset: Double = 978_307_200

    static func toUnix(_ raw: Int64) -> Double {
        guard raw != 0 else { return 0 }
        // Modern macOS writes nanoseconds; much older rows are plain seconds.
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return seconds + epochOffset
    }

    static func fromUnix(_ unix: Double) -> Int64 {
        Int64((unix - epochOffset) * 1_000_000_000)
    }
}

struct MessagePreview: Codable {
    var rowID: Int64
    var date: Double
    var isFromMe: Bool
    var text: String
    /// Display name of the sender; nil when the message is from me.
    var sender: String?
}

/// Named `ThreadSummary` rather than `Thread` — a module-level `Thread` type would
/// shadow `Foundation.Thread` everywhere in this target.
struct ThreadSummary: Codable {
    /// Stable identifier we mint by merging the duplicate chat rows Messages creates
    /// for the same person across services. This — not chat.guid — is what the UI and
    /// the triage database key on.
    var key: String
    /// The chat.guid to send to: whichever service they most recently used.
    var sendGUID: String
    var title: String
    var isGroup: Bool
    var service: String
    var participants: [String]
    var handles: [String]
    var lastMessage: MessagePreview
    /// True when the newest real message is not from me.
    var needsReply: Bool
    /// The resolved bucket this thread currently sits in.
    var state: TriageState = .toReply
    /// People you're deliberately keeping up with, findable regardless of triage state.
    var favorite: Bool = false
    /// Newest message ROWID — the client echoes this back when triaging so the decision
    /// is recorded against a specific point in the conversation.
    var lastRowID: Int64 = 0
    /// Whether this is someone you actually know. 63 of ~213 recent DM threads here are
    /// shortcodes — 2FA codes, delivery alerts, marketing. Mixing those into To Reply
    /// buries the friends you actually owe a reply to.
    var category: SenderCategory
    /// When a snoozed thread returns to To Reply (unix seconds); nil unless snoozed.
    var snoozeUntil: Double? = nil
}

enum SenderCategory: String, Codable {
    /// In your address book, or any group chat.
    case known
    /// A real phone number or email we can't put a name to.
    case unknown
    /// Short code (≤6 digits) — effectively always automated.
    case automated
}

struct Message: Codable {
    var rowID: Int64
    var guid: String
    var date: Double
    var isFromMe: Bool
    var text: String
    var sender: String
    var hasAttachments: Bool
    var isEdited: Bool
    var service: String
    var isDelivered: Bool
    var reactions: [Reaction] = []
    var attachments: [Attachment] = []
}

struct Attachment: Codable {
    var id: Int64
    /// Display name, e.g. "IMG_1234.HEIC".
    var name: String
    var uti: String
    var mimeType: String
    var isSticker: Bool
    var bytes: Int64
    /// Only images are worth rendering inline; everything else gets a chip.
    var isImage: Bool

    /// Messages stores a lot of things in the attachment table that aren't files you'd
    /// ever want to look at — app payloads for Apple Pay, link previews, Digital Touch.
    /// Those all land as `.pluginPayloadAttachment` and are noise if surfaced.
    var isPayload: Bool { uti.contains("pluginPayload") || name.hasSuffix(".pluginPayloadAttachment") }

    static func looksLikeImage(uti: String, mimeType: String) -> Bool {
        if mimeType.hasPrefix("image/") { return true }
        return [
            "public.jpeg", "public.png", "public.heic", "public.heif",
            "com.compuserve.gif", "public.tiff", "public.webp",
        ].contains(uti)
    }
}

/// A tapback attached to a message.
struct Reaction: Codable {
    var emoji: String
    var fromMe: Bool
    var sender: String
}

/// Tapbacks are stored as ordinary message rows pointing at a target.
/// 2000–2005 add a reaction, 3000–3005 remove the matching one; 2006/3006 carry a
/// custom emoji in `associated_message_emoji`.
enum TapbackKind {
    static func emoji(forType type: Int64, custom: String?) -> String? {
        if let custom, !custom.isEmpty { return custom }
        switch type % 1000 {
        case 0: return "❤️"
        case 1: return "👍"
        case 2: return "👎"
        case 3: return "😂"
        case 4: return "‼️"
        case 5: return "❓"
        default: return nil
        }
    }

    static func isAdd(_ type: Int64) -> Bool { (2000...2999).contains(type) }
    static func isRemove(_ type: Int64) -> Bool { (3000...3999).contains(type) }
}

/// All the chat rows that we've decided represent one human conversation.
struct ThreadGroup {
    var key: String
    var chatRowIDs: [Int64]
    var sendGUID: String
    var chatIdentifier: String
    var title: String
    var isGroup: Bool
    var service: String
    var handles: [String]
    var lastMessage: MessagePreview
    var lastRowID: Int64
    var needsReply: Bool
    var category: SenderCategory = .unknown
}
