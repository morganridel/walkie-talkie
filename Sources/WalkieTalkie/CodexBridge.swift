import AppKit

/// A conversation is addressed by its Codex ID, independent of windows and focus.
enum CodexBridge {
    struct Conversation: Equatable {
        let id: String
        let title: String
        let cwd: String
        let busy: Bool
        let source: String
        let live: Bool
        let background: Bool
        let archived: Bool
        let status: String
        /// Only the helper's process-verified native Terminal mapping is usable.
        let terminalTTY: String?
        var key: String { "codex:" + id }
        var folder: String { (cwd as NSString).lastPathComponent }
        var handle: TerminalBinding.Handle { .codex(threadID: id, tty: terminalTTY) }
        var locationLabel: String {
            if background {
                if status == "waitingOnApproval" { return "Background · waiting for approval" }
                if status == "waitingOnUserInput" { return "Background · waiting for your answer" }
                if status == "error" || status == "systemError" { return "Background · error" }
                return busy ? "Background · working" : "Background · ready"
            }
            guard live else { return archived ? "Archived" : "Saved chat" }
            if let terminalTTY { return "CLI · " + (terminalTTY as NSString).lastPathComponent }
            return "Codex · live"
        }
        init?(_ row: [String: Any]) {
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            self.id = id
            title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled Codex chat"
            cwd = row["cwd"] as? String ?? ""
            busy = row["busy"] as? Bool ?? false
            source = row["source"] as? String ?? ""
            live = row["live"] as? Bool ?? false
            background = row["background"] as? Bool ?? false
            archived = row["archived"] as? Bool ?? false
            status = row["status"] as? String ?? ""
            if live, row["ttyOwner"] as? Bool == true, let tty = row["tty"] as? String,
               tty.range(of: #"^/dev/ttys\d+$"#, options: .regularExpression) != nil {
                terminalTTY = tty
            } else { terminalTTY = nil }
        }
    }

