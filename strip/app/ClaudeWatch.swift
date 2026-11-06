import Foundation

/// Reads the files `hook/tv_hook.py` writes and says whether a turn you prompted is running.
struct ClaudeWatch {
    struct Session {
        var id: String
        var started: Date
        var project: String
        var needsYou: Bool
    }

    static let root = URL(fileURLWithPath: NSString(string: "~/.claude-tv").expandingTildeInPath)
    private static let working = root.appendingPathComponent("working")
    private static let attention = root.appendingPathComponent("attention")

    /// A turn interrupted with Esc never fires Stop, so its file would hold the strip open
    /// forever. Past this age, or once its Claude process is gone, a file is ignored.
    private static let staleAfter: TimeInterval = 45 * 60

    private struct Record: Decodable {
        var started: Double
        var pid: Int32
        var project: String
    }

    static func sessions(now: Date = Date()) -> [Session] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: working.path)) ?? []
        return names.compactMap { name in
            let file = working.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
            let started = Date(timeIntervalSince1970: record.started)
            if now.timeIntervalSince(started) > staleAfter { return nil }
            if record.pid > 0 && kill(record.pid, 0) != 0 && errno == ESRCH { return nil }
            let needsYou = FileManager.default.fileExists(
                atPath: attention.appendingPathComponent(name).path
            )
            return Session(id: name, started: started, project: record.project, needsYou: needsYou)
        }
    }
}
