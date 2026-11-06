import Foundation

/// Read-only access to the Messages database.
///
/// Hard rule: this class never writes to chat.db. Our own state lives in a separate
/// database (see TriageStore). Corrupting Messages would be unrecoverable.
final class ChatDB {

    static let defaultPath = NSString(string: "~/Library/Messages/chat.db").expandingTildeInPath

    private let db: SQLiteDB
    private(set) var contacts: ContactBook

    init(path: String = ChatDB.defaultPath, contacts: ContactBook) throws {
        self.db = try SQLiteDB(path: path, readOnly: true)
        self.contacts = contacts
    }

    /// Excludes everything that isn't a real, standing message from a human:
    ///
    ///  - `associated_message_type != 0` — tapbacks. These are ~8% of this database
    ///    (21k of 269k rows). Counting a 👍 as a reply would wrongly clear threads out
    ///    of the To Reply bucket, which is the exact failure this app exists to prevent.
    ///  - `item_type != 0` — group renames, joins, leaves and other system events.
    ///  - `date_retracted != 0` — messages that were unsent.
    private static let realMessagePredicate = """
        IFNULL(m.associated_message_type, 0) = 0
        AND IFNULL(m.item_type, 0) = 0
        AND IFNULL(m.date_retracted, 0) = 0
        """

    // MARK: - Threads

    /// Newest real message per chat, within the lookback window.
    ///
    /// Messages keeps *separate chat rows per service* for the same person — one for
    /// iMessage, one for SMS, sometimes one for RCS — all with the same
    /// chat_identifier. Left alone, a friend appears two or three times in the inbox.
    /// We collapse them here and remember every underlying chat row so message history
    /// stays continuous across a service switch.
    func threadGroups(sinceDays: Int = 180, limit: Int = 500) throws -> [ThreadGroup] {
        let cutoff = AppleDate.fromUnix(Date().timeIntervalSince1970 - Double(sinceDays) * 86_400)

        let sql = """
            WITH ranked AS (
                SELECT
                    cmj.chat_id                AS chat_id,
                    m.ROWID                    AS msg_id,
                    m.date                     AS msg_date,
                    m.is_from_me               AS is_from_me,
                    m.text                     AS text,
                    m.attributedBody           AS attributed_body,
                    m.cache_has_attachments    AS has_attachments,
                    m.balloon_bundle_id        AS balloon_bundle_id,
                    m.handle_id                AS handle_id,
                    ROW_NUMBER() OVER (
                        PARTITION BY cmj.chat_id
                        ORDER BY m.date DESC, m.ROWID DESC
                    ) AS rn
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE \(Self.realMessagePredicate)
                  AND m.date > ?
            )
            SELECT
                c.ROWID, c.guid, c.chat_identifier, IFNULL(c.display_name, ''),
                c.style, IFNULL(c.service_name, ''), IFNULL(c.group_id, ''),
                r.msg_id, r.msg_date, r.is_from_me,
                r.text, r.attributed_body, r.has_attachments, r.balloon_bundle_id,
                IFNULL(h.id, '')
            FROM ranked r
            JOIN chat c ON c.ROWID = r.chat_id
            LEFT JOIN handle h ON h.ROWID = r.handle_id
            WHERE r.rn = 1
            ORDER BY r.msg_date DESC
            """

        let stmt = try db.prepare(sql, [.int(cutoff)])

        var groups: [String: ThreadGroup] = [:]
        var order: [String] = []

        while stmt.step() {
            let chatRowID = stmt.int(0)
            let guid = stmt.string(1) ?? ""
            let chatIdentifier = stmt.string(2) ?? ""
            let displayName = stmt.string(3) ?? ""
            let style = stmt.int(4)
            let service = stmt.string(5) ?? ""
            let groupID = stmt.string(6) ?? ""

            let msgID = stmt.int(7)
            let msgDate = AppleDate.toUnix(stmt.int(8))
            let isFromMe = stmt.bool(9)

            var text = BodyDecoder.text(plain: stmt.string(10), attributedBody: stmt.blob(11))
            if text.isEmpty {
                text = BodyDecoder.placeholder(
                    hasAttachments: stmt.int(12) != 0,
                    balloonBundleID: stmt.string(13)
                )
            }
            let senderHandle = stmt.string(14) ?? ""

            let isGroup = style == 43
            let key = Self.canonicalKey(
                isGroup: isGroup, chatIdentifier: chatIdentifier, groupID: groupID, guid: guid
            )

            let preview = MessagePreview(
                rowID: msgID,
                date: msgDate,
                isFromMe: isFromMe,
                text: text,
                sender: isFromMe ? nil : (senderHandle.isEmpty ? nil : contacts.name(for: senderHandle))
            )

            if var existing = groups[key] {
                existing.chatRowIDs.append(chatRowID)
                // Rows arrive newest-first, so the first one we saw is the live service.
                if msgDate > existing.lastMessage.date {
                    existing.lastMessage = preview
                    existing.sendGUID = guid
                    existing.service = service
                    existing.lastRowID = msgID
                    existing.needsReply = !isFromMe
                }
                groups[key] = existing
            } else {
                groups[key] = ThreadGroup(
                    key: key,
                    chatRowIDs: [chatRowID],
                    sendGUID: guid,
                    chatIdentifier: chatIdentifier,
                    title: displayName,
                    isGroup: isGroup,
                    service: service,
                    handles: [],
                    lastMessage: preview,
                    lastRowID: msgID,
                    needsReply: !isFromMe
                )
                order.append(key)
            }
        }

        try attachParticipants(&groups)
        for (key, group) in groups {
            groups[key]?.category = classify(group)
        }
        try preferIMessage(&groups)

        return order.compactMap { groups[$0] }
            .sorted { $0.lastMessage.date > $1.lastMessage.date }
            .prefix(limit)
            .map { $0 }
    }

