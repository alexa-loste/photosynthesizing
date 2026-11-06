import Foundation

// Line-buffer stdout. When output is redirected to a log file (which is how the daemon
// always runs) the default is block buffering, so startup messages sit in a 4KB buffer
// and the log looks empty exactly when you're trying to debug why nothing started.
setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Tiny argument parsing

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : "help"

func intFlag(_ name: String, default fallback: Int) -> Int {
    guard let index = arguments.firstIndex(of: "--\(name)"),
          index + 1 < arguments.count,
          let value = Int(arguments[index + 1]) else { return fallback }
    return value
}

func hasFlag(_ name: String) -> Bool { arguments.contains("--\(name)") }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func truncate(_ s: String, _ max: Int) -> String {
    let flat = s.replacingOccurrences(of: "\n", with: " ")
    return flat.count <= max ? flat : String(flat.prefix(max)) + "…"
}

func age(_ unix: Double) -> String {
    let delta = Date().timeIntervalSince1970 - unix
    if delta < 3600 { return "\(Int(delta / 60))m" }
    if delta < 86_400 { return "\(Int(delta / 3600))h" }
    return "\(Int(delta / 86_400))d"
}

/// Pad by character count. `String(format:"%-24s")` counts bytes, so any name with an
/// accent or emoji would break the column alignment.
func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

// MARK: - Commands

