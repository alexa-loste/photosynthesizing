import Foundation
import SwiftUI

/// Everything the strip shows: the To Reply queue, keep-in-touch nudges, the open
/// conversation, and what Claude is doing.
@MainActor
final class StripModel: ObservableObject {

    enum Claude: Equatable {
        case idle
        case working(since: Date, projects: [String])
        case needsYou(projects: [String])
        case done
    }

    /// Reply, Follow up and Later are queues of threads; Keep in touch is the roster.
    enum Tab: CaseIterable {
        case reply, later, keepInTouch, all

        var isQueue: Bool { self != .keepInTouch }

        /// What each queue pulls from To Reply. Later holds both the backlog (snoozed) and
        /// threads you texted last and mean to come back to (follow_up); All is every
        /// conversation, newest first. A nil bucket means every bucket.
        var sources: [(bucket: TriageState?, people: PeopleFilter)] {
            switch self {
            // Groups stay out of Reply, as on the phone.
            case .reply: return [(.toReply, .known)]
            case .later: return [(.snoozed, .all), (.followUp, .all)]
            case .all: return [(nil, .all)]
            case .keepInTouch: return []
            }
        }
    }

    /// The conversation on screen, whichever tab opened it.
    struct Focus: Equatable {
        var key: String
        var title: String
        var isGroup: Bool
        var service: String? = nil
    }

    @Published var claude: Claude = .idle
    @Published var tab: Tab = .reply
    /// Each queue's threads, and the thread open in each, so switching tabs keeps your place.
    @Published var queues: [Tab: [ThreadSummary]] = [:]
    @Published var selected: [Tab: String] = [:]
    @Published var nudges: NudgeResponse?
    /// A keep-in-touch person opened for texting; nil shows the list.
    @Published var openNudge: Focus?
    @Published var messages: [Message] = []
    @Published var drafts: [String: String] = [:]
    /// Threads you've replied to here. They stay open so you can send several texts in a
    /// row, and leave the queue when you move on.
    @Published var sent: Set<String> = []
    /// Threads opened from search into a queue they aren't in; they stay until you move on.
    private var pulledIn: Set<String> = []
    /// Filters the open queue by name, and finds conversations outside it.
    @Published var queueFilter = "" {
        didSet { scheduleQueueSearch() }
    }
    @Published var otherResults: [ThreadSummary] = []
    private var queueSearchTask: Task<Void, Never>?
    /// Last keystroke or send. The strip waits for a quiet spell before sliding away.
    private(set) var lastActivity = Date.distantPast
    @Published var searchQuery = "" {
        didSet { scheduleSearch() }
    }
    @Published var searchResults: [ThreadSummary] = []
    private var searchTask: Task<Void, Never>?
    @Published var pinned = false
    @Published var busy = false
    @Published var error: String?

    let client: APIClient?
    let keepInTouch: KeepInTouchClient?
    private var eventsTask: Task<Void, Never>?

    init(config: ServerConfig?) {
        client = config.map { APIClient(config: $0) }
        keepInTouch = config.map { KeepInTouchClient(config: $0) }
        if client == nil {
            error = "No server config at ~/.claude-tv/config.json. See the README."
        }
    }

    /// The open tab's queue (empty on Keep in touch).
    var threads: [ThreadSummary] { queues[tab] ?? [] }

    func count(_ tab: Tab) -> Int { queues[tab]?.count ?? 0 }

    var current: ThreadSummary? { threads.first { $0.key == selected[tab] } }

    var focus: Focus? {
        if tab.isQueue {
            return current.map {
                Focus(key: $0.key, title: $0.title, isGroup: $0.isGroup, service: $0.service)
            }
        }
        return openNudge
    }

    var position: Int { (threads.firstIndex { $0.key == selected[tab] } ?? 0) + 1 }

    /// The whole queue after the open thread, wrapping round, so you can pick anyone.
    var queue: [ThreadSummary] {
        guard let index = threads.firstIndex(where: { $0.key == selected[tab] }) else { return threads }
        return Array(threads[(index + 1)...] + threads[..<index])
    }

    var upNext: [ThreadSummary] { Array(queue.prefix(4)) }