    static let desktopBundleIDs: Set<String> = ["com.openai.chat", "com.openai.codex"]
    static var helperPath: String? {
        let candidates: [String?] = [Bundle.main.resourceURL?.appendingPathComponent("codex_bridge.py").path,
                          URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                            .deletingLastPathComponent().appendingPathComponent("helpers/codex_bridge.py").path]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }
    static var launcherPath: String? { helperPath.map { (URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("walkie-codex")).path } }
    static var binaryPath: String? {
        let candidates: [String?] = [ProcessInfo.processInfo.environment["CODEX_BIN"],
          "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
          "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex"]
        return candidates
            .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Off the main thread. Reads metadata only; it does not start or alter a chat.
    static func conversations(liveOnly: Bool = false) throws -> [Conversation] {
        try conversationPage(liveOnly: liveOnly).conversations
    }

    struct ConversationPage {
        let conversations: [Conversation]
        let nextCursor: String?
    }

    /// The picker walks every page exposed by the active metadata transport so
    /// a project whose available chats are older than the newest global 100 is
    /// still reachable. Other callers keep the intentionally small single-page
    /// `conversations()` behavior.
    static func conversationPage(limit: Int = 100, cursor: String? = nil,
                                 liveOnly: Bool = false, includeArchived: Bool = false,
                                 quickOnly: Bool = false) throws -> ConversationPage {
        var arguments = [quickOnly ? "recent" : "list", "--limit", String(limit)]
        if let cursor, !cursor.isEmpty { arguments += ["--cursor", cursor] }
        if liveOnly { arguments.append("--live-only") }
        if includeArchived { arguments.append("--include-archived") }
        let result = try invoke(arguments)
        return ConversationPage(
            conversations: (result["threads"] as? [[String: Any]] ?? [])
                .compactMap(Conversation.init),
            nextCursor: (result["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    static func conversationCatalog(
        load: (String?) throws -> ConversationPage = {
            try CodexBridge.conversationPage(cursor: $0)
        }
    ) throws -> [Conversation] {
        var cursor: String?
        var seenCursors: Set<String> = []
        var seenIDs: Set<String> = []
        var conversations: [Conversation] = []
        repeat {
            let page = try load(cursor)
            for chat in page.conversations where seenIDs.insert(chat.id).inserted {
                conversations.append(chat)
            }
            cursor = page.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted { break }
        } while cursor != nil
        return conversations
    }
    static func conversation(_ id: String, timeout: TimeInterval = 25,
                             requireOwnerState: Bool = false) throws -> Conversation? {
        let result = try invoke(["thread", "--id", id]
                                + (requireOwnerState ? ["--require-owner-state"] : []),
                                timeout: timeout)
        let ownerState = result["ownerState"] as? String
        if requireOwnerState {
            guard ownerState == "live" || ownerState == "closed" else {
                throw failure("Codex ownership check returned no conclusive state")
            }
        }
        let chat = Conversation(result["thread"] as? [String: Any] ?? result)
        if requireOwnerState, let chat,
           (ownerState == "live") != chat.live {
            throw failure("Codex ownership check returned inconsistent metadata")
        }
        return chat
    }

    enum RebindDisposition: Equatable {
        case bind(Conversation)
        case resume(session: String, cwd: String)
    }

    enum PickerDisposition: Equatable {
        case bind(Conversation)
        case resume(session: String, cwd: String)
    }

    /// Bulk owner discovery is deliberately bounded, so a list miss is not
    /// evidence that a chat is closed. Re-check the selected stable ID and
    /// carry forward only the freshly verified row.
    static func pickerDisposition(
        session: String, recordedCWD: String,
        load: (String) throws -> Conversation? = {
            try CodexBridge.conversation($0, requireOwnerState: true)
        }
    ) throws -> PickerDisposition {
        guard let chat = try load(session) else {
            throw failure("Codex chat no longer exists")
        }
        guard chat.id == session else {
            throw failure("Codex ownership check returned a different chat")
        }
        if chat.live { return .bind(chat) }
        let cwd = chat.cwd.isEmpty ? recordedCWD : chat.cwd
        guard !cwd.isEmpty else {
            throw failure("Codex chat project folder is unavailable")
        }
        return .resume(session: session, cwd: cwd)
    }

    /// Re-check one stable ID at activation time. A saved metadata row is never
    /// enough to resume: Desktop ownership may have changed since search, and a
    /// second private copy of a live chat must not be opened.
    static func rebindDisposition(
        session: String, recordedCWD: String,
        load: (String) throws -> Conversation? = {
            try CodexBridge.conversation($0, requireOwnerState: true)
        }
    ) throws -> RebindDisposition {
        guard let chat = try load(session) else {
            throw failure("Codex chat no longer exists")
        }
        if chat.live { return .bind(chat) }
        let cwd = chat.cwd.isEmpty ? recordedCWD : chat.cwd
        guard !cwd.isEmpty else { throw failure("Codex chat project folder is unavailable") }
        return .resume(session: session, cwd: cwd)
    }
    static func resolve(tty: String) -> Conversation? {
        guard let row = try? invoke(["resolve", "--tty", tty]) else { return nil }
        return Conversation(row["thread"] as? [String: Any] ?? row)
    }
    static func send(_ text: String, to id: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("walkie-prompt-\(UUID().uuidString).txt")
        try withCompletionCue(text).write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        var arguments = ["send", "--thread", id, "--text-file", file.path]
        for path in attachmentPaths(in: text) { arguments += ["--image", path] }
        let result = try invoke(arguments)
        if result["ok"] as? Bool == false { throw failure(result["error"] as? String ?? "Codex refused the message") }
    }

    static let completionCue = """
        [Walkie completion cue: kamikaze means finish the requested work, then close only this session. \
        In a Codex desktop chat, use the app's set_thread_archived tool with archived=true for this chat \
        after finishing; do not close the whole app. In a Walkie-launched CLI, run walkie-finish as your \
        final tool action; it waits for this turn to finish before closing only the verified terminal. \
        If the matching close capability is unavailable, explain that limitation instead of killing \
        another session or the shared server.]
        """
    static func withCompletionCue(_ text: String) -> String {
        TerminalBinding.saysKamikaze(text) && !text.contains("[Walkie completion cue:")
            ? text + "\n\n" + completionCue : text
    }

    /// Attach the actual image bytes as Codex input, rather than relying on model
    /// access to a cache directory outside its project's filesystem policy.
    static func attachmentPaths(in text: String) -> [String] {
        let root = Outbox.cacheRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        func authorized(_ path: String) -> URL? {
            let expanded = path.replacingOccurrences(of: "$WALKIE_SHOTS", with: Outbox.cacheRoot.path)
            let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
            return url.path.hasPrefix(root) && FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        var attachments: Set<String> = []
        if let expression = try? NSRegularExpression(pattern: #"\[📁=([^\]]+)\]"#),
           let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text), let directory = authorized(String(text[range])),
           let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files {
                let name = file.lastPathComponent
                let isShot = name.range(of: #"^screenshot-\d+(?:-800px)?\.jpg$"#, options: .regularExpression) != nil
                if isShot || (name.hasSuffix(".png") && name.contains("sheet")),
                   let safeFile = authorized(file.path) { attachments.insert(safeFile.path) }
            }
        }
        // Films live in the app-session folder, while screenshots can live in a
        // sibling dictation folder. Resolve each explicitly referenced sheet;
        // never search unrelated recordings or assume 📁 is the film's parent.
        let prefixes = #"(?:\$WALKIE_SHOTS|"# + NSRegularExpression.escapedPattern(for: Outbox.cacheRoot.path) + ")"
        if let films = try? NSRegularExpression(pattern: prefixes + #"/[^\]\n,]+/film-[^/\]\n,]+/sheet\.png"#) {
            for match in films.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text), let sheet = authorized(String(text[range])) else { continue }
                attachments.insert(sheet.path)
            }
        }
        return attachments.sorted()
    }
    static func invoke(_ arguments: [String], timeout: TimeInterval = 25) throws -> [String: Any] {
        guard let helper = helperPath else { throw failure("codex_bridge.py is missing; rebuild Walkie Talkie") }
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper] + arguments
        process.standardOutput = output
        process.standardError = errors
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        // Drain concurrently: history/search and error output may exceed a pipe buffer.
        let group = DispatchGroup()
        let data = LockedData(), errorData = LockedData()
        group.enter(); DispatchQueue.global().async { data.value = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errorData.value = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw failure("Codex did not acknowledge the request in \(Int(timeout)) seconds; check the chat before retrying")
        }
        group.wait()
        let rows = data.value.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        guard process.terminationStatus == 0, let result = rows.last else {
            let detail = rows.last?["error"] as? String ?? String(decoding: errorData.value, as: UTF8.self)
            throw failure(detail.isEmpty ? "Codex bridge failed" : String(detail.prefix(500)),
                          code: rows.last?["code"] as? String)
        }
        return result
    }
    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        var value: Data { get { lock.lock(); defer { lock.unlock() }; return data } set { lock.lock(); data = newValue; lock.unlock() } }
    }
    private static func failure(_ message: String, code: String? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let code { info["CodexErrorCode"] = code }
        return NSError(domain: "CodexBridge", code: 1, userInfo: info)
    }
}

/// Invalidates owner checks when the picker changes underneath them. Tokens
/// also prevent a double click from starting two checks for one selection.
final class CodexPickerCheckGate {
    struct Token: Equatable {
        fileprivate let generation: UInt64
        let threadID: String
    }

