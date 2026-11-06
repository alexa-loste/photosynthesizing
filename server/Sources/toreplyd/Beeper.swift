import Foundation

/// WhatsApp, Instagram, Messenger and the rest, through Beeper Desktop's local API
/// (https://developers.beeper.com/desktop-api-reference) on this same Mac.
///
/// Beeper chats join the inbox as threads keyed `bp:<chat id>`, so triage, favourites and
/// keep-in-touch work on them unchanged. Two stand-ins make that possible:
///
///  - `lastRowID` is the chat's last activity in milliseconds. Triage only ever compares a
///    thread's lastRowID with the one it recorded for that same thread, so any number that
///    grows with each new message works, and "done as of message N" keeps its meaning.
///  - `chatRowIDs` is empty, which keeps Beeper threads out of everything that reads
///    chat.db directly.
///
/// Off unless ~/.toreply/beeper-token exists. Any failure (Beeper quit, token revoked)
/// leaves the inbox at iMessage only rather than failing the request.
final class Beeper {

    static let tokenPath = NSString(string: "~/.toreply/beeper-token").expandingTildeInPath
    static let keyPrefix = "bp:"

    private let base = URL(string: "http://localhost:23373/v1/")!
    private let token: String
    private let session: URLSession

    private let lock = NSLock()
    /// Thread key → Beeper image URL (mxc://, file://, or a bare local path).
    private var avatarSources: [String: String] = [:]
    /// Attachment id handed to clients → Beeper's URL for it. The shared Attachment model
    /// has integer ids (chat.db ROWIDs), so Beeper's mxc:// URLs get a negative stand-in
    /// that can't collide with a ROWID.
    private var attachmentSources: [Int64: (url: String, mimeType: String)] = [:]
    private var cached: [ThreadGroup] = []
    private var cachedAt: Double = 0
    private static let maxCacheAge: Double = 15

    init?() {
        guard let raw = try? String(contentsOfFile: Self.tokenPath, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        token = trimmed
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        session = URLSession(configuration: configuration)
    }

    static func isBeeperKey(_ key: String) -> Bool { key.hasPrefix(keyPrefix) }

    // MARK: - Wire types

    private struct Page<Item: Decodable>: Decodable {
        var items: [Item]
    }

    private struct User: Decodable {
        var id: String?
        var fullName: String?
        var username: String?
        var phoneNumber: String?
        var isSelf: Bool?
        var imgURL: String?

        var name: String { fullName ?? username ?? phoneNumber ?? id ?? "?" }
    }

    private struct Participants: Decodable { var items: [User] }

    private struct WireAttachment: Decodable {
        var id: String?
        var srcURL: String?
        var type: String?
        var mimeType: String?
        var fileName: String?
        var fileSize: Double?
        var isSticker: Bool?
    }

    private struct WireReaction: Decodable {
        var reactionKey: String?
        var participantID: String?
    }

    private struct WireMessage: Decodable {
        var id: String
        var senderID: String?
        var senderName: String?
        var timestamp: String
        var text: String?
        var type: String?
        var isSender: Bool?
        var isDeleted: Bool?
        var isHidden: Bool?
        var editedTimestamp: String?
        var attachments: [WireAttachment]?
        var reactions: [WireReaction]?
    }

    private struct Chat: Decodable {
        var id: String
        var accountID: String
        var network: String?
        var title: String
        var type: String
        var lastActivity: String?
        var isArchived: Bool?
        var isLowPriority: Bool?
        var isMuted: Bool?
        var participants: Participants?
        var preview: WireMessage?
        var imgURL: String?
    }

    private struct SendResult: Decodable { var pendingMessageID: String }

    // MARK: - HTTP

    private func call<T: Decodable>(
        _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil
    ) throws -> T {
        try JSONDecoder().decode(T.self, from: try callData(path, query: query, body: body))
    }

    private func callData(
        _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil
    ) throws -> Data {
        guard var components = URLComponents(url: base.appendingPathComponent(path),
                                             resolvingAgainstBaseURL: false) else {
            throw BeeperError("bad path \(path)")
        }
        if !query.isEmpty { components.queryItems = query }
        // A chat id's "!" and ":" are legal in a path segment and go as-is, as in
        // Beeper's own examples.
        guard let url = components.url else { throw BeeperError("bad url for \(path)") }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // The API layer is synchronous (one serial queue), so block on the response.
        var result: Result<Data, Error> = .failure(BeeperError("no response"))
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error { result = .failure(error); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status), let data else {
                let detail = data.map { String(decoding: $0.prefix(200), as: UTF8.self) } ?? ""
                result = .failure(BeeperError("HTTP \(status) \(detail)"))
                return
            }
            result = .success(data)
        }.resume()
        done.wait()
        return try result.get()
    }

