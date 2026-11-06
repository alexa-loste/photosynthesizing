import Foundation
import SQLite3

/// sqlite3 wants to know whether the bytes we hand it will outlive the call.
/// They won't — Swift Strings/Datas are temporary here — so always copy.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteError: Error, CustomStringConvertible {
    case open(path: String, message: String)
    case prepare(sql: String, message: String)
    case exec(message: String)

    var description: String {
        switch self {
        case .open(let path, let message):
            return "sqlite open failed for \(path): \(message)"
        case .prepare(let sql, let message):
            return "sqlite prepare failed: \(message)\nSQL: \(sql)"
        case .exec(let message):
            return "sqlite exec failed: \(message)"
        }
    }
}

enum SQLValue {
    case int(Int64)
    case text(String)
    case blob(Data)
    case null
}

final class SQLiteDB {
    fileprivate let handle: OpaquePointer

    init(path: String, readOnly: Bool) throws {
        var h: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let opened = h else {
            let message = h.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let h { sqlite3_close_v2(h) }
            throw SQLiteError.open(path: path, message: message)
        }
        handle = opened
        // Messages writes constantly; don't fail instantly on a write lock.
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close_v2(handle) }

    var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(err)
            throw SQLiteError.exec(message: message)
        }
    }

    func prepare(_ sql: String, _ params: [SQLValue] = []) throws -> Statement {
        let stmt = try Statement(db: self, sql: sql)
        stmt.bind(params)
        return stmt
    }

    /// Run a statement that returns no rows.
    func run(_ sql: String, _ params: [SQLValue] = []) throws {
        let stmt = try prepare(sql, params)
        _ = stmt.step()
    }
}

final class Statement {
    private let stmt: OpaquePointer
    private let sql: String

    init(db: SQLiteDB, sql: String) throws {
        self.sql = sql
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, sql, -1, &s, nil) == SQLITE_OK, let prepared = s else {
            throw SQLiteError.prepare(sql: sql, message: db.lastErrorMessage)
        }
        stmt = prepared
    }

    deinit { sqlite3_finalize(stmt) }

    func bind(_ values: [SQLValue]) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let v):
                sqlite3_bind_int64(stmt, index, v)
            case .text(let v):
                sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                _ = v.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
                }
            case .null:
                sqlite3_bind_null(stmt, index)
            }
        }
    }

    /// Advance to the next row. Returns false when the result set is exhausted.
    func step() -> Bool { sqlite3_step(stmt) == SQLITE_ROW }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(stmt, column) }
    func bool(_ column: Int32) -> Bool { sqlite3_column_int64(stmt, column) != 0 }

    func string(_ column: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: c)
    }

    func blob(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, column) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, column))
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
    }

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(stmt, column) == SQLITE_NULL
    }
}
