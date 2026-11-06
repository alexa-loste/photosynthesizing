import Foundation

enum TriageState: String, Codable {
    /// Owes a reply now.
    case toReply = "to_reply"
    /// Deferred to a specific time; resurfaces on its own.
    case snoozed
    /// Open-ended: the conversation isn't finished, but nothing is owed right now.
    /// "Let's schedule something when we're back" lives here — it would be wrong to
    /// mark it Done and wrong to leave it nagging in To Reply.
    case followUp = "follow_up"
    case done
}

struct StoredTriage {
    var state: TriageState
    /// The message ROWID this decision was made about. Anything newer supersedes it.
    var resolvedAtMessageRowID: Int64
    /// Unix seconds; 0 when not snoozed.
    var snoozeUntil: Double
    var updatedAt: Double
    /// Deliberately independent of triage state: the point of a favourite is to find
    /// someone again *after* you've cleared them, so it must survive being marked Done.
    var isFavorite: Bool = false
    /// Manual correction of the automatic sender classification. The heuristic is only
    /// a guess — a friend texting from a number you never saved reads as "unknown", and
    /// plenty of businesses use ordinary 10-digit numbers. Nil means trust the guess.
    var categoryOverride: SenderCategory?
}

/// Our own state, in our own database.
///
/// This is deliberately a separate file from chat.db — we never write a single byte to
/// Messages' database. Losing this file costs you your triage decisions; corrupting
/// chat.db would cost you your message history.
final class TriageStore {

    static let defaultPath = NSString(string: "~/.toreply/state.db").expandingTildeInPath

    private let db: SQLiteDB