    private var generation: UInt64 = 0
    private var current: Token?
    var isChecking: Bool { current != nil }

    func begin(threadID: String) -> Token? {
        guard current == nil else { return nil }
        generation &+= 1
        let token = Token(generation: generation, threadID: threadID)
        current = token
        return token
    }

    func invalidate() {
        generation &+= 1
        current = nil
    }

    func accept(_ token: Token) -> Bool {
        guard current == token, generation == token.generation else { return false }
        current = nil
        return true
    }
}

/// A desktop binding remains addressable while the user works in another app.
/// Mouse binding still names the frontmost terminal; only the keyboard shortcut
/// uses the existing desktop binding to open the chat switcher globally.
enum CodexBindShortcut {
    static func perform(bound: TerminalBinding.Handle?, forcePicker: Bool = false,
                        showPicker: () -> Void, bindFrontmost: () -> Void) {
        if forcePicker { showPicker(); return }
        if case .codex(_, nil)? = bound { showPicker() }
        else { bindFrontmost() }
    }
}

/// Explicit chat selection prevents a background dictation being sent to a different chat.
/// One project-like group in the picker. Codex metadata gives us a recorded
/// working directory, not authoritative sidebar project membership, so the UI
/// calls these project folders and never probes the path on disk.
struct CodexPickerProject: Equatable {
    let cwd: String
    let title: String
    let conversations: [CodexBridge.Conversation]
    var liveCount: Int { conversations.filter(\.live).count }
}

enum CodexPickerCatalog {
    static func projects(from conversations: [CodexBridge.Conversation]) -> [CodexPickerProject] {
        // The metadata helper already returns chats newest first using Codex's
        // recency ordering. A folder's first occurrence is its most recent chat.
        var paths: [String] = []
        var grouped: [String: [CodexBridge.Conversation]] = [:]
        for chat in conversations {
            if grouped[chat.cwd] == nil { paths.append(chat.cwd) }
            grouped[chat.cwd, default: []].append(chat)
        }
        return paths.map { cwd in
            let leaf = (cwd as NSString).lastPathComponent
            let title = cwd.isEmpty ? "No recorded folder" : (leaf.isEmpty ? cwd : leaf)
            return CodexPickerProject(cwd: cwd, title: title,
                                      conversations: grouped[cwd] ?? [])
        }
    }