    // MARK: - Threads

    /// Recent Beeper chats as inbox threads, newest first. iMessage is skipped: chat.db
    /// already has it, with more detail than Beeper's copy.
    func threadGroups(limit: Int = 100) -> [ThreadGroup] {
        let now = Date().timeIntervalSince1970
        lock.lock()
        if now - cachedAt < Self.maxCacheAge {
            defer { lock.unlock() }
            return cached
        }
        lock.unlock()

        let groups: [ThreadGroup]
        do {
            let page: Page<Chat> = try call("chats", query: [URLQueryItem(name: "limit", value: "\(limit)")])
            groups = page.items.compactMap { Self.group(from: $0) }
            var sources: [String: String] = [:]
            for chat in page.items {
                // A DM's own image is usually empty; the other person's picture is the one
                // you'd recognise.
                let other = chat.participants?.items.first { $0.isSelf != true }?.imgURL
                let source = chat.imgURL ?? (chat.type == "single" ? other : nil)
                if let source, !source.isEmpty { sources[Self.keyPrefix + chat.id] = source }
            }
            lock.lock()
            avatarSources = sources
            lock.unlock()
        } catch {
            FileHandle.standardError.write("beeper: chats failed: \(error)\n".data(using: .utf8)!)
            groups = []
        }

        lock.lock()
        cached = groups
        cachedAt = now
        lock.unlock()
        return groups
    }

    func invalidate() {
        lock.lock()
        cachedAt = 0
        lock.unlock()
    }

    /// Newest activity across Beeper chats, for the poll loop's change probe.
    func newestActivity() -> Int64 {
        threadGroups().map(\.lastRowID).max() ?? 0
    }

    /// Same lookback as the chat.db inbox, so an untouched 2023 Instagram DM doesn't
    /// count as owing a reply.
    static let lookbackDays: Double = 180

    private static func group(from chat: Chat, requireRecent: Bool = true) -> ThreadGroup? {
        let network = chat.network ?? chat.accountID
        let lowered = network.lowercased()
        // iMessage comes from chat.db; "Beeper (Matrix)" is Beeper's own support and
        // announcement rooms, not people.
        if lowered.contains("imessage") || lowered.contains("beeper") { return nil }
        if chat.isArchived == true || chat.isLowPriority == true { return nil }
        let preview = chat.preview
        if requireRecent && preview == nil { return nil }

        let date = parseDate(chat.lastActivity ?? preview?.timestamp ?? "")
        if requireRecent && date < Date().timeIntervalSince1970 - lookbackDays * 86_400 { return nil }
        let others = (chat.participants?.items ?? []).filter { $0.isSelf != true }
        let isGroup = chat.type == "group"
        let lastMessage = MessagePreview(
            rowID: Int64(date * 1000),
            date: date,
            isFromMe: preview?.isSender == true,
            text: preview.map(summary(of:)) ?? "",
            sender: preview?.isSender == true ? nil : preview?.senderName
        )
        return ThreadGroup(
            key: keyPrefix + chat.id,
            chatRowIDs: [],
            sendGUID: chat.id,
            chatIdentifier: chat.id,
            title: chat.title,
            isGroup: isGroup,
            service: network,
            handles: others.map(\.name),
            lastMessage: lastMessage,
            lastRowID: Int64(date * 1000),
            needsReply: preview.map { $0.isSender != true } ?? false,
            // Muted chats are kept out of "People" the way shortcodes are.
            category: chat.isMuted == true ? .automated : .known
        )
    }

    // MARK: - Messages