    init(path: String = TriageStore.defaultPath) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        db = try SQLiteDB(path: path, readOnly: false)
        try db.execute("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS chat_state (
                chat_key              TEXT PRIMARY KEY,
                state                 TEXT    NOT NULL,
                resolved_at_msg_rowid INTEGER NOT NULL DEFAULT 0,
                snooze_until          INTEGER NOT NULL DEFAULT 0,
                updated_at            INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS keep_in_touch (
                chat_key      TEXT PRIMARY KEY,
                title         TEXT    NOT NULL,
                cadence_days  INTEGER NOT NULL,
                added_at      INTEGER NOT NULL,
                snooze_until  INTEGER NOT NULL DEFAULT 0
            );
            """)
        try migrate()
    }

    /// Additive migrations for databases created by an earlier version.
    private func migrate() throws {
        let stmt = try db.prepare("PRAGMA table_info(chat_state)")
        var columns: Set<String> = []
        while stmt.step() { columns.insert(stmt.string(1) ?? "") }

        if !columns.contains("is_favorite") {
            try db.execute(
                "ALTER TABLE chat_state ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0"
            )
        }
        if !columns.contains("category_override") {
            try db.execute("ALTER TABLE chat_state ADD COLUMN category_override TEXT")
        }

        let kit = try db.prepare("PRAGMA table_info(keep_in_touch)")
        var kitColumns: Set<String> = []
        while kit.step() { kitColumns.insert(kit.string(1) ?? "") }
        if !kitColumns.contains("calls_only") {
            try db.execute(
                "ALTER TABLE keep_in_touch ADD COLUMN calls_only INTEGER NOT NULL DEFAULT 0"
            )
        }
    }

    /// Snapshot the triage database.
    ///
    /// Everything else this app shows can be rebuilt from chat.db, which Apple owns and
    /// we only ever read. These triage decisions are the one thing that exists nowhere
    /// else, so they get real backups — restoring from one is a file copy, whereas
    /// reconstructing them means rewinding a write-ahead log frame by frame.
    @discardableResult
    func backup(directory: String = NSString(string: "~/.toreply/backups").expandingTildeInPath,
                keep: Int = 14) throws -> String {
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HHmm"
        let path = "\(directory)/state-\(formatter.string(from: Date())).db"

        // VACUUM INTO writes a consistent snapshot even while the database is in use.
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        try db.run("VACUUM INTO ?", [.text(path)])

        // Keep the most recent few and drop the rest.
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) {
            let snapshots = entries.filter { $0.hasPrefix("state-") }.sorted()
            for stale in snapshots.dropLast(keep) {
                try? FileManager.default.removeItem(atPath: "\(directory)/\(stale)")
            }
        }
        return path
    }

    func all() throws -> [String: StoredTriage] {
        let stmt = try db.prepare("""
            SELECT chat_key, state, resolved_at_msg_rowid, snooze_until, updated_at,
                   is_favorite, IFNULL(category_override, '')
            FROM chat_state
            """)
        var out: [String: StoredTriage] = [:]
        while stmt.step() {
            guard let key = stmt.string(0),
                  let raw = stmt.string(1),
                  let state = TriageState(rawValue: raw) else { continue }
            out[key] = StoredTriage(
                state: state,
                resolvedAtMessageRowID: stmt.int(2),
                snoozeUntil: Double(stmt.int(3)),
                updatedAt: Double(stmt.int(4)),
                isFavorite: stmt.int(5) != 0,
                categoryOverride: SenderCategory(rawValue: stmt.string(6) ?? "")
            )
        }
        return out
    }

    /// Pass nil to drop back to the automatic classification.
    func setCategoryOverride(key: String, category: SenderCategory?) throws {
        try db.run(
            """
            INSERT INTO chat_state
                (chat_key, state, resolved_at_msg_rowid, snooze_until, updated_at, category_override)
            VALUES (?, 'to_reply', 0, 0, ?, ?)
            ON CONFLICT(chat_key) DO UPDATE SET
                category_override = excluded.category_override,
                updated_at        = excluded.updated_at
            """,
            [
                .text(key),
                .int(Int64(Date().timeIntervalSince1970)),
                category.map { SQLValue.text($0.rawValue) } ?? .null,
            ]
        )
    }

    /// Upsert that touches only the favourite flag, leaving triage state alone.
    func setFavorite(key: String, isFavorite: Bool) throws {
        try db.run(
            """
            INSERT INTO chat_state
                (chat_key, state, resolved_at_msg_rowid, snooze_until, updated_at, is_favorite)
            VALUES (?, 'to_reply', 0, 0, ?, ?)
            ON CONFLICT(chat_key) DO UPDATE SET
                is_favorite = excluded.is_favorite,
                updated_at  = excluded.updated_at
            """,
            [
                .text(key),
                .int(Int64(Date().timeIntervalSince1970)),
                .int(isFavorite ? 1 : 0),
            ]
        )
    }

    func set(
        key: String, state: TriageState, resolvedAtMessageRowID: Int64, snoozeUntil: Double
    ) throws {
        try db.run(
            """
            INSERT INTO chat_state (chat_key, state, resolved_at_msg_rowid, snooze_until, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(chat_key) DO UPDATE SET
                state                 = excluded.state,
                resolved_at_msg_rowid = excluded.resolved_at_msg_rowid,
                snooze_until          = excluded.snooze_until,
                updated_at            = excluded.updated_at
            """,
            [
                .text(key),
                .text(state.rawValue),
                .int(resolvedAtMessageRowID),
                .int(Int64(snoozeUntil)),
                .int(Int64(Date().timeIntervalSince1970)),
            ]
        )
    }

    /// Resolve what a thread's state actually is right now.
    ///
    /// The whole design turns on `resolvedAtMessageRowID`. "Done" means *done as of
    /// message N* — never "done forever". If a newer message has arrived since you
    /// swiped, the decision is stale and we recompute from scratch, which is what makes
    /// a thread pop back into To Reply when someone texts you again. Without this,
    /// swiping Done would silently bury that person for good.
    static func effectiveState(
        group: ThreadGroup, stored: StoredTriage?, now: Double = Date().timeIntervalSince1970
    ) -> TriageState {
        guard let stored else {
            return group.needsReply ? .toReply : .done
        }
        if group.lastRowID > stored.resolvedAtMessageRowID {
            // A follow-up waits for *their* reply. Another text from you doesn't settle
            // it, or marking Follow up right after sending would race your own message
            // and drop the thread to Done.
            if stored.state == .followUp && !group.needsReply { return .followUp }
            return group.needsReply ? .toReply : .done
        }
        if stored.state == .snoozed, stored.snoozeUntil > 0, now >= stored.snoozeUntil {
            return .toReply
        }
        return stored.state
    }
}

// MARK: - Keep in touch

/// Someone you want to hear from on a rhythm, whether or not a reply is owed.
/// `cadenceDays == 0` keeps the row only to remember "don't suggest this person again".
struct KeepInTouchEntry {
    var key: String
    var title: String
    var cadenceDays: Int
    var addedAt: Double
    /// Set by "did it" (a call, a coffee) and by "later": the nudge stays quiet until then.
    var snoozeUntil: Double
    /// For people you want to actually talk to: texting doesn't reset the clock, only a
    /// call or "did it" does.
    var callsOnly: Bool = false
}

extension TriageStore {

    func keepInTouch() throws -> [String: KeepInTouchEntry] {
        let stmt = try db.prepare(
            "SELECT chat_key, title, cadence_days, added_at, snooze_until, calls_only FROM keep_in_touch"
        )
        var out: [String: KeepInTouchEntry] = [:]
        while stmt.step() {
            guard let key = stmt.string(0) else { continue }
            out[key] = KeepInTouchEntry(
                key: key,
                title: stmt.string(1) ?? key,
                cadenceDays: Int(stmt.int(2)),
                addedAt: Double(stmt.int(3)),
                snoozeUntil: Double(stmt.int(4)),
                callsOnly: stmt.int(5) != 0
            )
        }
        return out
    }

    /// Changing the cadence keeps `added_at` and clears any snooze. A nil `callsOnly`
    /// leaves that setting as it was.
    func setCadence(key: String, title: String, days: Int, callsOnly: Bool? = nil) throws {
        try db.run(
            """
            INSERT INTO keep_in_touch (chat_key, title, cadence_days, added_at, snooze_until, calls_only)
            VALUES (?, ?, ?, ?, 0, IFNULL(?, 0))
            ON CONFLICT(chat_key) DO UPDATE SET
                title        = excluded.title,
                cadence_days = excluded.cadence_days,
                snooze_until = 0,
                calls_only   = IFNULL(?, calls_only)
            """,
            [
                .text(key), .text(title), .int(Int64(days)), .int(Int64(Date().timeIntervalSince1970)),
                callsOnly.map { .int($0 ? 1 : 0) } ?? .null,
                callsOnly.map { .int($0 ? 1 : 0) } ?? .null,
            ]
        )
    }

    func snoozeNudge(key: String, until: Double) throws {
        try db.run(
            "UPDATE keep_in_touch SET snooze_until = ? WHERE chat_key = ?",
            [.int(Int64(until)), .text(key)]
        )
    }
}
