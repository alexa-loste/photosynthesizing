import Foundation

enum APIError: Error, LocalizedError {
    case notConfigured
    case http(status: Int, body: String)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No server address or access key set yet."
        case .http(let status, let body):
            return "Server returned \(status): \(body)"
        case .transport(let error):
            return error.localizedDescription
        }
    }
}

/// Where the daemon lives and how to authenticate to it.
///
/// Stored in a shared App Group container rather than plain UserDefaults so the widget
/// extension — a separate process — can read the same values without a second setup step.
struct ServerConfig: Codable, Equatable {
    var baseURL: URL
    var token: String

    static let appGroup = "group.com.alexa.toreply"
    private static let key = "toreply.serverConfig"

    private static var store: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static func load() -> ServerConfig? {
        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ServerConfig.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.store.set(data, forKey: Self.key)
    }

    static func clear() { store.removeObject(forKey: key) }
}

actor APIClient {
    private let config: ServerConfig
    private let session: URLSession

    init(config: ServerConfig) {
        self.config = config
        let configuration = URLSessionConfiguration.default
        // The Mac mini is on the same tailnet, so requests are fast or the box is asleep.
        // A short timeout surfaces "mini is unreachable" quickly instead of hanging.
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    private func request(
        _ path: String, method: String = "GET", body: (any Encodable)? = nil
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: config.baseURL) else {
            throw APIError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.http(
                status: http.statusCode,
                body: String(decoding: data, as: UTF8.self)
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Reads

    func threads(bucket: TriageState?, people: PeopleFilter) async throws -> ThreadListResponse {
        let bucketValue = bucket?.rawValue ?? "all"
        return try await send(
            request("api/threads?bucket=\(bucketValue)&people=\(people.rawValue)"),
            as: ThreadListResponse.self
        )
    }

    /// `before` pages backwards through history: pass the oldest ROWID you already hold.
    func messages(key: String, limit: Int = 60, before: Int64? = nil) async throws -> [Message] {
        let encoded = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        var path = "api/threads/\(encoded)/messages?limit=\(limit)"
        if let before { path += "&before=\(before)" }
        return try await send(request(path), as: [Message].self)
    }

    /// Absolute URL for an attachment's bytes, returned rather than fetched so
    /// `AsyncImage` can stream and cache it instead of us buffering every photo in
    /// memory. `AsyncImage` can't attach headers, so the key rides in the query string —
    /// which the API accepts, and which never leaves the tailnet.
    nonisolated func attachmentURL(id: Int64) -> URL? {
        guard var components = URLComponents(
            url: config.baseURL.appendingPathComponent("api/attachments/\(id)"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.queryItems = [URLQueryItem(name: "k", value: config.token)]
        return components.url
    }

    /// Searches people and conversation titles across all history — including chats far
    /// older than the inbox's lookback window, which is the whole point of having it.
    func search(_ query: String) async throws -> ThreadListResponse {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        return try await send(request("api/search?q=\(encoded)"), as: ThreadListResponse.self)
    }

    func summary(people: PeopleFilter = .known, limit: Int = 5) async throws -> WidgetSummary {
        try await send(
            request("api/summary?people=\(people.rawValue)&limit=\(limit)"),
            as: WidgetSummary.self
        )
    }

    // MARK: - Writes

    private struct Ack: Decodable { var ok: Bool }

    private struct StateBody: Encodable {
        var state: String
        var snoozeUntil: Double
    }
    private struct FavoriteBody: Encodable { var favorite: Bool }
    private struct CategoryBody: Encodable { var category: String }
    private struct SendBody: Encodable { var body: String }

    private func encodedKey(_ key: String) -> String {
        key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
    }

    @discardableResult
    func setState(
        key: String, state: TriageState, snoozeUntil: Double = 0
    ) async throws -> Bool {
        let payload = StateBody(state: state.rawValue, snoozeUntil: snoozeUntil)
        return try await send(
            request("api/threads/\(encodedKey(key))/state", method: "POST", body: payload),
            as: Ack.self
        ).ok
    }

    @discardableResult
    func setFavorite(key: String, favorite: Bool) async throws -> Bool {
        try await send(
            request(
                "api/threads/\(encodedKey(key))/favorite",
                method: "POST",
                body: FavoriteBody(favorite: favorite)
            ),
            as: Ack.self
        ).ok
    }

    /// Pass nil to clear the override and fall back to the automatic classification.
    @discardableResult
    func setCategory(key: String, category: SenderCategory?) async throws -> Bool {
        try await send(
            request(
                "api/threads/\(encodedKey(key))/category",
                method: "POST",
                body: CategoryBody(category: category?.rawValue ?? "auto")
            ),
            as: Ack.self
        ).ok
    }

    @discardableResult
    func send(key: String, body: String) async throws -> Bool {
        try await send(
            request("api/threads/\(encodedKey(key))/send", method: "POST", body: SendBody(body: body)),
            as: Ack.self
        ).ok
    }

    // MARK: - Live updates

    /// Yields once per server-sent "messages" event. The daemon polls chat.db and pushes
    /// when the newest message ROWID changes, so this fires when a text actually arrives.
    nonisolated func events() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        var request = try await self.request("api/events")
                        request.timeoutInterval = 3600
                        let (bytes, _) = try await self.session.bytes(for: request)
                        for try await line in bytes.lines {
                            if Task.isCancelled { break }
                            if line.hasPrefix("event: messages") { continuation.yield(()) }
                        }
                    } catch {
                        // iOS suspends connections when the app backgrounds; just retry.
                    }
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Lets `request(body:)` take any Encodable without making the method generic, which
/// would otherwise force every call site to spell out the type.
private struct AnyEncodable: Encodable {
    private let encodeTo: (Encoder) throws -> Void
    init(_ wrapped: any Encodable) {
        encodeTo = { encoder in try wrapped.encode(to: encoder) }
    }
    func encode(to encoder: Encoder) throws { try encodeTo(encoder) }
}
