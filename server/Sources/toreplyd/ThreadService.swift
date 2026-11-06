import Foundation

/// Joins the read-only Messages data to our triage state, with a small cache so that
/// polling the thread list every couple of seconds doesn't re-scan 180 days of messages.
final class ThreadService {

    private let chatDB: ChatDB
    private let triage: TriageStore
    private let contacts: ContactBook
    private let beeper: Beeper?
    private let calls: CallHistory?
    private let photos: ContactPhotos?
    private let birthdays: ContactBirthdays?

    private let lock = NSLock()
    private var cachedGroups: [ThreadGroup] = []
    private var cachedAtRowID: Int64 = -1
    private var cachedAt: Double = 0

    private let lookbackDays: Int
    private static let maxCacheAge: Double = 30

    init(chatDB: ChatDB, triage: TriageStore, contacts: ContactBook, beeper: Beeper? = nil,
         calls: CallHistory? = nil, photos: ContactPhotos? = nil,
         birthdays: ContactBirthdays? = nil, lookbackDays: Int = 180) {
        self.photos = photos
        self.birthdays = birthdays
        self.chatDB = chatDB
        self.beeper = beeper
        self.calls = calls
        self.triage = triage
        self.contacts = contacts
        self.lookbackDays = lookbackDays
    }

    /// Cheap probe used both by the cache and by the poll loop.
    func currentMaxRowID() -> Int64 {
        (try? chatDB.maxMessageRowID()) ?? 0
    }

    /// iMessage threads from chat.db plus, when Beeper is set up, every other network.
    func groups() throws -> [ThreadGroup] {
        let messages = try chatGroups()
        guard let beeper else { return messages }
        return (messages + beeper.threadGroups())
            .sorted { $0.lastMessage.date > $1.lastMessage.date }
    }

    /// Newest Beeper activity, for the poll loop; 0 without Beeper.
    func beeperActivity() -> Int64 {
        beeper?.newestActivity() ?? 0
    }

    private func chatGroups() throws -> [ThreadGroup] {
        let rowID = currentMaxRowID()
        let now = Date().timeIntervalSince1970

        lock.lock()
        let isFresh = rowID == cachedAtRowID && (now - cachedAt) < Self.maxCacheAge
        let cached = cachedGroups
        lock.unlock()
        if isFresh, !cached.isEmpty { return cached }

        let groups = try chatDB.threadGroups(sinceDays: lookbackDays, limit: 1000)

        lock.lock()
        cachedGroups = groups
        cachedAtRowID = rowID
        cachedAt = now
        lock.unlock()
        return groups
    }

    func invalidate() {
        lock.lock()
        cachedAtRowID = -1
        lock.unlock()
        beeper?.invalidate()
    }

    func group(forKey key: String) throws -> ThreadGroup? {
        try groups().first { $0.key == key }
    }

    // MARK: - Views

    struct ThreadListResponse: Encodable {
        var threads: [ThreadSummary]
        var counts: [String: Int]
        var generatedAt: Double
    }

    /// `bucket` is one of to_reply / snoozed / done / all.
    /// `people` filters by sender category — the default hides automated senders, which
    /// is what keeps 60 real conversations from being buried under 124 robots.
    func list(bucket: String, people: String) throws -> ThreadListResponse {
        let groups = try groups()
        let stored = try triage.all()
        let now = Date().timeIntervalSince1970

        var summaries: [ThreadSummary] = []
        var counts: [String: Int] = [
            "to_reply": 0, "snoozed": 0, "follow_up": 0, "done": 0, "all": 0,
        ]

        // Favourites are a lens across every bucket, not a bucket of their own — the
        // whole point is to find someone you've already cleared out of the inbox.
        let favoritesOnly = people == "favorites"

        for group in groups {
            let record = stored[group.key]
            let state = TriageStore.effectiveState(group: group, stored: record, now: now)
            let category = record?.categoryOverride ?? group.category
            let summary = ThreadSummary(
                key: group.key,
                sendGUID: group.sendGUID,
                title: group.title,
                isGroup: group.isGroup,
                service: group.service,
                participants: group.handles.map { contacts.name(for: $0) },
                handles: group.handles,
                lastMessage: group.lastMessage,
                needsReply: group.needsReply,
                state: state,
                favorite: record?.isFavorite ?? false,
                lastRowID: group.lastRowID,
                category: category,
                snoozeUntil: state == .snoozed ? record?.snoozeUntil : nil
            )

            if favoritesOnly {
                if summary.favorite { summaries.append(summary) }
                counts["favorites", default: 0] += summary.favorite ? 1 : 0
                continue
            }

            // Counts always reflect the people filter, so the tab badges match the list.
            guard passes(people: people, isGroup: group.isGroup, category: category) else {
                continue
            }
            counts["all", default: 0] += 1
            counts[state.rawValue, default: 0] += 1

            if bucket == "all" || bucket == state.rawValue {
                summaries.append(summary)
            }
        }

        return ThreadListResponse(
            threads: summaries, counts: counts, generatedAt: now
        )
    }

