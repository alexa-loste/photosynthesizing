import Foundation
import Network

#if canImport(Darwin)
import Darwin
#endif

/// Find this machine's Tailscale address without shelling out to the Tailscale CLI
/// (which lives at an awkward path inside the app bundle and isn't on PATH).
///
/// Tailscale hands every node an address in the 100.64.0.0/10 carrier-grade NAT range,
/// so we just look for a local interface in that block. Keeping this dynamic means no
/// machine-specific IP is baked into the config, which is what lets someone else clone
/// this and run it unmodified.
enum TailscaleAddress {
    static func find() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidate: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            guard let rawAddress = current.pointee.ifa_addr,
                  rawAddress.pointee.sa_family == UInt8(AF_INET) else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                rawAddress, socklen_t(rawAddress.pointee.sa_len),
                &buffer, socklen_t(buffer.count),
                nil, 0, NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let address = String(cString: buffer)
            let parts = address.split(separator: ".").compactMap { UInt8($0) }
            guard parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) else {
                continue
            }
            candidate = address
        }
        return candidate
    }
}

/// A deliberately small HTTP/1.1 server.
///
/// The API surface is six JSON endpoints, one event stream, and static files. Pulling in
/// a web framework would mean managing SwiftPM dependencies on a machine that only has
/// Command Line Tools, for a server that will only ever be spoken to by one client over
/// a private network. Hand-rolling the subset we need keeps the daemon a single binary
/// with nothing to break on a macOS update.

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    func json<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: body)
    }

    var bearerToken: String? {
        guard let auth = headers["authorization"],
              auth.lowercased().hasPrefix("bearer ") else { return nil }
        return String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    }
}

struct HTTPResponse {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ value: some Encodable, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: data
        )
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }

    static func text(_ string: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": contentType], body: Data(string.utf8))
    }

    static func data(_ data: Data, contentType: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["Content-Type": contentType], body: data)
    }
}

enum HTTPOutcome {
    case response(HTTPResponse)
    /// Hijack the socket for a Server-Sent Events stream.
    case eventStream
}

private let statusPhrases: [Int: String] = [
    200: "OK", 201: "Created", 204: "No Content", 304: "Not Modified",
    400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
    405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error",
]

// MARK: - Server

final class HTTPServer {

    private let port: NWEndpoint.Port
    /// Re-resolved on every (re)start rather than captured once: Tailscale can hand out
    /// a different address after a network change, and a stale one binds to nothing.
    private let resolveHost: () -> String?
    private let handler: (HTTPRequest) -> HTTPOutcome
    private var listener: NWListener?
    private var watchdog: DispatchSourceTimer?
    private var restarting = false
    /// Bumped on every bind. A listener's callbacks carry the generation they were
    /// created under, so a stale one can be recognised and ignored.
    private var generation: UInt64 = 0
    private var backoff: Double = 3
    private let queue = DispatchQueue(label: "toreplyd.http")

    private static let minBackoff: Double = 3
    private static let maxBackoff: Double = 60

    /// Open SSE connections, guarded by `clientLock`.
    private var eventClients: [ObjectIdentifier: NWConnection] = [:]
    private let clientLock = NSLock()

