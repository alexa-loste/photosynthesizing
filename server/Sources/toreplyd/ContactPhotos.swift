import Foundation

/// Contact photos from AddressBook, for iMessage threads' avatars.
///
/// `ZABCDRECORD.ZTHUMBNAILIMAGEDATA` comes in two shapes, told apart by its first byte:
/// 0x01 then the JPEG itself, or 0x02 then a UUID naming a file in the store's
/// `.AddressBook-v22_SUPPORT/_EXTERNAL_DATA/` folder (larger photos live there).
final class ContactPhotos {

    private struct Ref {
        var store: String
        var recordID: Int64
    }

    private var byHandle: [String: Ref] = [:]
    private let lock = NSLock()
    private var cache: [String: Data] = [:]

    init() {
        for path in ContactBook.storePaths() {
            guard let db = try? SQLiteDB(path: path, readOnly: true) else { continue }
            index(db: db, store: path, sql: """
                SELECT r.Z_PK, p.ZFULLNUMBER FROM ZABCDPHONENUMBER p
                JOIN ZABCDRECORD r ON r.Z_PK = p.ZOWNER
                WHERE r.ZTHUMBNAILIMAGEDATA IS NOT NULL AND p.ZFULLNUMBER IS NOT NULL
                """)
            index(db: db, store: path, sql: """
                SELECT r.Z_PK, e.ZADDRESS FROM ZABCDEMAILADDRESS e
                JOIN ZABCDRECORD r ON r.Z_PK = e.ZOWNER
                WHERE r.ZTHUMBNAILIMAGEDATA IS NOT NULL AND e.ZADDRESS IS NOT NULL
                """)
        }
    }

    var count: Int { byHandle.count }

    private func index(db: SQLiteDB, store: String, sql: String) {
        guard let stmt = try? db.prepare(sql) else { return }
        while stmt.step() {
            guard let raw = stmt.string(1),
                  let handle = ContactBook.normalizeHandle(raw),
                  byHandle[handle] == nil else { continue }
            byHandle[handle] = Ref(store: store, recordID: stmt.int(0))
        }
    }

    /// JPEG bytes for the first of these handles that has a photo.
    func photo(handles: [String]) -> Data? {
        for raw in handles {
            guard let handle = ContactBook.normalizeHandle(raw) else { continue }
            lock.lock()
            if let hit = cache[handle] { lock.unlock(); return hit }
            lock.unlock()
            guard let ref = byHandle[handle], let data = load(ref) else { continue }
            lock.lock()
            cache[handle] = data
            lock.unlock()
            return data
        }
        return nil
    }

    private func load(_ ref: Ref) -> Data? {
        guard let db = try? SQLiteDB(path: ref.store, readOnly: true),
              let stmt = try? db.prepare(
                  "SELECT ZTHUMBNAILIMAGEDATA FROM ZABCDRECORD WHERE Z_PK = ?", [.int(ref.recordID)]
              ),
              stmt.step(),
              let blob = stmt.blob(0), let marker = blob.first else { return nil }

        switch marker {
        case 0x01:
            return blob.dropFirst()
        case 0x02:
            let uuid = String(decoding: blob.dropFirst().prefix { $0 != 0 }, as: UTF8.self)
            let folder = (ref.store as NSString).deletingLastPathComponent
            return FileManager.default.contents(
                atPath: "\(folder)/.AddressBook-v22_SUPPORT/_EXTERNAL_DATA/\(uuid)"
            )
        default:
            return nil
        }
    }
}

/// Birthdays from AddressBook, as "MM-dd", for the keep-in-touch roster.
///
/// ZBIRTHDAY is a full date (seconds since 2001); cards saved without a year have only
/// ZBIRTHDAYYEARLESS, the same kind of offset placed in 2001. Either way the month and
/// day come out of strftime in UTC, which is how Contacts stores them (noon UTC).
final class ContactBirthdays {

    private var byHandle: [String: String] = [:]

    init() {
        for path in ContactBook.storePaths() {
            guard let db = try? SQLiteDB(path: path, readOnly: true) else { continue }
            let date = """
                strftime('%m-%d', IFNULL(r.ZBIRTHDAY, r.ZBIRTHDAYYEARLESS) + 978307200, 'unixepoch')
                """
            for (table, column) in [("ZABCDPHONENUMBER", "ZFULLNUMBER"), ("ZABCDEMAILADDRESS", "ZADDRESS")] {
                guard let stmt = try? db.prepare("""
                    SELECT \(date), x.\(column) FROM \(table) x
                    JOIN ZABCDRECORD r ON r.Z_PK = x.ZOWNER
                    WHERE (r.ZBIRTHDAY IS NOT NULL OR r.ZBIRTHDAYYEARLESS IS NOT NULL)
                      AND x.\(column) IS NOT NULL
                    """) else { continue }
                while stmt.step() {
                    guard let day = stmt.string(0), let raw = stmt.string(1),
                          let handle = ContactBook.normalizeHandle(raw) else { continue }
                    byHandle[handle] = byHandle[handle] ?? day
                }
            }
        }
    }

    var count: Int { byHandle.count }

    func birthday(handles: [String]) -> String? {
        handles.lazy.compactMap { ContactBook.normalizeHandle($0) }.compactMap { self.byHandle[$0] }.first
    }
}