    /// Group chats get their own view rather than being mixed into "People" — a busy
    /// group generates constant activity that would otherwise dominate the list of
    /// individuals actually waiting on a reply.
    private func passes(people: String, isGroup: Bool, category: SenderCategory) -> Bool {
        switch people {
        case "all": return true
        case "groups": return isGroup
        case "unknown": return !isGroup && category == .unknown
        case "automated": return !isGroup && category == .automated
        default: return !isGroup && category == .known
        }
    }

    /// Minimal payload for a home-screen widget.
    ///
    /// Widget extensions get a small memory budget and are killed if a timeline refresh
    /// takes too long, so they can't afford the full thread list. This returns the four
    /// counts plus just enough of the top few threads to render a glanceable list.
    struct Summary: Encodable {
        struct Item: Encodable {
            var key: String
            var title: String
            var preview: String
            var date: Double
            var isGroup: Bool
        }
        var toReply: Int
        var followUp: Int
        var snoozed: Int
        var favorites: Int
        var top: [Item]
        var generatedAt: Double
    }

    func summary(people: String = "known", limit: Int = 5) throws -> Summary {
        let list = try list(bucket: "to_reply", people: people)
        let favorites = try? self.list(bucket: "all", people: "favorites")

        return Summary(
            toReply: list.counts["to_reply"] ?? 0,
            followUp: list.counts["follow_up"] ?? 0,
            snoozed: list.counts["snoozed"] ?? 0,
            favorites: favorites?.counts["favorites"] ?? 0,
            top: list.threads.prefix(limit).map {
                Summary.Item(
                    key: $0.key,
                    title: $0.title,
                    // Trim here rather than in the widget — every byte crosses a process
                    // boundary and widgets re-decode this on every timeline refresh.
                    preview: String($0.lastMessage.text.prefix(90)),
                    date: $0.lastMessage.date,
                    isGroup: $0.isGroup
                )
            },
            generatedAt: Date().timeIntervalSince1970
        )
    }

    func messages(key: String, limit: Int, before: Int64?) throws -> [Message] {
        if Beeper.isBeeperKey(key) {
            // Beeper returns its newest page; older history isn't paged in yet.
            guard before == nil, let beeper else { return [] }
            return Array(try beeper.messages(key: key).suffix(limit))
        }
        guard let group = try group(forKey: key) else { return [] }
        return try chatDB.messages(chatRowIDs: group.chatRowIDs, limit: limit, before: before)
    }

    func attachmentFile(id: Int64) throws -> (path: String, mimeType: String, name: String)? {
        try chatDB.attachmentFile(id: id)
    }

    /// Search results carry their resolved triage state so a hit can be actioned
    /// straight from the results list.
    func search(query: String, limit: Int = 40) throws -> ThreadListResponse {
        let needle = query.lowercased()
        let fromBeeper = needle.count >= 2 ? (beeper?.search(query) ?? []) : []
        let groups = try chatDB.searchThreads(query: query, limit: limit) + fromBeeper
        let stored = try triage.all()
        let now = Date().timeIntervalSince1970

        let threads = groups.map { group -> ThreadSummary in
            let record = stored[group.key]
            return ThreadSummary(
                key: group.key,
                sendGUID: group.sendGUID,
                title: group.title,
                isGroup: group.isGroup,
                service: group.service,
                participants: group.handles.map { contacts.name(for: $0) },
                handles: group.handles,
                lastMessage: group.lastMessage,
                needsReply: group.needsReply,
                state: TriageStore.effectiveState(group: group, stored: record, now: now),
                favorite: record?.isFavorite ?? false,
                lastRowID: group.lastRowID,
                category: record?.categoryOverride ?? group.category
            )
        }
        return ThreadListResponse(threads: threads, counts: [:], generatedAt: now)
    }

    // MARK: - Mutations

