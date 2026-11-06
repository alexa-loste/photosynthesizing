import Foundation
import Security

/// Shared-secret auth.
///
/// Tailscale is the real security boundary — the listener binds to loopback and only
/// `tailscale serve` can reach it, so traffic is already restricted to your own devices.
/// This token is a second layer so that anything else running on the Mac mini can't
/// simply curl your messages off localhost.
enum Token {
    static let path = NSString(string: "~/.toreply/token").expandingTildeInPath

    static func loadOrCreate() -> String {
        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        try? token.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path
        )
        return token
    }
}

final class API {

    private let service: ThreadService
    private let token: String
    private let webRoot: String

    init(service: ThreadService, token: String, webRoot: String) {
        self.service = service
        self.token = token
        self.webRoot = webRoot
    }

    func handle(_ request: HTTPRequest) -> HTTPOutcome {
        let parts = request.path.split(separator: "/").map(String.init)

        guard parts.first == "api" else {
            return .response(serveStatic(path: request.path))
        }
        guard isAuthorized(request) else {
            return .response(.error(401, "unauthorized"))
        }

        switch (request.method, Array(parts.dropFirst())) {

        case ("GET", ["health"]):
            struct Health: Encodable {
                var ok = true
                var messagesRunning: Bool
                var maxRowID: Int64
            }
            return .response(.json(Health(
                messagesRunning: Sender.isMessagesRunning(),
                maxRowID: service.currentMaxRowID()
            )))

        case ("GET", ["events"]):
            return .eventStream

        case ("GET", let route) where route.count == 2 && route[0] == "attachments":
            guard let id = Int64(route[1]) else {
                return .response(.error(400, "bad attachment id"))
            }
            do {
                guard let file = try service.attachmentFile(id: id),
                      let data = FileManager.default.contents(atPath: file.path) else {
                    return .response(.error(404, "no such attachment"))
                }
                var response = HTTPResponse.data(data, contentType: file.mimeType)
                // Attachment bytes never change once written, so let the client keep them.
                response.headers["Cache-Control"] = "private, max-age=31536000, immutable"
                return .response(response)
            } catch {
                return .response(.error(500, "\(error)"))
            }

        case ("GET", ["summary"]):
            let people = request.query["people"] ?? "known"
            let limit = min(Int(request.query["limit"] ?? "") ?? 5, 20)
            do {
                return .response(.json(try service.summary(people: people, limit: limit)))
            } catch {
                return .response(.error(500, "\(error)"))
            }

        case ("GET", ["nudges"]):
            do {
                return .response(.json(try service.nudges()))
            } catch {
                return .response(.error(500, "\(error)"))
            }

        case ("POST", let route) where route.count == 3 && route[0] == "threads" && route[2] == "cadence":
            struct Body: Decodable {
                var days: Int
                var title: String?
                var callsOnly: Bool?
            }
            guard let payload = request.json(Body.self), payload.days >= 0 else {
                return .response(.error(400, "expected {days >= 0, title?}"))
            }
            do {
                try service.setCadence(
                    key: route[1], days: payload.days, fallbackTitle: payload.title,
                    callsOnly: payload.callsOnly
                )
                return .response(.json(["ok": true]))
            } catch {
                return .response(.error(404, "\(error)"))
            }

        case ("GET", let route) where route.count == 3 && route[0] == "threads" && route[2] == "avatar":
            do {
                guard let data = try service.avatar(key: route[1]) else {
                    return .response(.error(404, "no picture"))
                }
                let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
                var response = HTTPResponse.data(data, contentType: isPNG ? "image/png" : "image/jpeg")
                response.headers["Cache-Control"] = "private, max-age=86400"
                return .response(response)
            } catch {
                return .response(.error(500, "\(error)"))
            }

        case ("POST", let route) where route.count == 5 && route[0] == "threads"
                                      && route[2] == "messages" && route[4] == "react":
            struct Body: Decodable { var emoji: String }
            guard let payload = request.json(Body.self), !payload.emoji.isEmpty else {
                return .response(.error(400, "expected {emoji}"))
            }
            do {
                try service.react(key: route[1], messageID: route[3], emoji: payload.emoji)
                return .response(.json(["ok": true]))
            } catch {
                return .response(.error(500, "\(error.localizedDescription)"))
            }

        case ("POST", let route) where route.count == 3 && route[0] == "threads" && route[2] == "nudge":
            struct Body: Decodable { var snoozeUntil: Double }
            guard let payload = request.json(Body.self) else {
                return .response(.error(400, "expected {snoozeUntil}"))
            }
            do {
                try service.snoozeNudge(key: route[1], until: payload.snoozeUntil)
                return .response(.json(["ok": true]))
            } catch {
                return .response(.error(500, "\(error)"))
            }

        case ("GET", ["search"]):
            let query = request.query["q"] ?? ""
            do {
                return .response(.json(try service.search(query: query)))
            } catch {
                return .response(.error(500, "\(error)"))
            }

        case ("GET", ["threads"]):
            let bucket = request.query["bucket"] ?? "to_reply"
            let people = request.query["people"] ?? "known"
            do {
                return .response(.json(try service.list(bucket: bucket, people: people)))
            } catch {
                return .response(.error(500, "\(error)"))
            }

        case ("GET", let route) where route.count == 3 && route[0] == "threads" && route[2] == "messages":
            let limit = min(Int(request.query["limit"] ?? "") ?? 60, 300)
            let before = Int64(request.query["before"] ?? "")
            do {
                return .response(.json(try service.messages(key: route[1], limit: limit, before: before)))
            } catch {
                return .response(.error(500, "\(error)"))
            }

        case ("POST", let route) where route.count == 3 && route[0] == "threads" && route[2] == "state":
            struct Body: Decodable {
                var state: String
                var snoozeUntil: Double?
            }
            guard let body = request.json(Body.self),
                  let state = TriageState(rawValue: body.state) else {
                return .response(.error(400, "expected {state, snoozeUntil?}"))
            }
            do {
                try service.setState(
                    key: route[1], state: state, snoozeUntil: body.snoozeUntil ?? 0
                )
                return .response(.json(["ok": true]))
            } catch {
                return .response(.error(404, "\(error)"))
            }

        case ("POST", let route) where route.count == 3 && route[0] == "threads" && route[2] == "category":
            struct Body: Decodable { var category: String }
            guard let payload = request.json(Body.self) else {
                return .response(.error(400, "expected {category}"))
            }
            // "auto" clears the override and restores the heuristic.
            let override = payload.category == "auto"
                ? nil
                : SenderCategory(rawValue: payload.category)
            if payload.category != "auto" && override == nil {
                return .response(.error(400, "category must be known/unknown/automated/auto"))
            }
            do {
                try service.setCategory(key: route[1], category: override)
                return .response(.json(["ok": true]))
            } catch {
                return .response(.error(404, "\(error)"))
            }

        case ("POST", let route) where route.count == 3 && route[0] == "threads" && route[2] == "favorite":
            struct Body: Decodable { var favorite: Bool }
            guard let payload = request.json(Body.self) else {
                return .response(.error(400, "expected {favorite}"))
            }
            do {
                try service.setFavorite(key: route[1], isFavorite: payload.favorite)
                return .response(.json(["ok": true]))
            } catch {
                return .response(.error(404, "\(error)"))
            }

        case ("POST", let route) where route.count == 3 && route[0] == "threads" && route[2] == "send":
            struct Body: Decodable { var body: String }
            guard let payload = request.json(Body.self) else {
                return .response(.error(400, "expected {body}"))
            }
            do {
                _ = try service.send(key: route[1], body: payload.body)
                return .response(.json(["ok": true]))
            } catch let error as SendError {
                return .response(.error(500, error.description))
            } catch {
                return .response(.error(500, "\(error)"))
            }

        default:
            return .response(.error(404, "no route for \(request.method) \(request.path)"))
        }
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        if let bearer = request.bearerToken, bearer == token { return true }
        // Allows the first load from a link without typing a header.
        if request.query["k"] == token { return true }
        return false
    }

    // MARK: - Static files

    private func serveStatic(path: String) -> HTTPResponse {
        // Reject traversal before touching the filesystem.
        guard !path.contains("..") else { return .error(403, "forbidden") }

        var relative = path == "/" ? "index.html" : String(path.drop(while: { $0 == "/" }))
        if relative.isEmpty { relative = "index.html" }

        let fullPath = webRoot + "/" + relative
        if let data = FileManager.default.contents(atPath: fullPath) {
            return .data(data, contentType: Self.contentType(for: relative))
        }
        // Single-page app: unknown paths fall back to the shell.
        if let index = FileManager.default.contents(atPath: webRoot + "/index.html") {
            return .data(index, contentType: "text/html; charset=utf-8")
        }
        return .text(
            "toreplyd is running, but no web build was found at \(webRoot).",
            status: 404
        )
    }

    private static func contentType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "webmanifest": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}
