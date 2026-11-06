import Foundation

/// chat.db stores only raw handles — phone numbers and email addresses. Names live in
/// AddressBook, in a completely separate Core Data SQLite store. Without this lookup the
/// whole app is a list of phone numbers, which is useless for triage.
///
/// There are several AddressBook stores (one per account source, plus a local one), so we
/// merge them all. ~523 of 556 records here have both a name and a phone number.
struct ContactBook {

    private var byPhone: [String: String] = [:]
    private var byEmail: [String: String] = [:]

    /// AddressBook formats numbers for humans and inconsistently:
    /// `(555) 123-4567`, `+15551234567`, `+1 (555) 123-4567`, `0555 123 4567`.
    /// chat.db is consistently E.164. Reduce both to comparable digits.
    static func normalizePhone(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        // Last 10 digits ignores country code and trunk-prefix differences, which is
        // what actually varies between the two databases.
        return digits.count > 10 ? String(digits.suffix(10)) : digits
    }

    static func isEmailHandle(_ handle: String) -> Bool { handle.contains("@") }

    static func normalizeHandle(_ handle: String) -> String? {
        if isEmailHandle(handle) { return handle.lowercased() }
        return normalizePhone(handle)
    }

    /// Look up a display name; falls back to a prettier form of the raw handle.
    func name(for handle: String) -> String {
        guard let key = Self.normalizeHandle(handle) else { return handle }
        if Self.isEmailHandle(handle) {
            return byEmail[key] ?? handle
        }
        return byPhone[key] ?? Self.prettyPhone(handle)
    }

    /// True when we actually know this person, vs. just reformatting their number.
    func isKnown(_ handle: String) -> Bool {
        guard let key = Self.normalizeHandle(handle) else { return false }
        return Self.isEmailHandle(handle) ? byEmail[key] != nil : byPhone[key] != nil
    }

    static func prettyPhone(_ handle: String) -> String {
        let digits = handle.filter(\.isNumber)
        guard digits.count == 10 || (digits.count == 11 && digits.hasPrefix("1")) else {
            return handle
        }
        let d = Array(digits.suffix(10))
        return "(\(String(d[0...2]))) \(String(d[3...5]))-\(String(d[6...9]))"
    }

    // MARK: - Loading

    static func load() -> ContactBook {
        var book = ContactBook()
        for path in storePaths() {
            book.merge(from: path)
        }
        return book
    }

    static func storePaths() -> [String] {
        let fm = FileManager.default
        let root = NSString(string: "~/Library/Application Support/AddressBook").expandingTildeInPath
        var paths: [String] = []

        let topLevel = "\(root)/AddressBook-v22.abcddb"
        if fm.fileExists(atPath: topLevel) { paths.append(topLevel) }

        let sources = "\(root)/Sources"
        if let entries = try? fm.contentsOfDirectory(atPath: sources) {
            for entry in entries {
                let candidate = "\(sources)/\(entry)/AddressBook-v22.abcddb"
                if fm.fileExists(atPath: candidate) { paths.append(candidate) }
            }
        }
        return paths
    }

    private mutating func merge(from path: String) {
        // Contacts.app may hold this open; read-only keeps us out of its way. A single
        // unreadable store shouldn't take down name resolution for the others.
        guard let db = try? SQLiteDB(path: path, readOnly: true) else { return }

        loadRows(
            db: db,
            sql: """
                SELECT r.ZFIRSTNAME, r.ZLASTNAME, r.ZNICKNAME, r.ZORGANIZATION, p.ZFULLNUMBER
                FROM ZABCDPHONENUMBER p
                JOIN ZABCDRECORD r ON r.Z_PK = p.ZOWNER
                WHERE p.ZFULLNUMBER IS NOT NULL
                """,
            store: { handle, name in
                if let key = Self.normalizePhone(handle), self.byPhone[key] == nil {
                    self.byPhone[key] = name
                }
            }
        )

        loadRows(
            db: db,
            sql: """
                SELECT r.ZFIRSTNAME, r.ZLASTNAME, r.ZNICKNAME, r.ZORGANIZATION, e.ZADDRESS
                FROM ZABCDEMAILADDRESS e
                JOIN ZABCDRECORD r ON r.Z_PK = e.ZOWNER
                WHERE e.ZADDRESS IS NOT NULL
                """,
            store: { handle, name in
                let key = handle.lowercased()
                if self.byEmail[key] == nil { self.byEmail[key] = name }
            }
        )
    }

    private func loadRows(db: SQLiteDB, sql: String, store: (String, String) -> Void) {
        guard let stmt = try? db.prepare(sql) else { return }
        while stmt.step() {
            guard let handle = stmt.string(4), !handle.isEmpty else { continue }
            guard let name = Self.assembleName(
                first: stmt.string(0),
                last: stmt.string(1),
                nickname: stmt.string(2),
                organization: stmt.string(3)
            ) else { continue }
            store(handle, name)
        }
    }

    private static func assembleName(
        first: String?, last: String?, nickname: String?, organization: String?
    ) -> String? {
        if let nickname, !nickname.isEmpty { return nickname }
        let parts = [first, last].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        if let organization, !organization.isEmpty { return organization }
        return nil
    }
}
