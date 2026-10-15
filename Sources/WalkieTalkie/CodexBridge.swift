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
        /// Only the helper's process-verified native Terminal mapping is usable.
        let terminalTTY: String?
        var key: String { "codex:" + id }
        var folder: String { (cwd as NSString).lastPathComponent }
        var handle: TerminalBinding.Handle { .codex(threadID: id, tty: terminalTTY) }
        var locationLabel: String {
            guard live else { return "Status unverified · checked when binding" }
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
                                 liveOnly: Bool = false) throws -> ConversationPage {
        var arguments = ["list", "--limit", String(limit)]
        if let cursor, !cursor.isEmpty { arguments += ["--cursor", cursor] }
        if liveOnly { arguments.append("--live-only") }
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
            throw failure(detail.isEmpty ? "Codex bridge failed" : String(detail.prefix(500)))
        }
        return result
    }
    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        var value: Data { get { lock.lock(); defer { lock.unlock() }; return data } set { lock.lock(); data = newValue; lock.unlock() } }
    }
    private static func failure(_ message: String) -> NSError { NSError(domain: "CodexBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
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

/// Project-first Codex chat selection. The panel owns the keyboard without
/// activating Walkie Talkie, like RebindPanel, so the app behind it regains the
/// keyboard as soon as this closes.
final class CodexChatPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                             NSTextFieldDelegate, NSWindowDelegate {
    private enum Mode {
        case projects
        case conversations(cwd: String)
    }

    private enum Selection {
        case project(cwd: String)
        case conversation(id: String)
    }

    private let width: CGFloat = 640
    private let rowHeight: CGFloat = 52
    private let visibleRows: CGFloat = 7

    private var panel: CodexPickerKeyPanel?
    private let search = NSTextField()
    private let glass = NSTextField(labelWithString: "⌕")
    private let backButton = NSButton(title: "‹", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let countLabel = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()

    private var all: [CodexBridge.Conversation] = []
    private var projects: [CodexPickerProject] = []
    private var visibleProjects: [CodexPickerProject] = []
    private var visibleConversations: [CodexBridge.Conversation] = []
    private var mode: Mode = .projects
    private var hasLoadedCatalog = false
    private var isRefreshing = false
    private var pendingCatalog: [CodexBridge.Conversation]?
    private var statusMessage: String?
    private var refreshError: String?
    private var reloadGeneration: UInt64 = 0
    private var wasKey = false
    private var clickMonitor: Any?
    private let ownerCheck = CodexPickerCheckGate()

    var onPick: ((CodexBridge.Conversation) -> Void)?
    /// Called only after the exact stable ID has been freshly and conclusively
    /// found closed. The receiver may open that historical chat in Terminal.
    var onResume: ((_ session: String, _ cwd: String) -> Void)?

    func show() {
        if panel != nil { close(); return }

        visibleProjects = []
        visibleConversations = []
        mode = .projects
        wasKey = false
        statusMessage = nil
        search.stringValue = ""
        isRefreshing = true
        refreshError = nil
        ownerCheck.invalidate()
        reloadGeneration &+= 1
        let generation = reloadGeneration

        let panel = buildPanel()
        self.panel = panel
        place(panel)
        applyFilter()
        panel.makeKeyAndOrderFront(nil)
        focusSearch(in: panel)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in DispatchQueue.main.async { self?.close() }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try CodexBridge.conversationCatalog() }
            DispatchQueue.main.async {
                guard let self, self.panel != nil, self.reloadGeneration == generation else { return }
                self.isRefreshing = false
                switch result {
                case .success(let conversations):
                    self.refreshError = nil
                    if self.ownerCheck.isChecking {
                        // A bulk refresh is metadata only. It must not move the
                        // exact row whose owner check is already in flight.
                        self.pendingCatalog = conversations
                        self.refreshChrome()
                    } else {
                        let selection = self.currentSelection()
                        self.replaceCatalog(conversations, selection: selection, redraw: true)
                    }
                case .failure(let error):
                    self.refreshError = "Could not refresh chats: \(error.localizedDescription)"
                    self.refreshChrome()
                }
            }
        }
    }

    func close() {
        ownerCheck.invalidate()
        installPendingCatalog(redraw: false)
        reloadGeneration &+= 1
        spinner.stopAnimation(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
    }

    var isOpen: Bool { panel != nil }

    /// Read-only native QA state. The optional image is rendered from this
    /// picker's own content view; it never asks WindowServer for a screenshot.
    func testState(snapshot: Bool = false) -> [String: Any] {
        guard Thread.isMainThread else {
            return ["error": "Codex picker testState must run on the main thread"]
        }

        let selectedRow = table.selectedRow
        var selectedProjectCWD: Any = NSNull()
        var selectedChatID: Any = NSNull()
        let modeName: String
        switch mode {
        case .projects:
            modeName = "projects"
            if visibleProjects.indices.contains(selectedRow) {
                selectedProjectCWD = visibleProjects[selectedRow].cwd
            }
        case .conversations:
            modeName = "chats"
            if visibleConversations.indices.contains(selectedRow) {
                selectedChatID = visibleConversations[selectedRow].id
            }
        }

        let frame: Any = panel.map {
            ["x": $0.frame.minX, "y": $0.frame.minY,
             "w": $0.frame.width, "h": $0.frame.height]
        } ?? NSNull()
        var state: [String: Any] = [
            "open": panel?.isVisible == true,
            "mode": modeName,
            "query": search.stringValue,
            "rowCount": numberOfRows(in: table),
            "selectedProjectCWD": selectedProjectCWD,
            "selectedChatID": selectedChatID,
            "cached": hasLoadedCatalog,
            "loading": isRefreshing,
            "checking": ownerCheck.isChecking,
            "frame": frame,
        ]

        if snapshot {
            guard let panel, panel.isVisible, let view = panel.contentView else {
                state["snapshotError"] = "Codex picker is not visible"
                return state
            }
            let bounds = view.bounds
            guard !bounds.isEmpty,
                  let png = view.bitmapImageRepForCachingDisplay(in: bounds).flatMap({ representation in
                      view.cacheDisplay(in: bounds, to: representation)
                      return representation.representation(using: .png, properties: [:])
                  }) else {
                state["snapshotError"] = "Could not render Codex picker content"
                return state
            }
            let url = Outbox.cacheRoot.appendingPathComponent("codex-picker-test.png")
            do {
                try FileManager.default.createDirectory(
                    at: Outbox.cacheRoot, withIntermediateDirectories: true)
                try png.write(to: url, options: .atomic)
                state["snapshotPath"] = url.path
            } catch {
                state["snapshotError"] = error.localizedDescription
            }
        }
        return state
    }

    private func buildPanel() -> CodexPickerKeyPanel {
        let height = 58 + 1 + rowHeight * visibleRows + 30
        let panel = CodexPickerKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Bind a Codex chat"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onNavigationKey = { [weak self, weak panel] event in
            guard let self, let panel, self.panel === panel else { return false }
            return self.handleNavigation(event, in: panel)
        }

        let blur = NSVisualEffectView(frame: panel.contentView?.bounds
                                      ?? NSRect(x: 0, y: 0, width: width, height: height))
        blur.material = .menu
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        panel.contentView = blur

        glass.frame = NSRect(x: 17, y: height - 43, width: 22, height: 22)
        glass.font = .systemFont(ofSize: 18, weight: .medium)
        glass.textColor = .secondaryLabelColor
        blur.addSubview(glass)

        backButton.frame = NSRect(x: 10, y: height - 47, width: 32, height: 30)
        backButton.isBordered = false
        backButton.font = .systemFont(ofSize: 26, weight: .regular)
        backButton.contentTintColor = .secondaryLabelColor
        backButton.target = self
        backButton.action = #selector(back)
        blur.addSubview(backButton)

        search.frame = NSRect(x: 44, y: height - 44, width: width - 44 - 180, height: 26)
        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.font = .systemFont(ofSize: 16)
        search.textColor = .labelColor
        search.isEditable = true
        search.isSelectable = true
        search.isEnabled = true
        search.delegate = self
        search.cell?.usesSingleLineMode = true
        blur.addSubview(search)
        panel.initialFirstResponder = search

        spinner.frame = NSRect(x: width - 31, y: height - 39, width: 16, height: 16)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        blur.addSubview(spinner)

        countLabel.frame = NSRect(x: width - 174, y: height - 38, width: 132, height: 16)
        countLabel.alignment = .right
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .tertiaryLabelColor
        blur.addSubview(countLabel)

        let rule = NSView(frame: NSRect(x: 0, y: height - 58, width: width, height: 1))
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        blur.addSubview(rule)

        if table.tableColumns.isEmpty {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("codex-picker"))
            column.width = width
            table.addTableColumn(column)
        }
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .regular
        // This is a search-driven menu. Keep typing in the search field even
        // after a mouse selection; the panel still handles list navigation.
        table.refusesFirstResponder = true
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(activateSelected)
        table.doubleAction = nil

        scroll.frame = NSRect(x: 0, y: 30, width: width, height: rowHeight * visibleRows)
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = table
        blur.addSubview(scroll)

        footer.frame = NSRect(x: 16, y: 8, width: width - 32, height: 16)
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        blur.addSubview(footer)
        return panel
    }

    private func place(_ panel: NSPanel) {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        var origin = NSPoint(x: point.x - 40, y: point.y - size.height - 8)
        origin.x = min(max(origin.x, area.minX + 12), area.maxX - size.width - 12)
        origin.y = min(max(origin.y, area.minY + 12), area.maxY - size.height - 12)
        panel.setFrameOrigin(origin)
    }

    func controlTextDidChange(_ obj: Notification) {
        cancelOwnerCheck()
        statusMessage = nil
        applyFilter()
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        guard control === search else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            activateSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            back()
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
            moveSelection(by: Int(visibleRows))
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
            moveSelection(by: -Int(visibleRows))
        default:
            return false
        }
        return true
    }

    private func handleNavigation(_ event: NSEvent, in panel: NSPanel) -> Bool {
        let hasMarkedText = (panel.firstResponder as? NSTextView)?.hasMarkedText() == true
        guard let command = CodexPickerNavigationCommand.command(
            keyCode: event.keyCode, modifiers: event.modifierFlags,
            hasMarkedText: hasMarkedText) else { return false }
        switch command {
        case .move(let delta): moveSelection(by: delta)
        case .page(let direction): moveSelection(by: direction * Int(visibleRows))
        case .activate: activateSelected()
        case .back: back()
        }
        return true
    }

    private func focusSearch(in expectedPanel: NSPanel? = nil) {
        guard let panel, expectedPanel == nil || panel === expectedPanel else { return }
        if !panel.makeFirstResponder(search) {
            // A newly ordered nonactivating panel can create its field editor
            // one run-loop turn later. Retry only while this opening survives.
            DispatchQueue.main.async { [weak self, weak panel] in
                guard let self, let panel, self.panel === panel else { return }
                _ = panel.makeFirstResponder(self.search)
            }
        }
    }

    private func moveSelection(by delta: Int) {
        let count = numberOfRows(in: table)
        guard count > 0 else { return }
        let current = table.selectedRow
        let next = current < 0 ? (delta > 0 ? 0 : count - 1)
            : min(count - 1, max(0, current + delta))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func applyFilter(preferredProjectCWD: String? = nil) {
        applyFilter(preferredProjectCWD: preferredProjectCWD, preferredConversationID: nil)
    }

    private func applyFilter(preferredProjectCWD: String?, preferredConversationID: String?) {
        switch mode {
        case .projects:
            visibleProjects = CodexPickerCatalog.projects(projects, matching: search.stringValue)
            visibleConversations = []
        case .conversations(let cwd):
            visibleProjects = []
            if let project = projects.first(where: { $0.cwd == cwd }) {
                visibleConversations = CodexPickerCatalog.conversations(
                    in: project, matching: search.stringValue)
            } else {
                visibleConversations = []
            }
        }
        table.reloadData()
        table.deselectAll(nil)
        let count = numberOfRows(in: table)
        if count > 0 {
            var row = 0
            if case .projects = mode, let preferredProjectCWD,
               let preferred = visibleProjects.firstIndex(where: { $0.cwd == preferredProjectCWD }) {
                row = preferred
            } else if case .conversations = mode, let preferredConversationID,
                      let preferred = visibleConversations.firstIndex(where: { $0.id == preferredConversationID }) {
                row = preferred
            }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        refreshChrome()
    }

    private func currentSelection() -> Selection? {
        let row = table.selectedRow
        switch mode {
        case .projects:
            guard visibleProjects.indices.contains(row) else { return nil }
            return .project(cwd: visibleProjects[row].cwd)
        case .conversations:
            guard visibleConversations.indices.contains(row) else { return nil }
            return .conversation(id: visibleConversations[row].id)
        }
    }

    private func replaceCatalog(_ conversations: [CodexBridge.Conversation],
                                selection: Selection?, redraw: Bool) {
        all = conversations
        projects = CodexPickerCatalog.projects(from: conversations)
        hasLoadedCatalog = true
        pendingCatalog = nil
        guard redraw else { return }
        switch selection {
        case .project(let cwd):
            applyFilter(preferredProjectCWD: cwd, preferredConversationID: nil)
        case .conversation(let id):
            applyFilter(preferredProjectCWD: nil, preferredConversationID: id)
        case nil:
            applyFilter()
        }
    }

    private func installPendingCatalog(redraw: Bool, selection: Selection? = nil,
                                       preferredConversationID: String? = nil) {
        guard let pendingCatalog else { return }
        let preferred = selection
            ?? preferredConversationID.map { Selection.conversation(id: $0) }
            ?? currentSelection()
        replaceCatalog(pendingCatalog, selection: preferred, redraw: redraw)
    }

    @objc private func back() {
        cancelOwnerCheck()
        statusMessage = nil
        switch mode {
        case .projects:
            close()
        case .conversations(let cwd):
            mode = .projects
            search.stringValue = ""
            applyFilter(preferredProjectCWD: cwd)
            focusSearch()
        }
    }

    @objc private func activateSelected() {
        guard panel != nil else { return }
        let row = table.selectedRow
        switch mode {
        case .projects:
            guard visibleProjects.indices.contains(row) else { return }
            let project = visibleProjects[row]
            mode = .conversations(cwd: project.cwd)
            search.stringValue = ""
            statusMessage = nil
            applyFilter()
            focusSearch()
        case .conversations:
            guard visibleConversations.indices.contains(row) else { return }
            verifyAndActivate(visibleConversations[row])
        }
    }

    private func verifyAndActivate(_ selected: CodexBridge.Conversation) {
        guard let token = ownerCheck.begin(threadID: selected.id) else { return }
        statusMessage = nil
        refreshChrome()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try CodexBridge.pickerDisposition(
                    session: token.threadID, recordedCWD: selected.cwd)
            }
            DispatchQueue.main.async {
                guard let self, self.ownerCheck.accept(token), self.panel != nil else { return }
                self.installPendingCatalog(
                    redraw: true, preferredConversationID: token.threadID)
                self.refreshChrome()
                switch result {
                case .success(.bind(let chat)):
                    self.close()
                    self.onPick?(chat)
                case .success(.resume(let session, let cwd)):
                    self.close()
                    self.onResume?(session, cwd)
                case .failure(let error):
                    self.statusMessage = "Could not verify this chat: \(error.localizedDescription)"
                    self.refreshChrome()
                }
            }
        }
    }

    private func cancelOwnerCheck() {
        guard ownerCheck.isChecking else { return }
        let selection = currentSelection()
        ownerCheck.invalidate()
        installPendingCatalog(redraw: true, selection: selection)
        refreshChrome()
    }

    private func refreshChrome() {
        let checking = ownerCheck.isChecking
        if isRefreshing || checking { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        backButton.isHidden = {
            if case .projects = mode { return true }
            return false
        }()
        glass.isHidden = !backButton.isHidden

        switch mode {
        case .projects:
            search.placeholderString = "Search project folders…"
            countLabel.stringValue = !hasLoadedCatalog && isRefreshing ? "loading history…" :
                "\(visibleProjects.count) folder\(visibleProjects.count == 1 ? "" : "s")"
        case .conversations(let cwd):
            let title = projects.first(where: { $0.cwd == cwd })?.title ?? "Project"
            search.placeholderString = "Search chats in \(title)…"
            countLabel.stringValue = "\(visibleConversations.count) chat\(visibleConversations.count == 1 ? "" : "s")"
        }
        if let statusMessage {
            footer.stringValue = statusMessage
            footer.textColor = .systemRed
        } else if checking {
            footer.textColor = .tertiaryLabelColor
            footer.stringValue = "Checking the exact Codex owner…"
        } else if !hasLoadedCatalog && isRefreshing {
            footer.textColor = .tertiaryLabelColor
            footer.stringValue = "Loading available, non-archived chats across recorded project folders…"
        } else if let refreshError {
            footer.textColor = .systemRed
            footer.stringValue = refreshError
        } else {
            footer.textColor = .tertiaryLabelColor
            switch mode {
            case .projects:
                footer.stringValue = "Projects are grouped by recorded folder   ·   ↑↓ choose   ·   ⏎ open   ·   esc close"
            case .conversations:
                footer.stringValue = "Past chats reopen in Terminal   ·   ↑↓ choose   ·   ⏎ check & open   ·   esc projects"
            }
        }
        redrawVisibleRows()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch mode {
        case .projects: return visibleProjects.count
        case .conversations: return visibleConversations.count
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let cancelled = ownerCheck.isChecking
        let clearedMessage = statusMessage != nil
        let selection = currentSelection()
        if cancelled {
            ownerCheck.invalidate()
            installPendingCatalog(redraw: true, selection: selection)
        }
        statusMessage = nil
        if cancelled || clearedMessage { refreshChrome() }
        else { redrawVisibleRows() }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CodexPickerTableRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("codex-picker-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? CodexPickerCellView ?? CodexPickerCellView()
        cell.identifier = identifier
        switch mode {
        case .projects:
            guard visibleProjects.indices.contains(row) else { return nil }
            let project = visibleProjects[row]
            let chats = project.conversations.count
            let path = project.cwd.isEmpty ? "Working folder was not recorded" : project.cwd
            let status = "\(chats) chat\(chats == 1 ? "" : "s") · \(path)"
            cell.configure(title: project.title, subtitle: status,
                           symbol: "folder.fill",
                           action: tableView.selectedRow == row ? "⏎  open" : "")
        case .conversations:
            guard visibleConversations.indices.contains(row) else { return nil }
            let chat = visibleConversations[row]
            let status: String
            let action: String
            let symbol: String
            if chat.live, let tty = chat.terminalTTY {
                status = "Terminal · \((tty as NSString).lastPathComponent) · live"
                action = "⏎  bind"
                symbol = "terminal.fill"
            } else if chat.live {
                status = "Codex Desktop · live"
                action = "⏎  bind"
                symbol = "bubble.left.and.bubble.right.fill"
            } else {
                status = "Not checked yet · closed chats reopen in Terminal"
                action = "⏎  check"
                symbol = "clock.arrow.circlepath"
            }
            cell.configure(title: (chat.busy ? "In progress · " : "") + chat.title,
                           subtitle: status, symbol: symbol,
                           action: tableView.selectedRow == row ? action : "")
        }
        return cell
    }

    func windowDidBecomeKey(_ notification: Notification) { wasKey = true }

    func windowDidResignKey(_ notification: Notification) {
        guard wasKey else { return }
        close()
    }

    private func redrawVisibleRows() {
        let rows = numberOfRows(in: table)
        guard rows > 0, !table.tableColumns.isEmpty else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows),
                         columnIndexes: IndexSet(integersIn: 0..<table.tableColumns.count))
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

private final class CodexPickerTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 3), xRadius: 7, yRadius: 7).fill()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 6, y: 6, width: 3, height: bounds.height - 12),
                     xRadius: 1.5, yRadius: 1.5).fill()
    }
}

private final class CodexPickerCellView: NSTableCellView {
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let actionLabel = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11.5)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        actionLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        actionLabel.textColor = .controlAccentColor
        actionLabel.alignment = .right
        for view in [symbolView, titleLabel, subtitleLabel, actionLabel] { addSubview(view) }
    }

    required init?(coder: NSCoder) { nil }

    func configure(title: String, subtitle: String, symbol: String, action: String) {
        symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        actionLabel.stringValue = action
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let actionWidth: CGFloat = 92
        let reserved = actionLabel.stringValue.isEmpty ? 0 : actionWidth + 10
        symbolView.frame = NSRect(x: 17, y: 17, width: 18, height: 18)
        actionLabel.frame = NSRect(x: bounds.width - actionWidth - 16, y: 18,
                                   width: actionWidth, height: 16)
        let textWidth = max(0, bounds.width - 60 - reserved)
        titleLabel.frame = NSRect(x: 44, y: 7, width: textWidth, height: 17)
        subtitleLabel.frame = NSRect(x: 44, y: 27, width: textWidth, height: 16)
    }
}
