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
            guard live else { return "Saved · open in Codex or resume through Rebind to…" }
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
        let result = try invoke(["list", "--limit", "100"] + (liveOnly ? ["--live-only"] : []))
        return (result["threads"] as? [[String: Any]] ?? []).compactMap(Conversation.init)
    }
    static func conversation(_ id: String, timeout: TimeInterval = 25) throws -> Conversation? {
        let result = try invoke(["thread", "--id", id], timeout: timeout)
        return Conversation(result["thread"] as? [String: Any] ?? result)
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

/// Explicit chat selection prevents a background dictation being sent to a different chat.
final class CodexChatPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var panel: NSPanel?
    private let search = NSSearchField()
    private let projects = NSPopUpButton()
    private let table = NSTableView()
    private let bindButton = NSButton(title: "Bind selected chat", target: nil, action: nil)
    private let message = NSTextField(labelWithString: "Loading Codex chats…")
    private var all: [CodexBridge.Conversation] = []
    private var visible: [CodexBridge.Conversation] = []
    var onPick: ((CodexBridge.Conversation) -> Void)?

    func show() {
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 650, height: 420),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        p.title = "Bind a Codex chat"
        p.isReleasedWhenClosed = false
        let view = NSView(frame: p.contentView!.bounds)
        p.contentView = view
        search.placeholderString = "Search chats by name or project"
        search.delegate = self
        projects.target = self; projects.action = #selector(filterChanged)
        projects.addItem(withTitle: "All projects")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("chat")); column.width = 600
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 48
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(bindSelected)
        scroll.documentView = table
        bindButton.target = self; bindButton.action = #selector(bindSelected); bindButton.keyEquivalent = "\r"
        bindButton.isEnabled = false
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(reload))
        for v in [search, projects, scroll, message, bindButton, refresh] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: view.topAnchor, constant: 16), search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            projects.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10), projects.leadingAnchor.constraint(equalTo: search.leadingAnchor), projects.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: projects.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: search.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -10),
            message.leadingAnchor.constraint(equalTo: search.leadingAnchor), message.bottomAnchor.constraint(equalTo: bindButton.topAnchor, constant: -12),
            bindButton.trailingAnchor.constraint(equalTo: search.trailingAnchor), bindButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14), refresh.leadingAnchor.constraint(equalTo: search.leadingAnchor), refresh.centerYAnchor.constraint(equalTo: bindButton.centerYAnchor)
        ])
        panel = p; p.center(); p.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        reload()
    }
    @objc private func reload() {
        message.stringValue = "Loading Codex chats…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try CodexBridge.conversations() }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let rows):
                    self.all = rows
                    self.projects.removeAllItems(); self.projects.addItem(withTitle: "All projects")
                    for path in Set(rows.map(\.cwd)).sorted() where !path.isEmpty { self.projects.addItem(withTitle: path) }
                    self.filterChanged()
                case .failure(let error): self.message.stringValue = error.localizedDescription
                }
            }
        }
    }
    func controlTextDidChange(_ obj: Notification) { filterChanged() }
    @objc private func filterChanged() {
        let query = search.stringValue.lowercased(), project = projects.indexOfSelectedItem > 0 ? projects.titleOfSelectedItem : nil
        visible = all.filter { (project == nil || $0.cwd == project) && (query.isEmpty || ($0.title + " " + $0.cwd).lowercased().contains(query)) }
        table.reloadData()
        table.deselectAll(nil)
        if let firstLive = visible.firstIndex(where: \.live) { table.selectRowIndexes(IndexSet(integer: firstLive), byExtendingSelection: false) }
        bindButton.isEnabled = visible.indices.contains(table.selectedRow) && visible[table.selectedRow].live
        message.stringValue = "\(visible.filter(\.live).count) live · \(visible.count) total · Saved chats must be opened before binding"
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        bindButton.isEnabled = visible.indices.contains(table.selectedRow) && visible[table.selectedRow].live
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visible.indices.contains(row) else { return nil }
        let chat = visible[row]
        let label = NSTextField(wrappingLabelWithString: "\(chat.busy ? "⏳ " : "")\(chat.title) · \(chat.locationLabel)\n\(chat.cwd)")
        label.font = .systemFont(ofSize: 13)
        return label
    }
    @objc private func bindSelected() {
        guard visible.indices.contains(table.selectedRow) else { return }
        let chat = visible[table.selectedRow]
        guard chat.live else {
            message.stringValue = "Open this saved chat in Codex and Refresh, or resume it through Rebind to…"
            return
        }
        panel?.orderOut(nil); panel = nil
        onPick?(chat)
    }
}
