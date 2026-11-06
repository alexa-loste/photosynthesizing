import Foundation

/// Phone and FaceTime calls, from the call log iCloud syncs from the iPhone to this Mac.
///
/// Read-only, like chat.db, and behind the same Full Disk Access grant. Only connected
/// calls count (duration > 0): a missed call isn't being in touch.
final class CallHistory {

    static let defaultPath = NSString(
        string: "~/Library/Application Support/CallHistoryDB/CallHistory.storedata"
    ).expandingTildeInPath

    private let db: SQLiteDB
    private let lock = NSLock()
    private var cached: [String: Double] = [:]
    private var cachedAt: Double = 0

    init?(path: String = CallHistory.defaultPath) {
        guard let db = try? SQLiteDB(path: path, readOnly: true) else { return nil }
        self.db = db
    }

    /// Normalized handle → unix time of the last connected call with it.
    func lastCalls() -> [String: Double] {
        let now = Date().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        if now - cachedAt < 60 { return cached }

        var out: [String: Double] = [:]
        if let stmt = try? db.prepare("""
            SELECT ZADDRESS, MAX(ZDATE) FROM ZCALLRECORD
            WHERE ZDURATION > 0 AND ZADDRESS IS NOT NULL
            GROUP BY ZADDRESS
            """) {
            while stmt.step() {
                guard let raw = stmt.string(0),
                      let handle = ContactBook.normalizeHandle(raw) else { continue }
                // ZDATE is seconds since 2001, stored as a float.
                let date = (Double(stmt.string(1) ?? "") ?? 0) + AppleDate.epochOffset
                out[handle] = max(out[handle] ?? 0, date)
            }
        }
        cached = out
        cachedAt = now
        return out
    }
}