    func setState(key: String, state: TriageState, snoozeUntil: Double) throws {
        guard let group = try group(forKey: key) else {
            throw NSError(domain: "toreplyd", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "unknown thread \(key)"])
        }
        // Anchor the decision to the newest message we know about, so a later message
        // automatically supersedes it and the thread returns to To Reply.
        try triage.set(
            key: key,
            state: state,
            resolvedAtMessageRowID: group.lastRowID,
            snoozeUntil: snoozeUntil
        )
    }

    /// Resolve a thread into a recipient whose identity we can state before sending.
    /// Sends are only ever addressed via a thread the user is looking at — never a bare
    /// handle — so the name shown in the UI is the name that receives the message.
    func sendTarget(for group: ThreadGroup) throws -> SendTarget {
        if group.isGroup {
            return SendTarget(route: .chat(guid: group.sendGUID), displayName: group.title)
        }
        // For a one-to-one thread the recipient is the single other participant.
        let handle = group.handles.count == 1
            ? group.handles[0]
            : (group.handles.first ?? group.chatIdentifier)
        guard !handle.isEmpty else {
            throw SendError.ambiguousRecipient("thread \(group.key) has no handle")
        }
        if group.handles.count > 1 {
            throw SendError.ambiguousRecipient(
                "one-to-one thread \(group.key) has \(group.handles.count) handles"
            )
        }
        return SendTarget(
            route: .participant(handle: handle, service: group.service),
            displayName: group.title
        )
    }

    /// A thread's picture: the contact photo for an iMessage DM, Beeper's for the rest.
    /// Group iMessage chats have none here.
    func avatar(key: String) throws -> Data? {
        if Beeper.isBeeperKey(key) { return beeper?.avatar(key: key) }
        guard key.hasPrefix("dm:") else { return nil }
        let handles = [String(key.dropFirst(3))] + (try group(forKey: key)?.handles ?? [])
        return photos?.photo(handles: handles)
    }

    /// Reactions go through Beeper only. Messages' AppleScript interface can't send an
    /// iMessage tapback; only Apple's private frameworks can, which needs SIP off.
    func react(key: String, messageID: String, emoji: String) throws {
        guard Beeper.isBeeperKey(key), let beeper else {
            throw NSError(domain: "toreplyd", code: 501, userInfo: [
                NSLocalizedDescriptionKey: "iMessage tapbacks can't be sent from here",
            ])
        }
        try beeper.react(key: key, messageID: messageID, emoji: emoji)
        beeper.invalidate()
    }

    func setFavorite(key: String, isFavorite: Bool) throws {
        guard try group(forKey: key) != nil else {
            throw NSError(domain: "toreplyd", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "unknown thread \(key)"])
        }
        try triage.setFavorite(key: key, isFavorite: isFavorite)
    }

    func setCategory(key: String, category: SenderCategory?) throws {
        guard try group(forKey: key) != nil else {
            throw NSError(domain: "toreplyd", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "unknown thread \(key)"])
        }
        try triage.setCategoryOverride(key: key, category: category)
    }

    func send(key: String, body: String) throws -> ThreadGroup {
        guard let group = try group(forKey: key) else {
            throw NSError(domain: "toreplyd", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "unknown thread \(key)"])
        }
        if Beeper.isBeeperKey(key), let beeper {
            try beeper.send(key: key, text: body)
        } else {
            try Sender.send(body: body, to: try sendTarget(for: group))
        }
        // Replying is itself a triage decision: the thread leaves To Reply.
        try triage.set(
            key: key, state: .done, resolvedAtMessageRowID: group.lastRowID, snoozeUntil: 0
        )
        invalidate()
        return group
    }

    // MARK: - Keep in touch

    struct Nudge: Encodable {
        var key: String
        var title: String
        var isGroup: Bool
        /// Where the chat lives: iMessage, SMS, WhatsApp, Instagram, Facebook/Messenger…
        var service: String?
        var cadenceDays: Int
        /// The later of lastTexted and lastCalled.
        var lastContact: Double?
        /// Last real message either way. Nil when it's older than the lookback window.
        var lastTexted: Double?
        var lastFromMe: Bool?
        /// Last connected phone or FaceTime call. Nil for Beeper threads and groups.
        var lastCalled: Double?
        /// Only calls (and "did it") reset the clock for this person; texts don't.
        var callsOnly: Bool
        /// "MM-dd" from their contact card, when it has one.
        var birthday: String?
        var dueAt: Double
    }

    struct Suggestion: Encodable {
        var key: String
        var title: String
        var firstContact: Double
        var messageCount: Int
        /// Most of these aren't in Contacts yet, so the number alone doesn't say who it is.
        var preview: String
        var lastFromMe: Bool
    }

    struct NudgeResponse: Encodable {
        var due: [Nudge]
        var upcoming: [Nudge]
        var suggestions: [Suggestion]
        var generatedAt: Double
    }

    /// Who you're overdue to be in touch with, plus recently met people worth adding.
    ///
    /// "In touch" is any real message in either direction, so a nudge clears itself the
    /// moment either of you texts. Contact outside Messages (a call, a coffee) is recorded
    /// with "did it", which quiets the nudge for one cadence.
    func nudges(newWithinDays: Int = 60) throws -> NudgeResponse {
        let groups = try groups()
        let byKey = Dictionary(groups.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let tracked = try triage.keepInTouch()
        let stored = try triage.all()
        let lastCalls = calls?.lastCalls() ?? [:]
        let now = Date().timeIntervalSince1970

        var nudges: [Nudge] = []
        for entry in tracked.values where entry.cadenceDays > 0 {
            let group = byKey[entry.key]
            let cadence = Double(entry.cadenceDays) * 86_400
            let lastTexted = group?.lastMessage.date
            let lastCalled = Self.callHandles(key: entry.key, group: group)
                .compactMap { lastCalls[$0] }.max()
            let lastContact = entry.callsOnly
                ? lastCalled
                : [lastTexted, lastCalled].compactMap { $0 }.max()
            // Never contacted inside the window: due now, not 180 days from now.
            let fromContact = lastContact.map { $0 + cadence } ?? now
            nudges.append(Nudge(
                key: entry.key,
                title: group?.title ?? entry.title,
                isGroup: group?.isGroup ?? entry.key.hasPrefix("grp:"),
                service: group?.service,
                cadenceDays: entry.cadenceDays,
                lastContact: lastContact,
                lastTexted: lastTexted,
                lastFromMe: group?.lastMessage.isFromMe,
                lastCalled: lastCalled,
                callsOnly: entry.callsOnly,
                birthday: birthdays?.birthday(handles: Self.callHandles(key: entry.key, group: group)),
                dueAt: max(fromContact, entry.snoozeUntil)
            ))
        }
        // Most overdue relative to their own rhythm first: a week late on a weekly friend
        // matters more than a week late on a quarterly one.
        func lateness(_ n: Nudge) -> Double { (now - n.dueAt) / Double(n.cadenceDays) }
        let due = nudges.filter { $0.dueAt <= now }.sorted { lateness($0) > lateness($1) }
        let upcoming = nudges.filter { $0.dueAt > now }.sorted { $0.dueAt < $1.dueAt }

        // New people: one-to-one, not a robot, first message within the window, and a
        // real back-and-forth (both sides have written at least twice).
        let cutoff = now - Double(newWithinDays) * 86_400
        let candidates = groups.filter { group in
            !group.isGroup
                && group.lastMessage.date > cutoff
                && tracked[group.key] == nil
                && (stored[group.key]?.categoryOverride ?? group.category) != .automated
        }
        let stats = try chatDB.contactStats(chatRowIDs: candidates.flatMap(\.chatRowIDs))
        let suggestions = candidates.compactMap { group -> Suggestion? in
            let rows = group.chatRowIDs.compactMap { stats[$0] }
            guard let first = rows.map(\.first).min(), first > cutoff else { return nil }
            let count = rows.reduce(0) { $0 + $1.count }
            let fromMe = rows.reduce(0) { $0 + $1.fromMe }
            guard fromMe >= 2, count - fromMe >= 2 else { return nil }
            return Suggestion(
                key: group.key, title: group.title, firstContact: first, messageCount: count,
                preview: String(group.lastMessage.text.prefix(90)),
                lastFromMe: group.lastMessage.isFromMe
            )
        }
        .sorted { $0.messageCount > $1.messageCount }

        return NudgeResponse(
            due: due, upcoming: upcoming, suggestions: Array(suggestions.prefix(8)), generatedAt: now
        )
    }

    /// Handles a call log entry could be filed under for this thread. Only iMessage DMs
    /// carry phone numbers or emails; Beeper threads and groups get none.
    private static func callHandles(key: String, group: ThreadGroup?) -> [String] {
        guard key.hasPrefix("dm:") else { return [] }
        let fromKey = String(key.dropFirst(3))
        let fromGroup = (group?.handles ?? []).compactMap(ContactBook.normalizeHandle)
        return [fromKey] + fromGroup
    }

    /// `days == 0` stops tracking and also stops suggesting this person.
    func setCadence(key: String, days: Int, fallbackTitle: String?, callsOnly: Bool? = nil) throws {
        let known = try group(forKey: key)?.title ?? triage.keepInTouch()[key]?.title
        guard let title = known ?? fallbackTitle else {
            throw NSError(domain: "toreplyd", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "unknown thread \(key)"])
        }
        try triage.setCadence(key: key, title: title, days: days, callsOnly: callsOnly)
    }

    func snoozeNudge(key: String, until: Double) throws {
        try triage.snoozeNudge(key: key, until: until)
    }
}