    /// First real message, total count and how many you sent, per chat row. Used to spot
    /// people you've only recently started talking to.
    func contactStats(chatRowIDs: [Int64]) throws -> [Int64: (first: Double, count: Int, fromMe: Int)] {
        guard !chatRowIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: chatRowIDs.count).joined(separator: ",")
        let stmt = try db.prepare(
            """
            SELECT cmj.chat_id, MIN(m.date), COUNT(*), SUM(m.is_from_me)
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE \(Self.realMessagePredicate)
              AND cmj.chat_id IN (\(placeholders))
            GROUP BY cmj.chat_id
            """,
            chatRowIDs.map { .int($0) }
        )
        var out: [Int64: (first: Double, count: Int, fromMe: Int)] = [:]
        while stmt.step() {
            out[stmt.int(0)] = (AppleDate.toUnix(stmt.int(1)), Int(stmt.int(2)), Int(stmt.int(3)))
        }
        return out
    }

    /// Messages can file a person's conversation under an SMS chat row even when you've been
    /// texting over iMessage (it happened with a friend whose chat row said SMS while every
    /// recent message was iMessage). Sending through that label goes out as SMS, which this
    /// Mac can't send without the iPhone, and fails. So a thread that has seen iMessage in
    /// the last 90 days is treated as iMessage, for sending and for its label.
    private func preferIMessage(_ groups: inout [String: ThreadGroup]) throws {
        let candidates = groups.values.filter { !$0.isGroup && $0.service != "iMessage" }
        let rowIDs = candidates.flatMap(\.chatRowIDs)
        guard !rowIDs.isEmpty else { return }
        let cutoff = AppleDate.fromUnix(Date().timeIntervalSince1970 - 90 * 86_400)
        let placeholders = Array(repeating: "?", count: rowIDs.count).joined(separator: ",")
        let stmt = try db.prepare(
            """
            SELECT DISTINCT j.chat_id FROM message m
            JOIN chat_message_join j ON j.message_id = m.ROWID
            WHERE j.chat_id IN (\(placeholders)) AND m.service = 'iMessage' AND m.date > ?
            """,
            rowIDs.map { .int($0) } + [.int(cutoff)]
        )
        var withIMessage: Set<Int64> = []
        while stmt.step() { withIMessage.insert(stmt.int(0)) }
        for group in candidates where group.chatRowIDs.contains(where: withIMessage.contains) {
            groups[group.key]?.service = "iMessage"
        }
    }

    /// Split real people from the machines. Without this the To Reply bucket fills with
    /// verification codes and package notifications and stops being worth opening.
    private func classify(_ group: ThreadGroup) -> SenderCategory {
        // A group chat is always people, even if we can't name all of them.
        if group.isGroup { return .known }

        let candidates = group.handles.isEmpty ? [group.chatIdentifier] : group.handles
        if candidates.contains(where: { contacts.isKnown($0) }) { return .known }

        // Short codes (≤6 digits) are reserved for automated senders — no human has one.
        let identifier = group.chatIdentifier
        if !ContactBook.isEmailHandle(identifier) {
            let digits = identifier.filter(\.isNumber)
            if !digits.isEmpty && digits.count <= 6 { return .automated }
        }
        return .unknown
    }

    /// DMs merge on the person; groups stay distinct.
    private static func canonicalKey(
        isGroup: Bool, chatIdentifier: String, groupID: String, guid: String
    ) -> String {
        if isGroup {
            return "grp:" + (groupID.isEmpty ? guid : groupID)
        }
        let normalized = ContactBook.normalizeHandle(chatIdentifier) ?? chatIdentifier.lowercased()
        return "dm:" + normalized
    }

    /// Fill in participant handles and derive a title for unnamed group chats.
    private func attachParticipants(_ groups: inout [String: ThreadGroup]) throws {
        var rowIDToKey: [Int64: String] = [:]
        for (key, group) in groups {
            for rowID in group.chatRowIDs { rowIDToKey[rowID] = key }
        }
        guard !rowIDToKey.isEmpty else { return }

        let placeholders = Array(repeating: "?", count: rowIDToKey.count).joined(separator: ",")
        let sql = """
            SELECT chj.chat_id, IFNULL(h.id, '')
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            WHERE chj.chat_id IN (\(placeholders))
            """
        let stmt = try db.prepare(sql, rowIDToKey.keys.map { .int($0) })

        var handlesByKey: [String: Set<String>] = [:]
        while stmt.step() {
            guard let key = rowIDToKey[stmt.int(0)] else { continue }
            let handle = stmt.string(1) ?? ""
            guard !handle.isEmpty else { continue }
            handlesByKey[key, default: []].insert(handle)
        }

        for (key, handles) in handlesByKey {
            guard var group = groups[key] else { continue }
            group.handles = handles.sorted()
            if group.title.isEmpty {
                let names = group.handles.map { contacts.name(for: $0) }.sorted()
                group.title = names.isEmpty ? "Unknown" : names.joined(separator: ", ")
            }
            groups[key] = group
        }

        // A chat with no handle rows at all still needs something to show.
        for (key, group) in groups where group.title.isEmpty {
            var g = group
            g.title = "Unknown"
            groups[key] = g
        }
    }

    // MARK: - Messages

    func messages(chatRowIDs: [Int64], limit: Int = 60, before: Int64? = nil) throws -> [Message] {
        guard !chatRowIDs.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: chatRowIDs.count).joined(separator: ",")
        var params: [SQLValue] = chatRowIDs.map { .int($0) }
        var beforeClause = ""
        if let before {
            beforeClause = "AND m.ROWID < ?"
            params.append(.int(before))
        }
        params.append(.int(Int64(limit)))

        let sql = """
            SELECT m.ROWID, m.date, m.is_from_me, m.text, m.attributedBody,
                   m.cache_has_attachments, m.balloon_bundle_id,
                   IFNULL(m.date_edited, 0), IFNULL(m.service, ''), IFNULL(h.id, ''),
                   IFNULL(m.guid, ''), IFNULL(m.date_delivered, 0)
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id IN (\(placeholders))
              AND \(Self.realMessagePredicate)
              \(beforeClause)
            ORDER BY m.date DESC, m.ROWID DESC
            LIMIT ?
            """

        let stmt = try db.prepare(sql, params)
        var out: [Message] = []
        var balloonByRow: [Int64: String] = [:]
        while stmt.step() {
            // No placeholder yet — a message with an image would otherwise show the
            // picture *and* the words "📎 Attachment" underneath it. Filled in below,
            // only for messages that end up with nothing renderable at all.
            let text = BodyDecoder.text(plain: stmt.string(3), attributedBody: stmt.blob(4))
            let isFromMe = stmt.bool(2)
            let handle = stmt.string(9) ?? ""
            balloonByRow[stmt.int(0)] = stmt.string(6) ?? ""
            out.append(Message(
                rowID: stmt.int(0),
                guid: stmt.string(10) ?? "",
                date: AppleDate.toUnix(stmt.int(1)),
                isFromMe: isFromMe,
                text: text,
                sender: isFromMe ? "Me" : (handle.isEmpty ? "Unknown" : contacts.name(for: handle)),
                hasAttachments: stmt.int(5) != 0,
                isEdited: stmt.int(7) != 0,
                service: stmt.string(8) ?? "",
                isDelivered: stmt.int(11) != 0
            ))
        }

        let byTarget = try reactions(chatRowIDs: chatRowIDs)
        for index in out.indices {
            if let found = byTarget[out[index].guid] { out[index].reactions = found }
        }

        let files = try attachments(messageRowIDs: out.map(\.rowID))
        for index in out.indices {
            if let found = files[out[index].rowID] { out[index].attachments = found }

            // Only now, knowing whether anything renderable came back, fall back to a
            // textual stand-in — an Apple Cash payment or a Digital Touch has neither
            // text nor a viewable file, and an empty bubble would be baffling.
            if out[index].text.isEmpty && out[index].attachments.isEmpty {
                out[index].text = BodyDecoder.placeholder(
                    hasAttachments: out[index].hasAttachments,
                    balloonBundleID: balloonByRow[out[index].rowID]
                )
            }
        }

        // Query is newest-first for the LIMIT; the UI wants oldest-first.
        return out.reversed()
    }

    /// Tapbacks, keyed by the guid of the message they're attached to.
    ///
    /// These are the same rows the main message query deliberately filters out. A
    /// reaction points at its target through `associated_message_guid`, which carries a
    /// prefix like `p:0/` before the actual guid.
    ///
    /// A person can add and remove the same tapback repeatedly, so we replay the events
    /// in order and keep only the final state per (sender, reaction kind).
    func reactions(chatRowIDs: [Int64]) throws -> [String: [Reaction]] {
        guard !chatRowIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: chatRowIDs.count).joined(separator: ",")

        let sql = """
            SELECT IFNULL(m.associated_message_guid, ''),
                   IFNULL(m.associated_message_type, 0),
                   IFNULL(m.associated_message_emoji, ''),
                   m.is_from_me,
                   IFNULL(h.id, '')
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id IN (\(placeholders))
              AND IFNULL(m.associated_message_type, 0) >= 2000
              AND IFNULL(m.date_retracted, 0) = 0
            ORDER BY m.date ASC, m.ROWID ASC
            """

        let stmt = try db.prepare(sql, chatRowIDs.map { .int($0) })

        // (target guid, sender, kind) -> the reaction, or nil once removed.
        struct Key: Hashable {
            var target: String
            var sender: String
            var kind: Int64
        }
        var latest: [Key: Reaction?] = [:]
        var order: [Key] = []

        while stmt.step() {
            let rawTarget = stmt.string(0) ?? ""
            guard !rawTarget.isEmpty else { continue }
            // Strip the `p:0/` style prefix to get the bare target guid.
            let target = rawTarget.contains("/")
                ? String(rawTarget[rawTarget.index(after: rawTarget.lastIndex(of: "/")!)...])
                : rawTarget

            let type = stmt.int(1)
            let isFromMe = stmt.bool(3)
            let handle = stmt.string(4) ?? ""
            let key = Key(target: target, sender: isFromMe ? "" : handle, kind: type % 1000)

            if TapbackKind.isRemove(type) {
                latest[key] = .some(nil)
            } else if TapbackKind.isAdd(type),
                      let emoji = TapbackKind.emoji(forType: type, custom: stmt.string(2)) {
                if latest[key] == nil { order.append(key) }
                latest[key] = Reaction(
                    emoji: emoji,
                    fromMe: isFromMe,
                    sender: isFromMe ? "You" : (handle.isEmpty ? "Unknown" : contacts.name(for: handle))
                )
            }
        }

        var out: [String: [Reaction]] = [:]
        for key in order {
            guard let stored = latest[key], let reaction = stored else { continue }
            out[key.target, default: []].append(reaction)
        }
        return out
    }

    /// Find conversations by person, across all history.
    ///
    /// Deliberately ignores the lookback window the inbox uses: 965 of these chats are
    /// older than 180 days, and "I can't find Naomi" is exactly the case search exists
    /// for. There are only ~1,350 chats total, so matching in Swift — where the same
    /// phone-number normalisation and contact lookup apply as everywhere else — is both
    /// simpler and more correct than trying to express it in SQL.
    func searchThreads(query: String, limit: Int = 40) throws -> [ThreadGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= 2 else { return [] }

        var participants: [Int64: [String]] = [:]
        let handleStmt = try db.prepare("""
            SELECT chj.chat_id, IFNULL(h.id, '')
            FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id
            """)
        while handleStmt.step() {
            let handle = handleStmt.string(1) ?? ""
            if !handle.isEmpty { participants[handleStmt.int(0), default: []].append(handle) }
        }

        let chatStmt = try db.prepare("""
            SELECT ROWID, guid, chat_identifier, IFNULL(display_name, ''), style,
                   IFNULL(service_name, ''), IFNULL(group_id, '')
            FROM chat
            """)

        struct Candidate {
            var rowID: Int64, guid: String, identifier: String, displayName: String
            var isGroup: Bool, service: String, groupID: String, handles: [String], title: String
        }
        var candidates: [Candidate] = []

        while chatStmt.step() {
            let rowID = chatStmt.int(0)
            let identifier = chatStmt.string(2) ?? ""
            let displayName = chatStmt.string(3) ?? ""
            let isGroup = chatStmt.int(4) == 43
            let handles = participants[rowID] ?? []

            var title = displayName
            if title.isEmpty {
                let names = handles.map { contacts.name(for: $0) }.sorted()
                title = names.isEmpty ? contacts.name(for: identifier) : names.joined(separator: ", ")
            }

            let haystack = ([title, identifier] + handles.map { contacts.name(for: $0) } + handles)
                .joined(separator: " ")
                .lowercased()
            guard haystack.contains(needle) else { continue }

            candidates.append(Candidate(
                rowID: rowID, guid: chatStmt.string(1) ?? "", identifier: identifier,
                displayName: displayName, isGroup: isGroup,
                service: chatStmt.string(5) ?? "", groupID: chatStmt.string(6) ?? "",
                handles: handles, title: title
            ))
        }
        guard !candidates.isEmpty else { return [] }

        // Newest real message for each match.
        let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ",")
        let lastStmt = try db.prepare(
            """
            WITH ranked AS (
                SELECT cmj.chat_id            AS chat_id,
                       m.ROWID                AS msg_id,
                       m.date                 AS msg_date,
                       m.is_from_me           AS is_from_me,
                       m.text                 AS text,
                       m.attributedBody       AS attributed_body,
                       m.cache_has_attachments AS has_attachments,
                       m.balloon_bundle_id    AS balloon_bundle_id,
                       m.handle_id            AS handle_id,
                       ROW_NUMBER() OVER (
                           PARTITION BY cmj.chat_id ORDER BY m.date DESC, m.ROWID DESC
                       ) AS rn
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE cmj.chat_id IN (\(placeholders)) AND \(Self.realMessagePredicate)
            )
            SELECT r.chat_id, r.msg_id, r.msg_date, r.is_from_me, r.text,
                   r.attributed_body, r.has_attachments, r.balloon_bundle_id,
                   IFNULL(h.id, '')
            FROM ranked r
            LEFT JOIN handle h ON h.ROWID = r.handle_id
            WHERE r.rn = 1
            """,
            candidates.map { .int($0.rowID) }
        )

        var lastByChat: [Int64: (MessagePreview, Int64)] = [:]
        while lastStmt.step() {
            var text = BodyDecoder.text(plain: lastStmt.string(4), attributedBody: lastStmt.blob(5))
            if text.isEmpty {
                text = BodyDecoder.placeholder(
                    hasAttachments: lastStmt.int(6) != 0, balloonBundleID: lastStmt.string(7)
                )
            }
            let isFromMe = lastStmt.bool(3)
            let handle = lastStmt.string(8) ?? ""
            lastByChat[lastStmt.int(0)] = (
                MessagePreview(
                    rowID: lastStmt.int(1),
                    date: AppleDate.toUnix(lastStmt.int(2)),
                    isFromMe: isFromMe,
                    text: text,
                    sender: isFromMe ? nil : (handle.isEmpty ? nil : contacts.name(for: handle))
                ),
                lastStmt.int(1)
            )
        }

        var groups: [String: ThreadGroup] = [:]
        for candidate in candidates {
            guard let (preview, lastRowID) = lastByChat[candidate.rowID] else { continue }
            let key = Self.canonicalKey(
                isGroup: candidate.isGroup, chatIdentifier: candidate.identifier,
                groupID: candidate.groupID, guid: candidate.guid
            )
            if var existing = groups[key] {
                existing.chatRowIDs.append(candidate.rowID)
                if preview.date > existing.lastMessage.date {
                    existing.lastMessage = preview
                    existing.sendGUID = candidate.guid
                    existing.lastRowID = lastRowID
                    existing.needsReply = !preview.isFromMe
                }
                groups[key] = existing
            } else {
                var group = ThreadGroup(
                    key: key, chatRowIDs: [candidate.rowID], sendGUID: candidate.guid,
                    chatIdentifier: candidate.identifier, title: candidate.title,
                    isGroup: candidate.isGroup, service: candidate.service,
                    handles: candidate.handles.sorted(), lastMessage: preview,
                    lastRowID: lastRowID, needsReply: !preview.isFromMe
                )
                group.category = classify(group)
                groups[key] = group
            }
        }
        try preferIMessage(&groups)

        return groups.values
            .sorted { $0.lastMessage.date > $1.lastMessage.date }
            .prefix(limit)
            .map { $0 }
    }

    /// Attachments keyed by the message they belong to.
    func attachments(messageRowIDs: [Int64]) throws -> [Int64: [Attachment]] {
        guard !messageRowIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: messageRowIDs.count).joined(separator: ",")

        let sql = """
            SELECT maj.message_id, a.ROWID, IFNULL(a.transfer_name, ''), IFNULL(a.uti, ''),
                   IFNULL(a.mime_type, ''), IFNULL(a.is_sticker, 0), IFNULL(a.total_bytes, 0)
            FROM message_attachment_join maj
            JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (\(placeholders))
              AND IFNULL(a.hide_attachment, 0) = 0
            ORDER BY a.ROWID ASC
            """

        let stmt = try db.prepare(sql, messageRowIDs.map { .int($0) })
        var out: [Int64: [Attachment]] = [:]
        while stmt.step() {
            let uti = stmt.string(3) ?? ""
            let mime = stmt.string(4) ?? ""
            let attachment = Attachment(
                id: stmt.int(1),
                name: stmt.string(2) ?? "",
                uti: uti,
                mimeType: mime,
                isSticker: stmt.int(5) != 0,
                bytes: stmt.int(6),
                isImage: Attachment.looksLikeImage(uti: uti, mimeType: mime)
            )
            guard !attachment.isPayload else { continue }
            out[stmt.int(0), default: []].append(attachment)
        }
        return out
    }

    /// Resolve an attachment ROWID to a file on disk.
    ///
    /// The path always comes from the database, never from the request, so a caller
    /// can't ask for an arbitrary file. The prefix check is a second line of defence in
    /// case a crafted row ever ends up in chat.db.
    func attachmentFile(id: Int64) throws -> (path: String, mimeType: String, name: String)? {
        let stmt = try db.prepare(
            """
            SELECT IFNULL(filename, ''), IFNULL(mime_type, ''), IFNULL(transfer_name, ''),
                   IFNULL(uti, '')
            FROM attachment WHERE ROWID = ?
            """,
            [.int(id)]
        )
        guard stmt.step() else { return nil }

        let raw = stmt.string(0) ?? ""
        guard !raw.isEmpty else { return nil }
        let path = NSString(string: raw).expandingTildeInPath

        let allowedRoots = [
            NSString(string: "~/Library/Messages/").expandingTildeInPath,
            "/var/folders/",
            "/private/var/folders/",
        ]
        guard allowedRoots.contains(where: { path.hasPrefix($0) }),
              !path.contains(".."),
              FileManager.default.fileExists(atPath: path)
        else { return nil }

        var mime = stmt.string(1) ?? ""
        if mime.isEmpty {
            // Stickers frequently have no mime_type recorded; infer from the extension.
            switch (path as NSString).pathExtension.lowercased() {
            case "heic", "heif": mime = "image/heic"
            case "png": mime = "image/png"
            case "jpg", "jpeg": mime = "image/jpeg"
            case "gif": mime = "image/gif"
            case "mov": mime = "video/quicktime"
            case "mp4": mime = "video/mp4"
            default: mime = "application/octet-stream"
            }
        }
        return (path, mime, stmt.string(2) ?? "attachment")
    }

    /// Cheap change probe for the poll loop.
    func maxMessageRowID() throws -> Int64 {
        let stmt = try db.prepare("SELECT IFNULL(MAX(ROWID), 0) FROM message")
        return stmt.step() ? stmt.int(0) : 0
    }
}
