import Foundation

/// The keep-in-touch half of To Reply's API (`/api/nudges` and friends). Kept here
/// rather than in the shared iOS client until the phone app grows the same feature.
struct NudgeResponse: Decodable {
    struct Nudge: Decodable, Identifiable, Hashable {
        var key: String
        var title: String
        var isGroup: Bool
        var service: String?
        var cadenceDays: Int
        var lastContact: Double?
        var lastTexted: Double?
        var lastFromMe: Bool?
        var lastCalled: Double?
        var callsOnly: Bool?
        /// "MM-dd" from their contact card.
        var birthday: String?
        var dueAt: Double
        var id: String { key }
    }

    struct Suggestion: Decodable, Identifiable, Hashable {
        var key: String
        var title: String
        var firstContact: Double
        var messageCount: Int
        /// Optional so the strip still decodes from a server older than this field.
        var preview: String?
        var lastFromMe: Bool?
        var id: String { key }
    }

    var due: [Nudge]
    var upcoming: [Nudge]
    var suggestions: [Suggestion]
}

enum Birthday {
    /// Days until the next "MM-dd", 0 on the day itself; nil when it doesn't parse.
    static func daysUntil(_ monthDay: String?, from now: Date = Date()) -> Int? {
        guard let monthDay else { return nil }
        let parts = monthDay.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: today)
        for offset in 0...1 {
            var components = DateComponents(year: year + offset, month: parts[0], day: parts[1])
            components.hour = 0
            guard let date = calendar.date(from: components), date >= today else { continue }
            return calendar.dateComponents([.day], from: today, to: date).day
        }
        return nil
    }
}

enum Cadence {
    static let choices: [(days: Int, label: String)] = [
        (7, "Every week"), (14, "Every 2 weeks"), (30, "Every month"), (90, "Every 3 months"),
    ]

    static func label(_ days: Int) -> String {
        switch days {
        case 7: return "every week"
        case 14: return "every 2 wk"
        case 30: return "every month"
        case 90: return "every 3 mo"
        default: return "every \(days)d"
        }
    }
}

struct KeepInTouchClient {
    let config: ServerConfig

    private func call<T: Decodable>(_ path: String, body: [String: Any]? = nil) async throws -> T {
        guard let url = URL(string: path, relativeTo: config.baseURL) else {
            throw APIError.notConfigured
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct Ack: Decodable { var ok: Bool }

    private func encoded(_ key: String) -> String {
        key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
    }

    /// Avatar image URL. AsyncImage can't send headers, so the key rides in the query
    /// string, as with attachments; it never leaves the tailnet.
    func avatarURL(key: String) -> URL? {
        let token = config.token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: "api/threads/\(encoded(key))/avatar?k=\(token)", relativeTo: config.baseURL)
    }

    func nudges() async throws -> NudgeResponse {
        try await call("api/nudges")
    }

    /// `days == 0` stops tracking and stops suggesting this person.
    /// A nil `callsOnly` leaves that setting as it is.
    func setCadence(key: String, days: Int, title: String, callsOnly: Bool? = nil) async throws {
        var body: [String: Any] = ["days": days, "title": title]
        if let callsOnly { body["callsOnly"] = callsOnly }
        let _: Ack = try await call("api/threads/\(encoded(key))/cadence", body: body)
    }

    /// WhatsApp, Instagram and Messenger only; the server refuses iMessage.
    func react(key: String, messageID: String, emoji: String) async throws {
        let _: Ack = try await call(
            "api/threads/\(encoded(key))/messages/\(encoded(messageID))/react", body: ["emoji": emoji]
        )
    }

    func snooze(key: String, until: Double) async throws {
        let _: Ack = try await call("api/threads/\(encoded(key))/nudge", body: ["snoozeUntil": until])
    }
}

/// Opens a conversation in the Messages app itself. Only one-to-one threads have a
/// handle to address; group keys are opaque.
enum MessagesApp {
    /// Beeper threads have no Messages handle; the strip opens those in Beeper instead
    /// (not wired yet: Beeper's API is on the mini, not this Mac).
    static func url(forKey key: String) -> URL? {
        guard key.hasPrefix("dm:") else { return nil }
        let handle = String(key.dropFirst(3))
        return URL(string: "imessage:" + (handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle))
    }

    /// Starts a FaceTime audio call, which reaches a phone number through your iPhone
    /// as a normal call when FaceTime isn't available.
    static func callURL(forKey key: String) -> URL? {
        guard key.hasPrefix("dm:") else { return nil }
        let handle = String(key.dropFirst(3))
        return URL(string: "facetime-audio:" + (handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle))
    }
}