switch command {

case "dump":
    let limit = intFlag("limit", default: 20)
    let days = intFlag("days", default: 180)
    let previewWidth = intFlag("width", default: 60)

    let contacts = ContactBook.load()
    guard let chatDB = try? ChatDB(contacts: contacts) else {
        fail("could not open chat.db read-only — check Full Disk Access")
    }

    let groups: [ThreadGroup]
    do {
        groups = try chatDB.threadGroups(sinceDays: days, limit: limit)
    } catch {
        fail("query failed: \(error)")
    }

    if hasFlag("json") {
        let threads = groups.map {
            ThreadSummary(
                key: $0.key, sendGUID: $0.sendGUID, title: $0.title, isGroup: $0.isGroup,
                service: $0.service, participants: $0.handles.map { contacts.name(for: $0) },
                handles: $0.handles, lastMessage: $0.lastMessage, needsReply: $0.needsReply,
                category: $0.category
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(threads) {
            print(String(decoding: data, as: UTF8.self))
        }
    } else {
        // Previews are truncated on purpose — this is a decode check, not a message reader.
        print(pad("", 2) + pad("WHO", 24) + pad("SVC", 9) + pad("AGE", 5) + "LAST MESSAGE")
        print(String(repeating: "─", count: 40 + previewWidth))
        for group in groups {
            let marker = group.needsReply ? "▶ " : "  "
            let who = truncate(group.title + (group.isGroup ? " (grp)" : ""), 23)
            let speaker = group.lastMessage.isFromMe ? "me: " : ""
            print(
                marker
                + pad(who, 24)
                + pad(truncate(group.service, 8), 9)
                + pad(age(group.lastMessage.date), 5)
                + speaker + truncate(group.lastMessage.text, previewWidth)
            )
        }
        let owed = groups.filter(\.needsReply).count
        print("\n\(groups.count) threads · ▶ \(owed) awaiting your reply")
    }

case "doctor":
    // Health check that prints statistics only — no message content.
    print("toreplyd doctor")
    print(String(repeating: "─", count: 46))

    let contacts = ContactBook.load()
    print("contacts loaded:      ok")

    guard let chatDB = try? ChatDB(contacts: contacts) else {
        fail("chat.db read-only open FAILED — check Full Disk Access")
    }
    print("chat.db (read-only):  ok")

    do {
        let maxRow = try chatDB.maxMessageRowID()
        print("max message ROWID:    \(maxRow)")

        let groups = try chatDB.threadGroups(sinceDays: 180, limit: 500)
        let owed = groups.filter(\.needsReply)
        let merged = groups.filter { $0.chatRowIDs.count > 1 }.count
        let empty = groups.filter { $0.lastMessage.text.isEmpty }.count

        func count(_ category: SenderCategory, in list: [ThreadGroup]) -> Int {
            list.filter { $0.category == category }.count
        }

        print("threads (180d):       \(groups.count)")
        print("  known people:       \(count(.known, in: groups))")
        print("  unknown numbers:    \(count(.unknown, in: groups))")
        print("  automated/shortcode:\(count(.automated, in: groups))")
        print("  merged multi-svc:   \(merged)")
        print("  empty preview:      \(empty)")
        print("awaiting reply:       \(owed.count)")
        print("  ↳ real people:      \(count(.known, in: owed))   ← the actual inbox")
        print("  ↳ unknown:          \(count(.unknown, in: owed))")
        print("  ↳ automated:        \(count(.automated, in: owed))")

        // Decode-rate check across a real sample.
        let sample = try chatDB.messages(
            chatRowIDs: Array(groups.prefix(40).flatMap(\.chatRowIDs)),
            limit: 500
        )
        let blank = sample.filter { $0.text.isEmpty }.count
        print("decode sample:        \(sample.count - blank)/\(sample.count) non-empty")
        if sample.isEmpty { print("  ⚠️  no messages sampled") }
    } catch {
        fail("query failed: \(error)")
    }
    print("\nall checks passed")

case "token":
    print(Token.loadOrCreate())

case "send":
    // Diagnostic send. Addressed by thread key, never by a raw handle, and a dry run
    // unless --confirm is given: it prints exactly who would receive the message first.
    // A previous version took a bare phone number and delivered a test message to the
    // wrong person; nothing here can be addressed to someone the tool can't name.
    func stringFlag(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: "--\(name)"),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    guard let threadKey = stringFlag("thread"), let body = stringFlag("body") else {
        fail("usage: toreplyd send --thread <key> --body <text> [--confirm]")
    }

    let contacts = ContactBook.load()
    guard let chatDB = try? ChatDB(contacts: contacts),
          let triage = try? TriageStore() else {
        fail("could not open databases")
    }
    let service = ThreadService(chatDB: chatDB, triage: triage, contacts: contacts)

    do {
        guard let group = try service.group(forKey: threadKey) else {
            fail("no thread with key \(threadKey)")
        }
        let target = try service.sendTarget(for: group)
        print("recipient:  \(target.displayName)")
        print("kind:       \(group.isGroup ? "group chat" : "one-to-one")")
        print("service:    \(group.service)")
        print("body:       \(body)")

        guard hasFlag("confirm") else {
            print("\nDRY RUN — nothing sent. Re-run with --confirm to actually send.")
            exit(0)
        }
        let started = Date()
        try Sender.send(body: body, to: target)
        print("\nsent to \(target.displayName) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
    } catch {
        fail("\(error)")
    }

case "whoami":
    // Your own handles, read from INCOMING messages. On outgoing rows
    // `destination_caller_id` holds the *recipient*, which is exactly the trap that
    // caused a test message to be delivered to the wrong person.
    guard let db = try? SQLiteDB(path: ChatDB.defaultPath, readOnly: true),
          let stmt = try? db.prepare("""
              SELECT destination_caller_id, COUNT(*) AS n
              FROM message
              WHERE is_from_me = 0 AND destination_caller_id IS NOT NULL
              GROUP BY 1 ORDER BY n DESC LIMIT 6
              """) else {
        fail("could not read chat.db")
    }
    print("your handles (from messages sent TO you):")
    while stmt.step() {
        print("  \(stmt.string(0) ?? "?")   \(stmt.int(1)) received")
    }

case "serve":
    let port = UInt16(intFlag("port", default: 8787))
    let requestedBind = arguments.firstIndex(of: "--bind").map { arguments[$0 + 1] } ?? "127.0.0.1"

    // Resolved lazily on every bind, not once at launch: after a rebind the Tailscale
    // address may have changed, and a captured value would bind to nothing.
    let resolveHost: () -> String? = {
        requestedBind == "auto" ? TailscaleAddress.find() : requestedBind
    }
    if resolveHost() == nil {
        fail("--bind auto: no Tailscale address found — is Tailscale connected?")
    }

    let webRoot = NSString(string: "~/toreply/web").expandingTildeInPath

    let contacts = ContactBook.load()
    guard let chatDB = try? ChatDB(contacts: contacts) else {
        fail("could not open chat.db read-only — check Full Disk Access")
    }
    guard let triage = try? TriageStore() else {
        fail("could not open triage state db at \(TriageStore.defaultPath)")
    }

    let beeper = Beeper()
    let calls = CallHistory()
    let photos = ContactPhotos()
    let birthdays = ContactBirthdays()
    let service = ThreadService(
        chatDB: chatDB, triage: triage, contacts: contacts, beeper: beeper, calls: calls,
        photos: photos, birthdays: birthdays
    )
    let token = Token.loadOrCreate()
    let api = API(service: service, token: token, webRoot: webRoot)

    let server: HTTPServer
    do {
        server = try HTTPServer(port: port, resolveHost: resolveHost) { api.handle($0) }
        try server.start()
    } catch {
        fail("could not bind \(resolveHost() ?? "?"):\(port) — \(error)")
    }

    print("toreplyd starting on port \(port)")
    print("web root: \(webRoot)")
    print("token:    \(token)")
    print("photos:   \(photos.count) handles with a contact photo")
    print("birthdays: \(birthdays.count) handles with a birthday")
    print("calls:    \(calls == nil ? "off (no call history)" : "on")")
    print("beeper:   \(beeper == nil ? "off (no \(Beeper.tokenPath))" : "on")")

    if let snapshot = try? triage.backup() {
        print("backup:   \(snapshot)")
    }
    // Triage state is the only irreplaceable data here, so snapshot it regularly.
    let backups = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "toreplyd.backup"))
    backups.schedule(deadline: .now() + 6 * 3600, repeating: 6 * 3600)
    backups.setEventHandler { try? triage.backup() }
    backups.resume()

    // Watch for new messages and push them to any connected client. Polling the max
    // ROWID is a single indexed lookup, so this is far cheaper than it looks and avoids
    // the complexity of watching the WAL file.
    //
    // The poller gets its own connection. Sharing the HTTP queue's handle across two
    // threads livelocked both inside sqlite3_finalize (purgeableCacheShrink) on
    // 2026-11-05: 200% CPU and every request timing out.
    guard let probeDB = try? ChatDB(contacts: contacts) else {
        fail("could not open a second chat.db connection for the poller")
    }
    var lastSeenRowID = service.currentMaxRowID()
    var lastBeeperActivity = service.beeperActivity()
    let poller = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "toreplyd.poll"))
    poller.schedule(deadline: .now() + 2, repeating: 2)
    poller.setEventHandler {
        let current = (try? probeDB.maxMessageRowID()) ?? lastSeenRowID
        // Beeper's list is cached for 15s, so this only reaches Beeper that often.
        let beeperActivity = service.beeperActivity()
        guard current != lastSeenRowID || beeperActivity != lastBeeperActivity else { return }
        lastSeenRowID = current
        lastBeeperActivity = beeperActivity
        service.invalidate()
        server.broadcast(event: "messages", data: "{\"maxRowID\":\(current)}")
    }
    poller.resume()

    // Keep Messages warm so the first send after an idle stretch isn't a 2–3s stall.
    let keepAlive = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "toreplyd.wake"))
    keepAlive.schedule(deadline: .now() + 300, repeating: 300)
    keepAlive.setEventHandler { Sender.wakeMessages() }
    keepAlive.resume()

    dispatchMain()

default:
    print("""
    toreplyd — personal iMessage triage backend

    usage:
      toreplyd serve  [--port N] [--bind <ip>|auto]
      toreplyd dump   [--limit N] [--days N] [--width N] [--json]
      toreplyd doctor
      toreplyd send   --thread <key> --body <text> [--confirm]
      toreplyd whoami
      toreplyd token

    serve   run the API + static web server. Binds loopback by default;
            --bind auto picks up this machine's Tailscale address so your
            other devices can reach it (never binds 0.0.0.0)
    dump    list recent threads; ▶ marks ones awaiting your reply
            previews are truncated (decode check, not a message reader)
    doctor  health + decode statistics only, prints no message content
    send    dry run by default — prints the recipient's name and sends
            nothing unless --confirm is passed
    whoami  your own handles, read from incoming messages
    token   print the shared secret used by the web app
    """)
}
