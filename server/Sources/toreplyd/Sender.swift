import Foundation

enum SendError: Error, CustomStringConvertible {
    case messagesNotRunning
    case scriptFailed(status: Int32, output: String)
    case emptyBody
    case chatNotFound(String)
    case ambiguousRecipient(String)

    var description: String {
        switch self {
        case .messagesNotRunning:
            return "Messages.app is not running on the Mac mini"
        case .emptyBody:
            return "refusing to send an empty message"
        case .chatNotFound(let guid):
            return "Messages has no chat with id \(guid)"
        case .ambiguousRecipient(let detail):
            return "refusing to send — recipient is ambiguous: \(detail)"
        case .scriptFailed(let status, let output):
            return "AppleScript failed (exit \(status)): \(output)"
        }
    }
}

/// Where a message is going, resolved to a specific person or chat.
///
/// This type exists because of a real incident: a send was issued against a bare phone
/// number that had been derived from the wrong database column, and it reached a friend
/// instead of the intended self-test. A raw handle carries no identity, so nothing could
/// catch the mistake before delivery. Every send now goes through a target that knows the
/// display name of who will receive it, and callers are expected to show it first.
struct SendTarget {
    enum Route {
        /// One-to-one. Uses the participant form.
        case participant(handle: String, service: String)
        /// Group chat. Must be addressed as a chat object.
        case chat(guid: String)
    }

    var route: Route
    /// Human-readable name of the recipient, for confirmation and logging.
    var displayName: String
}

enum Sender {

    /// Body and recipient are passed as `argv`, never interpolated into the script
    /// source. Otherwise a message containing a quote or backslash would corrupt the
    /// script, and a crafted incoming message quoted into a reply could inject
    /// AppleScript. `on run argv` keeps data strictly out of code.
    ///
    /// Addressing note: `chat id "…"` raises error -1728 on macOS 26 even for guids that
    /// Messages itself reports, so we do not use it. One-to-one messages go through
    /// `participant … of account`, and group chats are matched by walking `chats`.
    private static let participantScript = """
        on run argv
            set messageBody to item 1 of argv
            set targetHandle to item 2 of argv
            set wantsSMS to ((item 3 of argv) is "SMS")
            tell application "Messages"
                if wantsSMS then
                    set targetAccount to 1st account whose service type = SMS
                else
                    set targetAccount to 1st account whose service type = iMessage
                end if
                send messageBody to participant targetHandle of targetAccount
            end tell
        end run
        """

    private static let chatScript = """
        on run argv
            set messageBody to item 1 of argv
            set targetGUID to item 2 of argv
            tell application "Messages"
                repeat with theChat in chats
                    if (id of theChat) is targetGUID then
                        send messageBody to theChat
                        return "sent"
                    end if
                end repeat
            end tell
            error "CHAT_NOT_FOUND"
        end run
        """

    static func send(body: String, to target: SendTarget) throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SendError.emptyBody }
        guard isMessagesRunning() else { throw SendError.messagesNotRunning }

        switch target.route {
        case .participant(let handle, let service):
            guard !handle.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw SendError.ambiguousRecipient("empty handle")
            }
            let smsLike = (service == "SMS" || service == "RCS") ? "SMS" : "iMessage"
            try run(script: participantScript, arguments: [body, handle, smsLike])

        case .chat(let guid):
            guard !guid.isEmpty else { throw SendError.ambiguousRecipient("empty chat guid") }
            do {
                try run(script: chatScript, arguments: [body, guid])
            } catch SendError.scriptFailed(let status, let output) {
                if output.contains("CHAT_NOT_FOUND") { throw SendError.chatNotFound(guid) }
                throw SendError.scriptFailed(status: status, output: output)
            }
        }
    }

    private static func run(script: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // "-" reads the script from stdin; everything after becomes argv.
        process.arguments = ["-"] + arguments

        let stdin = Pipe()
        let output = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = output

        try process.run()
        stdin.fileHandleForWriting.write(Data(script.utf8))
        stdin.fileHandleForWriting.closeFile()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SendError.scriptFailed(
                status: process.terminationStatus,
                output: String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    static func isMessagesRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "Messages"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// macOS parks Messages after ~15–20 minutes idle, turning the first send after a
    /// quiet stretch into a 2–3 second stall. A cheap read keeps it warm.
    @discardableResult
    static func wakeMessages() -> Bool {
        guard isMessagesRunning() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Messages\" to return (count of chats)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
