import SwiftUI

struct StripView: View {
    @ObservedObject var model: StripModel
    var onClose: () -> Void
    var onBackToClaude: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.sessions.count > 1 {
                SessionList(model: model, onBack: onBackToClaude)
            }
            Divider()
            tabs
            if let error = model.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
            switch model.tab {
            case .all:
                if let focus = model.focus {
                    ThreadPane(model: model, focus: focus)
                } else {
                    ConversationList(model: model)
                }
            case .reply, .later:
                if let focus = model.focus {
                    ThreadPane(model: model, focus: focus)
                } else {
                    empty(emptyText)
                }
            case .keepInTouch:
                if let focus = model.openNudge {
                    ThreadPane(model: model, focus: focus)
                } else {
                    KeepInTouchList(model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        )
    }

    private var emptyText: String {
        switch model.tab {
        case .reply: return "Nothing waiting on you."
        case .later: return "Nothing for later. Later on a thread parks it here for once Reply is clear."
        case .all: return "No conversations."
        case .keepInTouch: return ""
        }
    }

    private func empty(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            Spacer()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ClaudeStatus(claude: model.claude, midReply: model.hasDraft, onBack: onBackToClaude)
            Spacer()
            Button { model.pinned.toggle() } label: {
                Image(systemName: model.pinned ? "pin.fill" : "pin")
            }
            .help(model.pinned ? "Unpin: hide when Claude is done" : "Pin: stay open after Claude is done")
            Button(action: onClose) { Image(systemName: "xmark") }
                .help("Hide until your next prompt")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            TabButton(title: "Reply", count: model.count(.reply), selected: model.tab == .reply) {
                model.select(.reply)
            }
            TabButton(title: "Later", count: model.count(.later), selected: model.tab == .later) {
                model.select(.later)
            }
            TabButton(title: "All", count: 0, selected: model.tab == .all) {
                model.select(.all)
            }
            TabButton(title: "Favorites", count: model.dueCount,
                      selected: model.tab == .keepInTouch) {
                model.select(.keepInTouch)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }
}

private struct TabButton: View {
    var title: String
    var count: Int
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.secondary.opacity(0.25)))
                }
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ClaudeStatus: View {
    var claude: StripModel.Claude
    var midReply: Bool
    var onBack: () -> Void

    var body: some View {
        switch claude {
        case .working(let since, let projects):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text("Claude is working · \(elapsed(since, context.date))")
                        .font(.callout.weight(.medium))
                }
                if let project = projects.first {
                    Text(project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        case .needsYou(let projects):
            Button(action: onBack) {
                Label("Claude needs you" + (projects.first.map { " · \($0)" } ?? "") + "  →",
                      systemImage: "exclamationmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        case .done:
            Button(action: onBack) {
                Label(midReply ? "Claude's done · back →" : "Back to Claude  →",
                      systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        case .idle:
            Text("Photosynthesizing").font(.callout.weight(.medium))
        }
    }

    private func elapsed(_ since: Date, _ now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - A conversation

private struct ThreadPane: View {
    @ObservedObject var model: StripModel
    var focus: StripModel.Focus

    private var replied: Bool { model.sent.contains(focus.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !model.tab.isQueue || model.tab == .all {
                    Button { model.tab == .all ? model.closeConversation() : model.closeNudge() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless)
                }
                Avatar(model: model, key: focus.key, title: focus.title, size: 30)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                Text(focus.title).font(.title3.weight(.semibold)).lineLimit(1)
                NetworkBadge(key: focus.key, service: focus.service)
                CadenceMenu(model: model, key: focus.key, title: focus.title)
                OpenInMessages(key: focus.key)
                Spacer()
                if model.tab.isQueue && model.tab != .all {
                    Text("\(model.position) of \(model.threads.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.messages) { message in
                            Bubble(
                                message: message,
                                showSender: focus.isGroup,
                                attachmentURL: { model.client?.attachmentURL(id: $0) },
                                onReact: focus.key.hasPrefix("bp:")
                                    ? { emoji in model.react(to: message, emoji: emoji) } : nil
                            )
                            .id(message.rowID)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .onChange(of: model.messages) { _, messages in
                    if let last = messages.last { proxy.scrollTo(last.rowID, anchor: .bottom) }
                }
            }

            composer
            if model.tab.isQueue && model.tab != .all { UpNext(model: model) }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            TextField(replied ? "Another text…" : "Reply to \(focus.title)…",
                      text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.6)))
                .onSubmit { model.send() }

            HStack(spacing: 8) {
                Button("Send", action: model.send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasDraft || model.busy)
                if model.tab.isQueue && model.tab != .all {
                    if replied {
                        Button("Next →", action: model.skip)
                            .keyboardShortcut(.rightArrow, modifiers: .command)
                    } else {
                        Button("Skip", action: model.skip)
                            .disabled(model.upNext.isEmpty)
                    }
                }
                Spacer()
                // Move this thread between Reply and Later.
                if model.tab != .reply && !replied {
                    Button("Reply") { model.move(to: .reply) }
                        .help("Back to the Reply queue")
                }
                if model.tab != .later {
                    Button("Later") { model.move(to: .later) }
                        .help(replied ? "Come back to this after they reply, or when you're ready"
                                      : "Park it for once Reply is clear")
                }
                if !replied {
                    Button("Done", action: model.markDone)
                        .help("Handled, nothing more to do")
                }
            }
            .controlSize(.small)
            .disabled(model.busy)
        }
        .padding(14)
    }
}

/// Clock button on a conversation: how often you want to be in touch with this person.
private struct CadenceMenu: View {
    @ObservedObject var model: StripModel
    var key: String
    var title: String

    var body: some View {
        let current = model.cadence(for: key)
        Menu {
            ForEach(Cadence.choices, id: \.days) { choice in
                Button {
                    model.setCadence(key: key, title: title, days: choice.days)
                } label: {
                    if current == choice.days {
                        Label(choice.label, systemImage: "checkmark")
                    } else {
                        Text(choice.label)
                    }
                }
            }
            if let nudge = model.nudge(for: key) {
                Divider()
                Button {
                    model.setCallsOnly(nudge, !(nudge.callsOnly ?? false))
                } label: {
                    if nudge.callsOnly == true {
                        Label("Only calls count", systemImage: "checkmark")
                    } else {
                        Text("Only calls count")
                    }
                }
                Button("Stop reminding me") { model.setCadence(key: key, title: title, days: 0) }
            }
        } label: {
            Image(systemName: current == nil ? "clock" : "clock.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(current.map { "Keep in touch \(Cadence.label($0))" } ?? "Keep in touch…")
    }
}

private struct Bubble: View {
    var message: Message
    var showSender: Bool
    var attachmentURL: (Int64) -> URL?
    /// Set for Beeper threads, where reactions can be sent. Right-click a bubble to react.
    var onReact: ((String) -> Void)?

    static let reactions = ["❤️", "👍", "😂", "😮", "😢", "🙏"]

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 40) }
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                if showSender && !message.isFromMe && !message.sender.isEmpty {
                    Text(message.sender).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(message.attachments) { attachment in
                    AttachmentView(attachment: attachment, url: attachmentURL(attachment.id))
                }
                if let displayText {
                Text(displayText)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(message.isFromMe ? .white : .primary)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(message.isFromMe
                                  ? AnyShapeStyle(message.isGreen ? Color.green : Color.blue)
                                  : AnyShapeStyle(.quaternary))
                    )
                    .contextMenu {
                        if let onReact {
                            ForEach(Self.reactions, id: \.self) { emoji in
                                Button(emoji) { onReact(emoji) }
                            }
                        }
                    }
                }
                if !message.reactions.isEmpty {
                    Text(message.reactions.map(\.emoji).joined(separator: " "))
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                        .help(message.reactions.map { "\($0.emoji) \($0.fromMe ? "You" : $0.sender)" }
                            .joined(separator: "\n"))
                }
                Text(Format.relative(message.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !message.isFromMe { Spacer(minLength: 40) }
        }
    }

    /// The text bubble, or nil when the message is only attachments. Beeper fills empty
    /// text with a stand-in like "📷 Photo", which the attachment itself now replaces.
    private var displayText: String? {
        let standIns: Set<String> = ["📷 Photo", "🎥 Video", "🎤 Voice message", "Sticker", "📎 File", "📎 Attachment"]
        if !message.attachments.isEmpty && (message.text.isEmpty || standIns.contains(message.text)) {
            return nil
        }
        if !message.text.isEmpty { return message.text }
        return message.hasAttachments ? "📎 Attachment" : "…"
    }
}

/// A photo inline; anything else as a chip that opens the file.
private struct AttachmentView: View {
    var attachment: Attachment
    var url: URL?

    var body: some View {
        if attachment.isImage {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                        .frame(maxWidth: attachment.isSticker ? 110 : 240, maxHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onTapGesture { if let url { NSWorkspace.shared.open(url) } }
                case .failure:
                    chip("photo", "Photo isn't on the Mac mini yet")
                default:
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                        .frame(width: 160, height: 120)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
        } else {
            Button { if let url { NSWorkspace.shared.open(url) } } label: {
                chip(attachment.isVideo ? "video" : "doc",
                     attachment.name.isEmpty ? (attachment.isVideo ? "Video" : "File") : attachment.name)
            }
            .buttonStyle(.plain)
        }
    }

    private func chip(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title).lineLimit(1)
            if attachment.bytes > 0 && !attachment.isImage {
                Text(attachment.sizeLabel).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
    }
}

private struct UpNext: View {
    @ObservedObject var model: StripModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("QUEUE · \(model.threads.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Search", text: $model.queueFilter)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .frame(width: 130)
                if !model.queueFilter.isEmpty {
                    Button { model.queueFilter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.filteredQueue) { thread in
                        row(thread) { model.queueFilter = ""; model.open(thread.key) }
                    }
                    if !model.otherResults.isEmpty {
                        Text("OTHER CONVERSATIONS")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                        ForEach(model.otherResults) { thread in
                            row(thread) { model.openFromSearch(thread) }
                        }
                    }
                }
            }
            .defaultScrollAnchor(.top)
            .frame(maxHeight: 190)
        }
        .padding(14)
        .background(.black.opacity(0.06))
    }

    private func row(_ thread: ThreadSummary, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack {
                Avatar(model: model, key: thread.key, title: thread.title, size: 22)
                Text(thread.title).lineLimit(1)
                NetworkBadge(key: thread.key, service: thread.service)
                if model.sent.contains(thread.key) {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
                Spacer()
                Text(Format.relative(thread.lastMessage.date))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }
}

// MARK: - Keep in touch

private struct KeepInTouchList: View {
    @ObservedObject var model: StripModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AddPerson(model: model)

                let roster = model.roster
                if !roster.isEmpty {
                    section("FAVORITES · \(roster.count)") {
                        ForEach(roster) { PersonRow(model: model, nudge: $0) }
                    }
                } else if model.nudges != nil {
                    Text("No one here yet. Search above, or use the clock on any conversation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let suggestions = model.nudges?.suggestions, !suggestions.isEmpty {
                    section("NEW PEOPLE") {
                        ForEach(suggestions) { SuggestionRow(model: model, suggestion: $0) }
                    }
                }
            }
            .padding(14)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Search any conversation, iMessage or Beeper, and pick how often to stay in touch.
private struct AddPerson: View {
    @ObservedObject var model: StripModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Add someone…", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                if !model.searchQuery.isEmpty {
                    Button { model.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.6)))

            ForEach(model.searchResults) { thread in
                HStack {
                    Avatar(model: model, key: thread.key, title: thread.title, size: 22)
                    Text(thread.title).lineLimit(1)
                    NetworkBadge(key: thread.key, service: thread.service)
                    Spacer()
                    if let days = model.cadence(for: thread.key) {
                        Text(Cadence.label(days)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Menu("Add") {
                            ForEach(Cadence.choices, id: \.days) { choice in
                                Button(choice.label) {
                                    model.setCadence(key: thread.key, title: thread.title, days: choice.days)
                                    model.searchQuery = ""
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                .font(.callout)
                .padding(.horizontal, 8)
            }
        }
    }
}

/// One person on the roster: when you last texted and called, and whether they're due.
private struct PersonRow: View {
    @ObservedObject var model: StripModel
    var nudge: NudgeResponse.Nudge

    private var now: Double { Date().timeIntervalSince1970 }
    private var isDue: Bool { nudge.dueAt <= now }
    private var callsOnly: Bool { nudge.callsOnly == true }

    /// One calm card: who, when you last talked, and at most one gentle note. Everything
    /// else lives in the ··· menu.
    var body: some View {
        HStack(spacing: 10) {
            Avatar(model: model, key: nudge.key, title: nudge.title, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(nudge.title).font(.body.weight(.medium)).lineLimit(1)
                    NetworkBadge(key: nudge.key, service: nudge.service)
                }
                Text(lastTalked).font(.caption).foregroundStyle(.secondary)
                if let birthday = birthdayNote {
                    Text(birthday).font(.caption).foregroundStyle(.secondary)
                } else if isDue {
                    Label(callsOnly ? "Time to call" : "Time to say hi", systemImage: "circle.fill")
                        .labelStyle(SoftDot())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if isDue {
                if callsOnly, let url = MessagesApp.callURL(forKey: nudge.key) {
                    Button("Call") { NSWorkspace.shared.open(url) }
                } else if !callsOnly {
                    Button("Say hi") { model.openNudge(nudge) }
                }
            }
            moreMenu
        }
        .controlSize(.small)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
        .contentShape(Rectangle())
        .onTapGesture { model.openNudge(nudge) }
    }

    private var moreMenu: some View {
        Menu {
            Button("Caught up") { model.didIt(nudge) }
            Button("Remind me in 3 days") { model.remindLater(nudge) }
            if let url = MessagesApp.url(forKey: nudge.key) {
                Button("Open in Messages") { NSWorkspace.shared.open(url) }
            }
            Divider()
            ForEach(Cadence.choices, id: \.days) { choice in
                Button {
                    model.setCadence(key: nudge.key, title: nudge.title, days: choice.days)
                } label: {
                    if nudge.cadenceDays == choice.days {
                        Label(choice.label, systemImage: "checkmark")
                    } else {
                        Text(choice.label)
                    }
                }
            }
            Button {
                model.setCallsOnly(nudge, !callsOnly)
            } label: {
                if callsOnly { Label("Only calls count", systemImage: "checkmark") } else { Text("Only calls count") }
            }
            Divider()
            Button("Remove from favorites") { model.setCadence(key: nudge.key, title: nudge.title, days: 0) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// "texted 10d ago · called 2w ago", leaving out whichever never happened.
    private var lastTalked: String {
        var parts: [String] = []
        if let texted = nudge.lastTexted { parts.append("texted \(ago(texted))") }
        if let called = nudge.lastCalled { parts.append("called \(ago(called))") }
        if parts.isEmpty { return "no messages in a while" }
        if !isDue {
            let days = Int(ceil((nudge.dueAt - now) / 86_400))
            parts.append(days <= 1 ? "say hi tomorrow" : "say hi in \(days)d")
        }
        return parts.joined(separator: " · ")
    }

    private var birthdayNote: String? {
        guard let days = Birthday.daysUntil(nudge.birthday), days <= 7 else { return nil }
        switch days {
        case 0: return "🎂 Birthday today"
        case 1: return "🎂 Birthday tomorrow"
        default:
            let date = Date().addingTimeInterval(Double(days) * 86_400)
            let weekday = date.formatted(.dateTime.weekday(.wide))
            return "🎂 Birthday \(weekday)"
        }
    }

    private func ago(_ date: Double) -> String {
        let days = Int((now - date) / 86_400)
        switch days {
        case 0: return "today"
        case 1: return "yesterday"
        case ..<14: return "\(days)d ago"
        case ..<60: return "\(days / 7)w ago"
        default: return "\(days / 30)mo ago"
        }
    }
}

/// A small teal dot before the text, softer than coloring the words.
private struct SoftDot: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(.teal)
            configuration.title
        }
    }
}

private struct SuggestionRow: View {
    @ObservedObject var model: StripModel
    var suggestion: NudgeResponse.Suggestion

    private var daysAgo: Int {
        Int((Date().timeIntervalSince1970 - suggestion.firstContact) / 86_400)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Avatar(model: model, key: suggestion.key, title: suggestion.title, size: 32)
                Button {
                    model.openConversation(key: suggestion.key, title: suggestion.title, isGroup: false)
                } label: {
                    Text(suggestion.title).font(.body.weight(.medium)).lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Open the conversation")
                Spacer()
                OpenInMessages(key: suggestion.key)
                Button {
                    model.setCadence(key: suggestion.key, title: suggestion.title, days: 0)
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Don't suggest again")
            }
            if let preview = suggestion.preview, !preview.isEmpty {
                Text((suggestion.lastFromMe == true ? "You: " : "") + preview)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(.primary.opacity(0.8))
            }
            Text("Met \(daysAgo) days ago · \(suggestion.messageCount) messages")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button("Every 2 wk") {
                    model.setCadence(key: suggestion.key, title: suggestion.title, days: 14)
                }
                Button("Monthly") {
                    model.setCadence(key: suggestion.key, title: suggestion.title, days: 30)
                }
            }
            .controlSize(.small)
            .disabled(model.busy)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
        .contentShape(Rectangle())
        .onTapGesture {
            model.openConversation(key: suggestion.key, title: suggestion.title, isGroup: false)
        }
    }
}

/// Jumps to the thread in Messages, for photos, reactions and everything the strip skips.
private struct OpenInMessages: View {
    var key: String

    var body: some View {
        if let url = MessagesApp.url(forKey: key) {
            Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless)
                .help("Open in Messages")
        }
    }
}

/// Where a chat lives: iMessage, SMS, WhatsApp, Instagram or Messenger.
private struct NetworkBadge: View {
    var key: String
    var service: String?

    private var name: String? {
        guard let service, !service.isEmpty else { return key.hasPrefix("bp:") ? nil : "iMessage" }
        if service.localizedCaseInsensitiveContains("messenger") { return "Messenger" }
        return service
    }

    private var tint: Color {
        switch name {
        case "iMessage": return .blue
        case "SMS", "RCS": return .green
        case "WhatsApp": return .teal
        case "Instagram": return .pink
        case "Messenger": return .indigo
        default: return .gray
        }
    }

    var body: some View {
        if let name {
            Text(name)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(tint.opacity(0.25)))
        }
    }
}

/// A person's picture, or their initials on a stable colour when there isn't one.
struct Avatar: View {
    @ObservedObject var model: StripModel
    var key: String
    var title: String
    var size: CGFloat = 28

    var body: some View {
        AsyncImage(url: model.keepInTouch?.avatarURL(key: key)) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color(hue: Format.avatarHue(key), saturation: 0.45, brightness: 0.6))
                    Text(Format.initials(title))
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}


/// Every conversation, newest first, like the Messages sidebar. Nothing opens until you
/// pick one.
private struct ConversationList: View {
    @ObservedObject var model: StripModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search conversations", text: $model.queueFilter)
                    .textFieldStyle(.plain)
                if !model.queueFilter.isEmpty {
                    Button { model.queueFilter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.6)))
            .padding(.horizontal, 14)
            .padding(.top, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.filteredQueue) { thread in
                        row(thread) { model.queueFilter = ""; model.open(thread.key) }
                    }
                    if !model.otherResults.isEmpty {
                        Text("OLDER CONVERSATIONS")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 10)
                            .padding(.horizontal, 14)
                        ForEach(model.otherResults) { thread in
                            row(thread) { model.openFromSearch(thread) }
                        }
                    }
                }
            }
        }
    }

    private func row(_ thread: ThreadSummary, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Avatar(model: model, key: thread.key, title: thread.title, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(thread.title).font(.body.weight(thread.needsReply ? .semibold : .regular))
                            .lineLimit(1)
                        NetworkBadge(key: thread.key, service: thread.service)
                        Spacer()
                        Text(Format.relative(thread.lastMessage.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text((thread.lastMessage.isFromMe ? "You: " : "") + thread.lastMessage.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// With more than one Claude session going: each one you prompted, what you asked, and
/// whether it's working, waiting on you, or done, so you can see which one to go back to.
private struct SessionList: View {
    @ObservedObject var model: StripModel
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.sessions.prefix(5)) { session in
                HStack(spacing: 8) {
                    icon(session)
                        .frame(width: 14)
                    Text(session.prompt.isEmpty ? session.project : session.prompt)
                        .lineLimit(1)
                        .foregroundStyle(session.isWorking ? .secondary : .primary)
                    Spacer(minLength: 6)
                    status(session)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if session.isDone {
                        Button { ClaudeWatch.dismiss(session.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Seen it")
                    }
                }
                .font(.callout)
                .contentShape(Rectangle())
                .onTapGesture {
                    if session.isDone { ClaudeWatch.dismiss(session.id) }
                    if !session.isWorking { onBack() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    @ViewBuilder private func icon(_ session: ClaudeWatch.Session) -> some View {
        switch session.state {
        case .working: ProgressView().controlSize(.mini)
        case .needsYou: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    @ViewBuilder private func status(_ session: ClaudeWatch.Session) -> some View {
        switch session.state {
        case .working(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
            }
        case .needsYou:
            Text("needs you")
        case .done(let at):
            TimelineView(.periodic(from: at, by: 30)) { context in
                let minutes = Int(context.date.timeIntervalSince(at) / 60)
                Text(minutes < 1 ? "done just now" : "done \(minutes)m ago")
            }
        }
    }
}
