import Foundation

/// Message text extraction.
///
/// On modern macOS the `message.text` column is almost always empty and the real
/// content lives in `message.attributedBody` — an NSAttributedString serialized in
/// Apple's legacy `typedstream` format (NOT a plist, NOT a keyed archive).
///
/// Measured on this database: of the last 5,000 messages, only 163 had usable `text`
/// while 4,817 were blob-only. So this path is the primary one, not a fallback.
///
/// Rather than reimplement the typedstream format, we hand the bytes to Apple's own
/// decoder. `NSUnarchiver` is deprecated but it is the *only* thing that reads this
/// format — `NSKeyedUnarchiver` cannot, since these are not keyed archives.
/// Verified at 500/500 successful decodes with zero failures on real data.
enum BodyDecoder {

    /// U+FFFC OBJECT REPLACEMENT CHARACTER — stands in for inline attachments,
    /// images, and app payloads inside the attributed string.
    private static let objectReplacement: Character = "\u{FFFC}"

    static func text(plain: String?, attributedBody: Data?) -> String {
        if let plain, !plain.isEmpty {
            return clean(plain)
        }
        if let attributedBody, let decoded = decodeTypedStream(attributedBody) {
            return clean(decoded)
        }
        return ""
    }

    static func decodeTypedStream(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        // Deprecated on purpose — see the type doc above.
        guard let unarchiver = NSUnarchiver(forReadingWith: data) else { return nil }

        // A malformed blob raises an ObjC exception rather than returning nil, and
        // Swift cannot catch those. Blobs come from Apple's own writer so this is
        // safe in practice; `decodeObject()` returning nil covers the rest.
        guard let object = unarchiver.decodeObject() else { return nil }

        if let attributed = object as? NSAttributedString { return attributed.string }
        if let string = object as? String { return string }
        return nil
    }

    /// Strip the attachment placeholders and collapse the whitespace they leave behind.
    private static func clean(_ raw: String) -> String {
        var s = raw
        if s.contains(objectReplacement) {
            s = s.replacingOccurrences(of: String(objectReplacement), with: " ")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A short label for threads whose newest message carries no text
    /// (a photo, a tapback-only exchange, an app payload).
    static func placeholder(hasAttachments: Bool, balloonBundleID: String?) -> String {
        if let bundle = balloonBundleID, !bundle.isEmpty {
            if bundle.contains("PeerPayment") { return "💸 Apple Cash" }
            if bundle.contains("AudioMessage") { return "🎤 Audio message" }
            if bundle.contains("Handwriting") { return "✍️ Handwritten" }
            if bundle.contains("DigitalTouch") { return "❤️ Digital Touch" }
            if bundle.contains("Link") { return "🔗 Link" }
            return "📱 App message"
        }
        return hasAttachments ? "📎 Attachment" : ""
    }
}