    func messages(key: String) throws -> [Message] {
        let chatID = String(key.dropFirst(Self.keyPrefix.count))
        let page: Page<WireMessage> = try call("chats/\(chatID)/messages")
        return page.items
            .filter { $0.isDeleted != true && $0.isHidden != true && $0.type != "REACTION" }
            .map { wire in
                let date = Self.parseDate(wire.timestamp)
                return Message(
                    rowID: Int64(wire.id) ?? Int64(date * 1000),
                    guid: wire.id,
                    date: date,
                    isFromMe: wire.isSender == true,
                    text: Self.summary(of: wire),
                    sender: wire.isSender == true ? "" : (wire.senderName ?? ""),
                    hasAttachments: !(wire.attachments ?? []).isEmpty,
                    isEdited: wire.editedTimestamp != nil,
                    service: "",
                    isDelivered: true,
                    reactions: (wire.reactions ?? []).compactMap { reaction in
                        reaction.reactionKey.map { Reaction(emoji: $0, fromMe: false, sender: reaction.participantID ?? "") }
                    },
                    attachments: (wire.attachments ?? []).compactMap(register)
                )
            }
            .sorted { $0.date < $1.date }
    }

    private func register(_ wire: WireAttachment) -> Attachment? {
        guard let url = wire.srcURL ?? wire.id, !url.isEmpty else { return nil }
        let mimeType = wire.mimeType ?? (wire.type == "img" ? "image/jpeg" : "application/octet-stream")
        let id = Self.standInID(for: url)
        lock.lock()
        attachmentSources[id] = (url, mimeType)
        lock.unlock()
        return Attachment(
            id: id,
            name: wire.fileName ?? "",
            uti: "",
            mimeType: mimeType,
            isSticker: wire.isSticker == true,
            bytes: Int64(wire.fileSize ?? 0),
            isImage: wire.type == "img" || mimeType.hasPrefix("image/")
        )
    }

    /// FNV-1a of the URL with the sign bit set: stable across restarts, always negative.
    private static func standInID(for url: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Int64(bitPattern: hash | 0x8000_0000_0000_0000)
    }

    /// Bytes for an attachment id from `messages(key:)`, via Beeper's asset server.
    func attachment(id: Int64) -> (data: Data, mimeType: String)? {
        lock.lock()
        let source = attachmentSources[id]
        lock.unlock()
        guard let source else { return nil }
        var url = source.url
        if url.hasPrefix("/") { url = "file://" + url }
        guard let data = try? callData("assets/serve", query: [URLQueryItem(name: "url", value: url)]) else {
            return nil
        }
        return (data, source.mimeType)
    }

    func send(key: String, text: String) throws {
        let chatID = String(key.dropFirst(Self.keyPrefix.count))
        let _: SendResult = try call("chats/\(chatID)/messages", body: ["text": text])
        invalidate()
    }

    func react(key: String, messageID: String, emoji: String) throws {
        let chatID = String(key.dropFirst(Self.keyPrefix.count))
        struct Ack: Decodable {}
        let _: Ack = try call("chats/\(chatID)/messages/\(messageID)/reactions", body: ["reactionKey": emoji])
    }

    /// Chats whose title matches, through Beeper's own search, so people you haven't
    /// talked to lately (or whose history Beeper hasn't loaded) can still be found.
    func search(_ query: String, limit: Int = 20) -> [ThreadGroup] {
        let page: Page<Chat>? = try? call("chats/search", query: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "scope", value: "titles"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ])
        return (page?.items ?? []).compactMap { Self.group(from: $0, requireRecent: false) }
    }

    /// The chat's picture through Beeper's asset server, which fetches remote (mxc://)
    /// images on demand and caches them.
    func avatar(key: String) -> Data? {
        _ = threadGroups()
        lock.lock()
        let source = avatarSources[key]
        lock.unlock()
        guard var url = source else { return nil }
        if url.hasPrefix("/") { url = "file://" + url }
        return try? callData("assets/serve", query: [URLQueryItem(name: "url", value: url)])
    }

    // MARK: - Helpers

    private static func summary(of message: WireMessage) -> String {
        if let text = message.text, !text.isEmpty { return unescapeHTML(text) }
        switch message.type {
        case "IMAGE": return "📷 Photo"
        case "VIDEO": return "🎥 Video"
        case "VOICE", "AUDIO": return "🎤 Voice message"
        case "STICKER": return "Sticker"
        case "LOCATION": return "📍 Location"
        case "FILE": return "📎 File"
        default: return (message.attachments ?? []).isEmpty ? "" : "📎 Attachment"
        }
    }

    /// Some bridges hand back text with HTML entities left in ("&quot;Too many…").
    private static func unescapeHTML(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
                ("&nbsp;", " "), ("&amp;", "&")]
            .reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let whole = ISO8601DateFormatter()

    static func parseDate(_ string: String) -> Double {
        (fractional.date(from: string) ?? whole.date(from: string))?.timeIntervalSince1970 ?? 0
    }
}

struct BeeperError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