    /// `bindHost` decides who can reach the server:
    ///
    ///  - `127.0.0.1` (default) — loopback only, for when `tailscale serve` fronts us
    ///    with TLS. Nothing on the local network can connect.
    ///  - the machine's Tailscale IP — reachable from your other tailnet devices but
    ///    still not from the local network. Traffic is already encrypted by WireGuard.
    ///
    /// Deliberately never `0.0.0.0`, which would also expose it to the home LAN.
    init(
        port: UInt16,
        resolveHost: @escaping () -> String?,
        handler: @escaping (HTTPRequest) -> HTTPOutcome
    ) throws {
        guard let p = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "toreplyd", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bad port \(port)"])
        }
        self.port = p
        self.resolveHost = resolveHost
        self.handler = handler
    }

    func start() throws {
        try bind()
        startWatchdog()
    }

    private func bind() throws {
        guard let hostString = resolveHost() else {
            throw NSError(
                domain: "toreplyd", code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                            "no bind address available (is Tailscale connected?)"]
            )
        }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(hostString), port: port
        )
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        // Without this the process happily keeps running around a dead socket. When
        // Tailscale's utun interface is torn down and recreated — a network change, a
        // wake from sleep — the listener fails, the app goes unreachable, and nothing
        // reports it. This is how the server silently stopped answering in practice.
        // The generation guard is what stops a rebind from multiplying. Cancelling a
        // listener makes it report `.cancelled`, and a superseded listener can report
        // `.failed` long after it was replaced. Without this, a stale callback triggers
        // another rebind, which cancels the *healthy* listener, which reports `.cancelled`
        // in turn. That feedback loop is what pegged two cores on 2026-08-21 while lsof
        // still showed the socket LISTENing.
        generation &+= 1
        let myGeneration = generation

        listener.stateUpdateHandler = { [weak self] state in
            guard let self, myGeneration == self.generation else { return }
            switch state {
            case .failed(let error):
                FileHandle.standardError.write(
                    Data("listener failed: \(error) — rebinding\n".utf8)
                )
                self.scheduleRebind()
            // `.cancelled` is deliberately not handled. A cancel is something this process
            // asked for, never a fault to recover from, and treating it as one is exactly
            // how the loop started.
            case .ready:
                self.backoff = Self.minBackoff
                FileHandle.standardOutput.write(
                    Data("listening on http://\(hostString):\(self.port.rawValue)\n".utf8)
                )
            default:
                break
            }
        }

        listener.start(queue: queue)
        self.listener = listener
    }

    private func scheduleRebind() {
        queue.async { [weak self] in
            guard let self, !self.restarting else { return }
            self.restarting = true

            // Detach before cancelling. A listener on its way out still delivers state
            // changes, and a handler that outlives the thing it belongs to is a callback
            // from a listener we already gave up on.
            self.generation &+= 1
            self.listener?.stateUpdateHandler = nil
            self.listener?.newConnectionHandler = nil
            self.listener?.cancel()
            self.listener = nil

            // Give the interface a moment to settle before trying again; a rebind during
            // the tear-down usually fails too. The delay doubles on repeated failure and
            // is capped, so an address that never comes back costs one attempt a minute
            // instead of an unbounded pile of pending work.
            self.queue.asyncAfter(deadline: .now() + self.backoff) {
                self.restarting = false
                do {
                    try self.bind()
                } catch {
                    self.backoff = min(self.backoff * 2, Self.maxBackoff)
                    FileHandle.standardError.write(
                        Data("rebind failed: \(error) — retrying in \(Int(self.backoff))s\n".utf8)
                    )
                    self.queue.asyncAfter(deadline: .now() + self.backoff) {
                        self.scheduleRebind()
                    }
                }
            }
        }
    }

    /// Belt and braces: a listener can also end up wedged without ever reporting
    /// `.failed`, so check periodically that it's actually ready.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self, !self.restarting else { return }
            switch self.listener?.state {
            case .ready, .setup, .waiting:
                break
            default:
                FileHandle.standardError.write(
                    Data("watchdog: listener not ready — rebinding\n".utf8)
                )
                self.scheduleRebind()
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    /// Requests arrive in arbitrary chunks, so accumulate until headers (and any declared
    /// body) are complete before dispatching.
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }

            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            if error != nil {
                connection.cancel()
                return
            }

            // Refuse absurd requests rather than buffering forever.
            if buffer.count > 4 << 20 {
                self.send(.error(413, "request too large"), on: connection, close: true)
                return
            }

            if let (request, consumed) = Self.parse(buffer) {
                _ = consumed
                switch self.handler(request) {
                case .response(let response):
                    self.send(response, on: connection, close: true)
                case .eventStream:
                    self.beginEventStream(on: connection)
                }
                return
            }

            if isComplete {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    // MARK: Parsing

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Returns nil while the request is still incomplete.
    static func parse(_ buffer: Data) -> (HTTPRequest, Int)? {
        guard let headerEnd = buffer.range(of: headerTerminator) else { return nil }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let declaredLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        let available = buffer.count - (bodyStart - buffer.startIndex)
        guard available >= declaredLength else { return nil }  // wait for the rest

        let body = declaredLength > 0
            ? buffer[bodyStart..<buffer.index(bodyStart, offsetBy: declaredLength)]
            : Data()

        let (path, query) = splitTarget(requestLine[1])
        let request = HTTPRequest(
            method: requestLine[0].uppercased(),
            path: path,
            query: query,
            headers: headers,
            body: Data(body)
        )
        return (request, (bodyStart - buffer.startIndex) + declaredLength)
    }

    static func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let mark = target.firstIndex(of: "?") else {
            return (percentDecode(target), [:])
        }
        let path = percentDecode(String(target[target.startIndex..<mark]))
        var query: [String: String] = [:]
        for pair in target[target.index(after: mark)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = parts.first else { continue }
            query[percentDecode(name)] = parts.count > 1 ? percentDecode(parts[1]) : ""
        }
        return (path, query)
    }

    static func percentDecode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }

    // MARK: Writing

    private func send(_ response: HTTPResponse, on connection: NWConnection, close: Bool) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = close ? "close" : "keep-alive"
        // Everything is same-origin behind `tailscale serve`; no CORS needed.
        headers["Cache-Control"] = headers["Cache-Control"] ?? "no-store"

        let phrase = statusPhrases[response.status] ?? "OK"
        var head = "HTTP/1.1 \(response.status) \(phrase)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(response.body)
        connection.send(content: out, completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }

    // MARK: Server-Sent Events

    private func beginEventStream(on connection: NWConnection) {
        let head = """
            HTTP/1.1 200 OK\r
            Content-Type: text/event-stream\r
            Cache-Control: no-store\r
            Connection: keep-alive\r
            \r

            """
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        let id = ObjectIdentifier(connection)
        clientLock.lock()
        eventClients[id] = connection
        clientLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.dropEventClient(id)
            default:
                break
            }
        }
        // Drain anything the client sends so the connection doesn't stall.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, done, _ in
            if done { connection.cancel() }
        }
    }

    private func dropEventClient(_ id: ObjectIdentifier) {
        clientLock.lock()
        eventClients.removeValue(forKey: id)
        clientLock.unlock()
    }

    /// Push an event to every connected client.
    func broadcast(event: String, data: String) {
        let payload = Data("event: \(event)\ndata: \(data)\n\n".utf8)
        clientLock.lock()
        let clients = Array(eventClients.values)
        clientLock.unlock()
        for client in clients {
            client.send(content: payload, completion: .contentProcessed { _ in })
        }
    }

    var eventClientCount: Int {
        clientLock.lock()
        defer { clientLock.unlock() }
        return eventClients.count
    }
}
