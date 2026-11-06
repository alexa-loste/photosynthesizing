import Foundation

/// Reads the files `hook/tv_hook.py` writes: which turns you prompted are running, which
/// are waiting on you, and which just finished.
struct ClaudeWatch {
    struct Session: Identifiable, Equatable {
        enum State: Equatable {
            case working(since: Date)
            case needsYou
            case done(at: Date)
        }

        var id: String
        var project: String
        /// The first words of what you asked, to tell sessions apart.
        var prompt: String
        var state: State

        var isWorking: Bool { if case .working = state { return true } else { return false } }
        var isDone: Bool { if case .done = state { return true } else { return false } }
        var needsYou: Bool { state == .needsYou }
        var started: Date { if case .working(let since) = state { return since } else { return .distantPast } }
    }

    static let root = URL(fileURLWithPath: NSString(string: "~/.claude-tv").expandingTildeInPath)
    private static let working = root.appendingPathComponent("working")
    private static let attention = root.appendingPathComponent("attention")
    private static let done = root.appendingPathComponent("done")

    /// A turn interrupted with Esc never fires Stop, so its file would hold the strip open
    /// forever. Past this age, or once its Claude process is gone, a file is ignored.
    private static let staleAfter: TimeInterval = 45 * 60
    /// Finished sessions stay listed this long, or until you prompt that session again.
    private static let doneFor: TimeInterval = 30 * 60

    private struct Record: Decodable {
        var started: Double
        var pid: Int32?
        var project: String?
        var prompt: String?
        var finished: Double?
    }

    static func sessions(now: Date = Date()) -> [Session] {
        var out: [Session] = []
        for (name, record) in records(in: working) {
            let started = Date(timeIntervalSince1970: record.started)
            if now.timeIntervalSince(started) > staleAfter { continue }
            if let pid = record.pid, pid > 0, kill(pid, 0) != 0, errno == ESRCH { continue }
            let waiting = FileManager.default.fileExists(atPath: attention.appendingPathComponent(name).path)
            out.append(Session(
                id: name, project: record.project ?? "", prompt: tidy(record.prompt),
                state: waiting ? .needsYou : .working(since: started)
            ))
        }
        for (name, record) in records(in: done) where !out.contains(where: { $0.id == name }) {
            guard let finished = record.finished.map(Date.init(timeIntervalSince1970:)),
                  now.timeIntervalSince(finished) < doneFor else { continue }
            out.append(Session(
                id: name, project: record.project ?? "", prompt: tidy(record.prompt),
                state: .done(at: finished)
            ))
        }
        return out.sorted { order($0) < order($1) }
    }

    /// Forget a finished session (you've seen it).
    static func dismiss(_ id: String) {
        try? FileManager.default.removeItem(at: done.appendingPathComponent(id))
    }

    private static func records(in directory: URL) -> [(String, Record)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
            return (name, record)
        }
    }

    /// Needs you first, then just finished, then still working, oldest first.
    private static func order(_ session: Session) -> (Int, Double) {
        switch session.state {
        case .needsYou: return (0, 0)
        case .done(let at): return (1, -at.timeIntervalSince1970)
        case .working(let since): return (2, since.timeIntervalSince1970)
        }
    }

    private static func tidy(_ prompt: String?) -> String {
        let flat = (prompt ?? "").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > 48 ? String(flat.prefix(47)) + "…" : flat
    }
}