    static func projects(_ projects: [CodexPickerProject], matching query: String) -> [CodexPickerProject] {
        let terms = words(in: query)
        guard !terms.isEmpty else { return projects }
        return projects.filter { project in
            let haystack = (project.title + " " + project.cwd).lowercased()
            return terms.allSatisfy(haystack.contains)
        }
    }

    static func conversations(in project: CodexPickerProject,
                              matching query: String) -> [CodexBridge.Conversation] {
        let terms = words(in: query)
        guard !terms.isEmpty else { return project.conversations }
        return project.conversations.filter { chat in
            let haystack = (chat.title + " " + chat.source + " " + chat.locationLabel).lowercased()
            return terms.allSatisfy(haystack.contains)
        }
    }

    private static func words(in query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

/// Hardware-key routing shared by the field editor and the table. AppKit moves
/// first responder to an NSTableView after a click, so relying only on
/// `NSTextFieldDelegate` leaves Return and paging keys stranded there.
enum CodexPickerNavigationCommand: Equatable {
    case move(Int)
    case page(Int)
    case activate
    case back

    static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                        hasMarkedText: Bool) -> Self? {
        guard !hasMarkedText else { return nil }
        let disallowed: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard modifiers.intersection(disallowed).isEmpty else { return nil }
        switch keyCode {
        case 125: return .move(1)       // Down arrow
        case 126: return .move(-1)      // Up arrow
        case 121: return .page(1)       // Page Down
        case 116: return .page(-1)      // Page Up
        case 36, 76: return .activate   // Return, keypad Enter
        case 53: return .back           // Escape
        default: return nil
        }
    }
}

final class CodexPickerKeyPanel: NSPanel {
    var onNavigationKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onNavigationKey?(event) == true { return }
        super.sendEvent(event)
    }
}