    /// The queue list as shown: everything, or just the names matching the search box.
    var filteredQueue: [ThreadSummary] {
        let needle = queueFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return queue }
        return threads.filter { $0.title.lowercased().contains(needle) }
    }

    private func scheduleQueueSearch() {
        queueSearchTask?.cancel()
        let query = queueFilter.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2, let client else {
            otherResults = []
            return
        }
        queueSearchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let found = try? await client.search(query) else { return }
            guard query == queueFilter.trimmingCharacters(in: .whitespaces) else { return }
            let here = Set(threads.map(\.key))
            otherResults = Array(found.threads.filter { !here.contains($0.key) }.prefix(6))
        }
    }

    /// Opens a search hit in this queue, even if it isn't in it, so you can reply.
    func openFromSearch(_ thread: ThreadSummary) {
        if !threads.contains(where: { $0.key == thread.key }) {
            queues[tab, default: []].insert(thread, at: 0)
            pulledIn.insert(thread.key)
        }
        queueFilter = ""
        open(thread.key)
    }

    var dueCount: Int { nudges?.due.count ?? 0 }

    func cadence(for key: String) -> Int? {
        let all = (nudges?.due ?? []) + (nudges?.upcoming ?? [])
        return all.first { $0.key == key }?.cadenceDays
    }

    var draft: String {
        get { focus.flatMap { drafts[$0.key] } ?? "" }
        set {
            if let key = focus?.key { drafts[key] = newValue }
            lastActivity = Date()
        }
    }

    var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True while you're in a conversation: a half-written reply, or typing or sending
    /// in the last 20 seconds. The strip stays up until this goes false.
    var isMidReply: Bool {
        hasDraft || Date().timeIntervalSince(lastActivity) < 20
    }

    // MARK: - Loading

    func startListening() {
        guard let client, eventsTask == nil else { return }
        eventsTask = Task { [weak self] in
            for await _ in client.events() {
                await self?.reload()
            }
        }
    }

    func reload() async {
        guard let client else { return }
        do {
            for queue in Tab.allCases where queue.isQueue {
                var fresh: [ThreadSummary] = []
                for source in queue.sources {
                    fresh += try await client.threads(bucket: source.bucket, people: source.people).threads
                }
                fresh = fresh.filter { $0.category != .automated }
                if queue != .reply {
                    fresh.sort { $0.lastMessage.date > $1.lastMessage.date }
                }
                // Replying moves a thread out of its bucket on the server. Keep the ones
                // you replied to here in place until you move on, or the update your own
                // send triggers would yank the conversation away mid-thread.
                for (index, thread) in (queues[queue] ?? []).enumerated()
                where (sent.contains(thread.key) || pulledIn.contains(thread.key))
                    && !fresh.contains(where: { $0.key == thread.key }) {
                    fresh.insert(thread, at: min(index, fresh.count))
                }
                queues[queue] = fresh
                if !fresh.contains(where: { $0.key == selected[queue] }) {
                    // All is a list you pick from; the queues open their first thread.
                    selected[queue] = queue == .all ? nil : fresh.first?.key
                }
            }
            nudges = try await keepInTouch?.nudges()
            error = nil
            await loadMessages()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMessages() async {
        guard let client, let key = focus?.key else {
            messages = []
            return
        }
        do {
            let loaded = try await client.messages(key: key, limit: 14)
            if key == focus?.key { messages = loaded }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func select(_ tab: Tab) {
        self.tab = tab
        messages = []
        Task { await loadMessages() }
    }

    func open(_ key: String) {
        dropSent(except: key)
        selected[tab] = key
        messages = []
        Task { await loadMessages() }
    }

    func openNudge(_ nudge: NudgeResponse.Nudge) {
        openConversation(key: nudge.key, title: nudge.title, isGroup: nudge.isGroup, service: nudge.service)
    }

    func openConversation(key: String, title: String, isGroup: Bool, service: String? = nil) {
        openNudge = Focus(key: key, title: title, isGroup: isGroup, service: service)
        messages = []
        Task { await loadMessages() }
    }

    /// Moves the open thread to another queue (Reply, Follow up or Later) and goes on to
    /// the next one here.
    func move(to target: Tab) {
        guard let client, let key = focus?.key, target == .reply || target == .later, !busy else { return }
        // Later has no wake-up time: it waits until you go through it, or comes back to
        // Reply if they text you. After you've replied it's stored as a follow-up, which
        // your own message can't settle; before, as a snooze.
        let state: TriageState = target == .reply
            ? .toReply : (sent.contains(key) ? .followUp : .snoozed)
        perform(key: key) {
            _ = try await client.setState(key: key, state: state, snoozeUntil: 0)
        }
    }

    /// Back from a conversation to the All list.
    func closeConversation() {
        selected[.all] = nil
        messages = []
    }

    func closeNudge() {
        openNudge = nil
        messages = []
    }

    /// Adds the reaction on screen straight away and takes it back if the send fails.
    func react(to message: Message, emoji: String) {
        guard let keepInTouch, let key = focus?.key, key.hasPrefix("bp:") else { return }
        let mine = Reaction(emoji: emoji, fromMe: true, sender: "You")
        if let index = messages.firstIndex(where: { $0.guid == message.guid }) {
            messages[index].reactions.append(mine)
        }
        Task {
            do {
                try await keepInTouch.react(key: key, messageID: message.guid, emoji: emoji)
            } catch {
                self.error = error.localizedDescription
                if let index = messages.firstIndex(where: { $0.guid == message.guid }),
                   let last = messages[index].reactions.lastIndex(where: { $0.fromMe && $0.emoji == emoji }) {
                    messages[index].reactions.remove(at: last)
                }
            }
        }
    }

    // MARK: - Reply actions

    /// Next thread in the queue: "Skip" before you reply, "Next" after.
    func skip() {
        guard tab.isQueue else { return }
        guard let next = upNext.first(where: { !sent.contains($0.key) }) else {
            dropSent(except: "")
            selected[tab] = threads.first?.key
            messages = []
            Task { await loadMessages() }
            return
        }
        open(next.key)
    }

    /// Sends and stays on the thread, showing the text straight away rather than waiting
    /// for it to come back through chat.db.
    func send() {
        guard let client, let key = focus?.key, hasDraft, !busy else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await client.send(key: key, body: body)
                drafts[key] = nil
                lastActivity = Date()
                sent.insert(key)
                if key == focus?.key { messages.append(Self.echo(body)) }
                error = nil
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if key == focus?.key { await loadMessages() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private static func echo(_ body: String) -> Message {
        let now = Date().timeIntervalSince1970
        return Message(
            rowID: Int64.max - Int64(now * 1000), guid: UUID().uuidString, date: now,
            isFromMe: true, text: body, sender: "", hasAttachments: false, isEdited: false,
            service: "iMessage", isDelivered: false, reactions: [], attachments: []
        )
    }

    /// Replied-to threads leave the reply queue once you move to another one.
    private func dropSent(except key: String) {
        for queue in Tab.allCases where queue.isQueue {
            queues[queue]?.removeAll {
                (sent.contains($0.key) || pulledIn.contains($0.key)) && $0.key != key
            }
        }
        sent = sent.filter { $0 == key }
        pulledIn = pulledIn.filter { $0 == key }
    }

    func markDone() {
        guard let client, let key = focus?.key, !busy else { return }
        perform(key: key) {
            _ = try await client.setState(key: key, state: .done)
        }
    }

    /// Everyone you're tracking, most overdue first, then by when they come due.
    var roster: [NudgeResponse.Nudge] {
        (nudges?.due ?? []) + (nudges?.upcoming ?? [])
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2, let client else {
            searchResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled,
                  let found = try? await client.search(query) else { return }
            if query == searchQuery.trimmingCharacters(in: .whitespaces) {
                searchResults = Array(found.threads.prefix(8))
            }
        }
    }

    // MARK: - Keep-in-touch actions

    func setCadence(key: String, title: String, days: Int) {
        guard let keepInTouch else { return }
        run { try await keepInTouch.setCadence(key: key, days: days, title: title) }
    }

    func nudge(for key: String) -> NudgeResponse.Nudge? {
        roster.first { $0.key == key }
    }

    func setCallsOnly(_ nudge: NudgeResponse.Nudge, _ on: Bool) {
        guard let keepInTouch else { return }
        run {
            try await keepInTouch.setCadence(
                key: nudge.key, days: nudge.cadenceDays, title: nudge.title, callsOnly: on
            )
        }
    }

    /// "Caught up": in touch some other way (a call, seeing them), so quiet for one cadence.
    func didIt(_ nudge: NudgeResponse.Nudge) {
        guard let keepInTouch else { return }
        let until = Date().timeIntervalSince1970 + Double(nudge.cadenceDays) * 86_400
        run { try await keepInTouch.snooze(key: nudge.key, until: until) }
    }

    func remindLater(_ nudge: NudgeResponse.Nudge, days: Double = 3) {
        guard let keepInTouch else { return }
        let until = Date().timeIntervalSince1970 + days * 86_400
        run { try await keepInTouch.snooze(key: nudge.key, until: until) }
    }

    private func run(_ write: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await write()
                nudges = try await keepInTouch?.nudges()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Runs a write on the open conversation, then moves on: to the next thread in this
    /// queue, or back to the keep-in-touch list.
    private func perform(key: String, _ write: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await write()
                drafts[key] = nil
                error = nil
                if tab.isQueue {
                    let next = upNext.first { $0.key != key }?.key
                    queues[tab]?.removeAll { $0.key == key }
                    sent.remove(key)
                    selected[tab] = next
                    messages = []
                } else {
                    closeNudge()
                }
                await reload()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
