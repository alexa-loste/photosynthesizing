import Foundation

// Codable mirrors of the toreplyd JSON API.
//
// These are shared by the app and the widget extension, so they deliberately depend on
// Foundation only — no SwiftUI, no UIKit. That also means they compile and typecheck
// with the Command Line Tools compiler, without a full Xcode install.

/// Declaration order is the tab order in the UI — To Reply, then the two "not now"
/// states, then Done — so it matches the web app.
enum TriageState: String, Codable, CaseIterable {
    case toReply = "to_reply"
    case followUp = "follow_up"
    case snoozed
    case done

    var title: String {
        switch self {
        case .toReply: return "To Reply"
        case .snoozed: return "Later"
        case .followUp: return "Follow Up"
        case .done: return "Done"
        }
    }
}

enum SenderCategory: String, Codable {
    case known, unknown, automated
}

enum PeopleFilter: String, CaseIterable {
    case known, groups, favorites, unknown, automated, all

    var title: String {
        switch self {
        case .known: return "People"
        case .groups: return "Groups"
        case .favorites: return "Favorites"
        case .unknown: return "Unknown"
        case .automated: return "Robots"
        case .all: return "Everything"
        }
    }
}

struct MessagePreview: Codable, Hashable {
    var rowID: Int64
    var date: Double
    var isFromMe: Bool
    var text: String
    var sender: String?
}

struct ThreadSummary: Codable, Identifiable, Hashable {
    var key: String
    var sendGUID: String
    var title: String
    var isGroup: Bool
    var service: String
    var participants: [String]
    var handles: [String]
    var lastMessage: MessagePreview
    var needsReply: Bool
    var state: TriageState
    var favorite: Bool
    var lastRowID: Int64
    var category: SenderCategory
    /// When a snoozed thread returns to To Reply; nil unless snoozed (or an older server).
    var snoozeUntil: Double?

    var id: String { key }
}

struct Reaction: Codable, Hashable {
    var emoji: String
    var fromMe: Bool
    var sender: String
}

struct Attachment: Codable, Hashable, Identifiable {
    var id: Int64
    var name: String
    var uti: String
    var mimeType: String
    var isSticker: Bool
    var bytes: Int64
    var isImage: Bool

    var isVideo: Bool { mimeType.hasPrefix("video/") }

    /// Human-readable size for the non-image chip.
    var sizeLabel: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct Message: Codable, Identifiable, Hashable {
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
    var reactions: [Reaction]
    var attachments: [Attachment]

    var id: Int64 { rowID }

    /// A sticker sent on its own has no text and shouldn't get a bubble around it —
    /// Messages floats it bare over the transcript.
    var isBareSticker: Bool {
        text.isEmpty && attachments.count == 1 && attachments[0].isSticker
    }

    /// Messages colours SMS and RCS green rather than iMessage blue.
    var isGreen: Bool { service == "SMS" || service == "RCS" }
}

struct ThreadListResponse: Codable {
    var threads: [ThreadSummary]
    var counts: [String: Int]
    var generatedAt: Double
}

/// Small payload for the home-screen widget. Widget timeline refreshes run under a tight
/// memory and time budget, so this carries counts plus a handful of trimmed previews
/// instead of the full thread list.
struct WidgetSummary: Codable {
    struct Item: Codable, Identifiable, Hashable {
        var key: String
        var title: String
        var preview: String
        var date: Double
        var isGroup: Bool

        var id: String { key }
    }

    var toReply: Int
    var followUp: Int
    var snoozed: Int
    var favorites: Int
    var top: [Item]
    var generatedAt: Double
}

// MARK: - Formatting shared by the app and the widget

enum Format {
    static func relative(_ unixSeconds: Double, now: Date = Date()) -> String {
        let delta = now.timeIntervalSince1970 - unixSeconds
        if delta < 60 { return "now" }
        if delta < 3600 { return "\(Int(delta / 60))m" }
        if delta < 86_400 { return "\(Int(delta / 3600))h" }
        if delta < 604_800 { return "\(Int(delta / 86_400))d" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: Date(timeIntervalSince1970: unixSeconds))
    }

    static func clock(_ unixSeconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: Date(timeIntervalSince1970: unixSeconds))
    }

    static func initials(_ title: String) -> String {
        let words = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard let first = words.first else { return "?" }
        if words.count == 1 { return String(first.prefix(2)).uppercased() }
        let second = words[1]
        return (String(first.prefix(1)) + String(second.prefix(1))).uppercased()
    }

    /// Stable per-thread hue so an avatar keeps its colour between launches.
    static func avatarHue(_ key: String) -> Double {
        var hash: Int32 = 0
        for scalar in key.unicodeScalars {
            hash = hash &* 31 &+ Int32(truncatingIfNeeded: scalar.value)
        }
        return Double(abs(Int(hash)) % 360) / 360.0
    }

    /// Snooze target used by the swipe action: the next 9am.
    static func nextMorning(from now: Date = Date()) -> Double {
        var calendar = Calendar.current
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 9
        components.minute = 0
        components.second = 0
        var target = calendar.date(from: components) ?? now
        if target <= now {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? target
        }
        return target.timeIntervalSince1970
    }
}
