import AppKit

extension CodexBridge {
    enum OpenDestination: String { case desktop, cli }

    struct BackgroundThread {
        let id: String
        let state: String
        let busy: Bool
        init?(_ row: [String: Any]) {
            guard let id = row["threadId"] as? String ?? row["id"] as? String else { return nil }
            self.id = id
            state = row["state"] as? String ?? row["status"] as? String ?? "idle"
            busy = row["busy"] as? Bool ?? (state == "active")
        }
    }
    struct BackgroundCompletion {
        let id: String
        let threadID: String
        let timestamp: Double
        let status: String
        init?(_ row: [String: Any]) {
            guard let id = row["id"] as? String,
                  let threadID = row["threadId"] as? String else { return nil }
            self.id = id; self.threadID = threadID
            timestamp = (row["timestamp"] as? NSNumber)?.doubleValue ?? 0
            status = row["status"] as? String ?? "completed"
        }
    }
    struct BackgroundRequest {
        struct Choice {
            let id: String
            let label: String
            let response: [String: Any]
        }
        struct Question {
            let id: String
            let title: String
            let options: [String]
            let secret: Bool
        }
        let id: String
        let threadID: String
        let kind: String
        let title: String
        let detail: String
        let choices: [Choice]
        let questions: [Question]
        init?(_ row: [String: Any]) {
            guard let id = row["id"] as? String else { return nil }
            self.id = id; self.threadID = row["threadId"] as? String ?? ""
            kind = row["kind"] as? String ?? "unsupported"
            title = row["title"] as? String ?? "Codex needs your attention"
            detail = row["detail"] as? String ?? ""
            choices = (row["choices"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["id"] as? String, let response = $0["response"] as? [String: Any] else { return nil }
                return Choice(id: id, label: $0["label"] as? String ?? id, response: response)
            }
            questions = (row["questions"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["id"] as? String else { return nil }
                return Question(id: id, title: $0["question"] as? String ?? $0["header"] as? String ?? id,
                                options: ($0["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                                secret: $0["isSecret"] as? Bool ?? false)
            }
        }
    }
    struct BackgroundStatus {
        let threads: [BackgroundThread]
        let requests: [BackgroundRequest]
        let completions: [BackgroundCompletion]
        init(_ row: [String: Any]) {
            threads = (row["threads"] as? [[String: Any]] ?? []).compactMap(BackgroundThread.init)
            requests = (row["requests"] as? [[String: Any]] ?? []).compactMap(BackgroundRequest.init)
            completions = (row["completions"] as? [[String: Any]] ?? []).compactMap(BackgroundCompletion.init)
        }
    }
    static func createBackground(prompt: String, directory: String) throws -> Conversation {
        try withPrivateRequestFile(Data(withCompletionCue(prompt).utf8)) { path in
            var arguments = ["background-create", "--cwd", directory, "--text-file", path]
            for image in attachmentPaths(in: prompt) { arguments += ["--image", image] }
            let result = try invoke(arguments, timeout: 45)
            guard result["ok"] as? Bool != false,
                  let chat = Conversation(result["thread"] as? [String: Any] ?? [:]) else {
                throw explorerFailure(result["error"] as? String ?? "Codex did not return the created chat")
            }
            return chat
        }
    }
    static func backgroundStatus() throws -> BackgroundStatus {
        BackgroundStatus(try invoke(["background-status"]))
    }
    static func respondBackground(requestID: String, response: [String: Any]) throws {
        try withPrivateRequestFile(JSONSerialization.data(withJSONObject: response)) { path in
            let result = try invoke(["background-respond", "--request-id", requestID, "--response-file", path])
            if result["ok"] as? Bool == false {
                throw explorerFailure(result["error"] as? String ?? "Codex refused the response")
            }
        }
    }
    /// Desktop can display saved history while another client owns the writer.
    /// Only a CLI attachment needs an ownership preflight before resuming.
    static func prepareOpen(id: String, destination: OpenDestination,
                            run: ([String]) throws -> [String: Any] = { try invoke($0, timeout: 45) }) throws {
        guard destination == .cli else { return }
        let result = try run(["prepare-open", "--id", id, "--destination", destination.rawValue])
        guard result["ok"] as? Bool == true, result["safe"] as? Bool == true,
              result["threadId"] as? String == id else {
            throw explorerFailure(result["error"] as? String ?? "This chat cannot be opened safely yet")
        }
    }
    /// Binding only records an exact target. Sending performs the fresh owner
    /// check, so choosing a saved chat does not create a TUI or another writer.
    static func explorerBinding(id: String, load: (String) throws -> Conversation? = {
        try conversation($0)
    }) throws -> Conversation {
        guard let chat = try load(id), chat.id == id else {
            throw explorerFailure("The selected Codex chat is no longer available")
        }
        return chat
    }
    private static func withPrivateRequestFile<T>(_ data: Data, body: (String) throws -> T) throws -> T {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("walkie-codex-request-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: path.path, contents: data,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw explorerFailure("Could not stage the Codex request")
        }
        defer { try? FileManager.default.removeItem(at: path) }
        return try body(path.path)
    }
    private static func explorerFailure(_ message: String) -> NSError {
        NSError(domain: "CodexExplorer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    struct HistoryMessage: Equatable {
        let id: String
        let role: String
        let text: String
        let turnID: String
    }
    struct HistoryPage {
        let messages: [HistoryMessage]
        let nextCursor: String?
    }
    static func historyPage(id: String, cursor: String? = nil) throws -> HistoryPage {
        var arguments = ["history", "--thread", id, "--limit", "30", "--direction", "desc"]
        if let cursor { arguments += ["--cursor", cursor] }
        let row = try invoke(arguments)
        guard row["threadId"] as? String == id else { throw explorerFailure("History returned a different chat") }
        return HistoryPage(messages: historyMessages(row["turns"] as? [[String: Any]] ?? [], newestFirst: true),
                           nextCursor: row["nextCursor"] as? String)
    }
    static func latestHistory(id: String) throws -> [HistoryMessage] {
        let row = try invoke(["latest", "--thread", id])
        guard row["threadId"] as? String == id else { throw explorerFailure("Preview returned a different chat") }
        return latestExchange(historyMessages(row["turns"] as? [[String: Any]] ?? [], newestFirst: true))
    }
    /// Native item types are rendered as readable messages, never raw JSON.
    static func historyMessages(_ turns: [[String: Any]], newestFirst: Bool) -> [HistoryMessage] {
        let ordered = newestFirst ? Array(turns.reversed()) : turns
        return ordered.flatMap { turn -> [HistoryMessage] in
            let turnID = turn["id"] as? String ?? ""
            return (turn["items"] as? [[String: Any]] ?? []).enumerated().compactMap { index, item in
                let type = item["type"] as? String ?? ""
                let role: String
                let text: String
                switch type {
                case "userMessage":
                    role = "You"
                    text = (item["content"] as? [[String: Any]] ?? []).compactMap { part -> String? in
                        switch part["type"] as? String {
                        case "text": return part["text"] as? String
                        case "image", "localImage": return "[Image attachment]"
                        default: return nil
                        }
                    }.joined(separator: "\n")
                case "agentMessage": role = "Codex"; text = item["text"] as? String ?? ""
                case "plan": role = "Plan"; text = item["text"] as? String ?? ""
                case "commandExecution":
                    role = "Command"
                    text = [item["command"] as? String, item["aggregatedOutput"] as? String].compactMap { $0 }.joined(separator: "\n")
                case "fileChange":
                    role = "Files"
                    text = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }.joined(separator: "\n")
                default: return nil
                }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return HistoryMessage(id: item["id"] as? String ?? "\(turnID)-\(index)", role: role, text: text, turnID: turnID)
            }
        }
    }
    static func mergeHistory(_ existing: [HistoryMessage], latest: [HistoryMessage], preserveOlder: Bool) -> [HistoryMessage] {
        guard preserveOlder else { return latest }
        let latestIDs = Set(latest.map(\.id))
        return existing.filter { !latestIDs.contains($0.id) } + latest
    }
    /// The quick preview contains only the latest prompt and its answer. Tool
    /// output and an answer to an older prompt never masquerade as this result.
    static func latestExchange(_ messages: [HistoryMessage]) -> [HistoryMessage] {
        guard let prompt = messages.lastIndex(where: { $0.role == "You" }) else {
            return messages.last(where: { $0.role == "Codex" }).map { [$0] } ?? []
        }
        let answer = messages[(prompt + 1)...].last { $0.role == "Codex" }
        return [messages[prompt]] + (answer.map { [$0] } ?? [])
    }
    /// Search is deliberately scoped to the selected full working directory.
    static func searchConversationIDs(query: String, cwd: String, includeArchived: Bool) throws -> Set<String> {
        var cursor: String?
        var seen: Set<String> = []
        var ids: Set<String> = []
        repeat {
            var arguments = ["catalog-search", "--query", query, "--cwd", cwd, "--limit", "100"]
            if includeArchived { arguments.append("--include-archived") }
            if let cursor { arguments += ["--cursor", cursor] }
            let page = try invoke(arguments)
            for row in page["threads"] as? [[String: Any]] ?? [] {
                if let id = row["session"] as? String ?? row["id"] as? String { ids.insert(id) }
            }
            cursor = page["nextCursor"] as? String
            if let cursor, !seen.insert(cursor).inserted { break }
        } while cursor != nil
        return ids
    }
}


/// The palette's keyboard contract is independent of which AppKit control owns
/// the field editor. Return binds; Command-Return opens without rebinding.
enum CodexQuickAccessAction: Equatable {
    case bind, open
    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, hasMarkedText: Bool) -> Self? {
        guard !hasMarkedText, keyCode == 36 || keyCode == 76 else { return nil }
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        if flags.isEmpty { return .bind }
        return flags == .command ? .open : nil
    }
}

/// Explicit focus avoids AppKit's Full Keyboard Access preference removing
/// palette actions from the Tab loop. Field editors belong to their controls.
enum CodexQuickAccessFocus {
    static func owns(_ view: NSView, responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder === view { return true }
        if let control = view as? NSControl, control.currentEditor() === responder { return true }
        return (responder as? NSTextView)?.delegate === view
    }
    static func next(in views: [NSView], from responder: NSResponder?, reverse: Bool) -> NSView? {
        let available = views.filter { view in
            !view.isHiddenOrHasHiddenAncestor && ((view as? NSControl)?.isEnabled ?? true)
        }
        guard !available.isEmpty else { return nil }
        guard let current = available.firstIndex(where: { owns($0, responder: responder) }) else {
            return reverse ? available.last : available.first
        }
        return available[(current + (reverse ? available.count - 1 : 1)) % available.count]
    }
}

private final class CodexQuickButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled }
}
private final class CodexQuickPopup: NSPopUpButton {
    override var acceptsFirstResponder: Bool { isEnabled }
}

/// Small, nonactivating quick access to exact chat IDs. Cached rows appear
/// immediately; metadata refresh, preview and folder search run off-main.
final class CodexChatPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                             NSSearchFieldDelegate, NSWindowDelegate {
    private var panel: CodexPickerKeyPanel?
    private var retainedPanel: CodexPickerKeyPanel?
    private let search = NSSearchField()
    private let scope = CodexQuickPopup()
    private let archived = CodexQuickButton(checkboxWithTitle: "Archived", target: nil, action: nil)
    private let requestsButton = CodexQuickButton(title: "Requests", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let footer = NSTextField(wrappingLabelWithString: "")
    private let openProgress = NSProgressIndicator()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let preview = NSTextView()
    private let previewScroll = NSScrollView()
    private let openButton = CodexQuickButton(title: "Open ↗ ⌘↩", target: nil, action: nil)
    private let requestStack = NSStackView()
    private let requestScroll = NSScrollView()
    private var requestHeight: NSLayoutConstraint?
    private var all: [CodexBridge.Conversation] = []
    private var visibleConversations: [CodexBridge.Conversation] = []
    private var selectedCWD: String?
    private var nextCursor: String?
    private var hasLoadedContinuation = false
    private var cachedArchived = false
    private var previewID: String?
    private var messages: [CodexBridge.HistoryMessage] = []
    private var reloadGeneration: UInt64 = 0
    private var previewGeneration: UInt64 = 0
    private var searchGeneration: UInt64 = 0
    private var openingGeneration: UInt64 = 0
    private var actionGeneration: UInt64 = 0
    private var searchedIDs: Set<String>?
    private var hasLoadedCatalog = false
    private var loadingCatalog = false
    private var loadingPreview = false
    private var isOpening = false
    private var statusMessage: String?
    private var timer: Timer?
    private var previewWork: DispatchWorkItem?
    private var searchWork: DispatchWorkItem?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var allRequests: [CodexBridge.BackgroundRequest] = []
    private var pendingRequests: [CodexBridge.BackgroundRequest] = []
    private var displayedRequestID: String?
    private var lastVisitedRequestID: String?
    private var requestsMode = false
    private var backgroundStates: [String: String] = [:]
    private var questionInputs: [(String, NSControl)] = []
    private var responding = false
    private var applyingFilter = false
    private var pendingBrowse: (cwd: String?, threadID: String?, query: String?)?

    var onPick: ((CodexBridge.Conversation) -> Void)?
    var onOpen: ((_ session: String, _ cwd: String, _ destination: CodexBridge.OpenDestination,
                  _ stillWanted: @escaping () -> Bool,
                  _ completion: @escaping (String?) -> Void) -> Void)?
    var onResume: ((_ session: String, _ cwd: String) -> Void)?
    var isOpen: Bool { panel != nil }

    static func acceptsResult(expected: UInt64, current: UInt64, panelOpen: Bool) -> Bool {
        panelOpen && expected == current
    }
    static func defaultDestination(client: NewChatClient) -> CodexBridge.OpenDestination {
        client == .cli ? .cli : .desktop
    }
    func show() {
        if panel != nil { close(); return }
        selectedCWD = nil; search.stringValue = ""; archived.state = .off
        if cachedArchived {
            all = all.filter { !$0.archived }; cachedArchived = false
            nextCursor = nil; hasLoadedContinuation = false
        }
        statusMessage = nil; searchedIDs = nil; previewID = nil; messages = []
        requestsMode = false; pendingRequests = []; displayedRequestID = nil
        openingGeneration &+= 1; isOpening = false; responding = false
        let window = retainedPanel ?? buildPanel(); retainedPanel = window; panel = window
        applyingFilter = true; table.deselectAll(nil); applyingFilter = false
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        setPreview("Loading last prompt and answer…")
        renderRequests(); rebuildScope(); applyFilter()
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2,
                y: frame.midY - window.frame.height / 2 + min(100, frame.height / 10)))
        } else { window.center() }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(search)
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak window] event in
            if let window, event.window !== window, !(event.window is NSPanel) { self?.close() }
            return event
        }
        reloadCatalog(); reloadBackground()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.reloadCatalog(); self?.reloadBackground(); self?.loadPreview()
        }
    }
    func close() {
        timer?.invalidate(); timer = nil
        searchWork?.cancel(); previewWork?.cancel()
        searchWork = nil; previewWork = nil
        reloadGeneration &+= 1; previewGeneration &+= 1; searchGeneration &+= 1; openingGeneration &+= 1
        actionGeneration &+= 1
        loadingCatalog = false; loadingPreview = false; isOpening = false; pendingBrowse = nil
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor); self.globalClickMonitor = nil }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor); self.localClickMonitor = nil }
        panel?.orderOut(nil); panel = nil
    }
    func windowWillClose(_ notification: Notification) { close() }

    private func buildPanel() -> CodexPickerKeyPanel {
        let window = CodexPickerKeyPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 520),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Find Codex Chat"; window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = true; window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.level = .floating; window.delegate = self
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.onNavigationKey = { [weak self, weak window] event in
            guard let self, let window, self.panel === window else { return false }
            return self.handleKey(event, window: window)
        }
        let content = NSVisualEffectView()
        content.material = .menu; content.state = .active; content.blendingMode = .behindWindow
        content.wantsLayer = true; content.layer?.cornerRadius = 14; content.layer?.masksToBounds = true
        window.contentView = content
        search.delegate = self; search.placeholderString = "Find a chat…"
        search.font = .systemFont(ofSize: 17); search.focusRingType = .none
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Find a chat")
        scope.target = self; scope.action = #selector(scopeChanged)
        scope.controlSize = .small; scope.font = .systemFont(ofSize: 11)
        scope.setAccessibilityLabel("Folder filter, Command L")
        archived.target = self; archived.action = #selector(archiveChanged)
        archived.controlSize = .small; archived.font = .systemFont(ofSize: 11)
        archived.toolTip = "Include archived chats · ⇧⌘A"
        requestsButton.target = self; requestsButton.action = #selector(showNextRequest)
        requestsButton.controlSize = .small; requestsButton.bezelStyle = .inline
        requestsButton.toolTip = "Review pending requests · ⌘R"
        countLabel.font = .systemFont(ofSize: 11); countLabel.textColor = .secondaryLabelColor
        let scopeRow = NSStackView(views: [scope, countLabel, archived, requestsButton]); scopeRow.spacing = 10
        table.tableColumns.forEach(table.removeTableColumn)
        table.addTableColumn(NSTableColumn(identifier: .init("chat")))
        table.headerView = nil; table.rowHeight = 50; table.intercellSpacing = .zero
        table.delegate = self; table.dataSource = self; table.target = self
        table.doubleAction = #selector(bindSelected); table.action = nil
        table.backgroundColor = .clear; table.focusRingType = .none
        table.selectionHighlightStyle = .regular; table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Recent chats, Return to bind, Command Return to open")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        preview.isEditable = false; preview.isSelectable = true; preview.drawsBackground = false
        preview.font = .systemFont(ofSize: 12); preview.textColor = .secondaryLabelColor
        preview.textContainerInset = NSSize(width: 4, height: 5)
        preview.isHorizontallyResizable = false; preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true
        preview.setAccessibilityLabel("Last prompt and answer")
        previewScroll.documentView = preview; previewScroll.hasVerticalScroller = true; previewScroll.drawsBackground = false
        requestStack.orientation = .vertical; requestStack.alignment = .leading; requestStack.spacing = 8
        requestScroll.documentView = requestStack; requestScroll.hasVerticalScroller = true; requestScroll.drawsBackground = false
        requestStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            requestStack.widthAnchor.constraint(equalTo: requestScroll.contentView.widthAnchor),
            requestStack.topAnchor.constraint(equalTo: requestScroll.contentView.topAnchor),
            requestStack.leadingAnchor.constraint(equalTo: requestScroll.contentView.leadingAnchor)
        ])
        requestHeight = requestScroll.heightAnchor.constraint(equalToConstant: 0); requestHeight?.isActive = true
        openButton.target = self; openButton.action = #selector(openSelected)
        openButton.bezelStyle = .inline; openButton.controlSize = .small
        openProgress.style = .spinning; openProgress.controlSize = .small
        openProgress.isDisplayedWhenStopped = false
        footer.font = .systemFont(ofSize: 11); footer.textColor = .secondaryLabelColor
        footer.maximumNumberOfLines = 2
        let bottom = NSStackView(views: [openProgress, footer, openButton]); bottom.spacing = 8
        let divider = NSBox(); divider.boxType = .separator
        for view in [search, scopeRow, scroll, divider, previewScroll, requestScroll, bottom] {
            view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), search.heightAnchor.constraint(equalToConstant: 30),
            scopeRow.leadingAnchor.constraint(equalTo: search.leadingAnchor), scopeRow.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            scopeRow.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 9), scopeRow.heightAnchor.constraint(equalToConstant: 24),
            scope.widthAnchor.constraint(lessThanOrEqualToConstant: 330),
            scroll.topAnchor.constraint(equalTo: scopeRow.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            divider.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            divider.leadingAnchor.constraint(equalTo: search.leadingAnchor), divider.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            previewScroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 6),
            previewScroll.leadingAnchor.constraint(equalTo: search.leadingAnchor), previewScroll.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            previewScroll.heightAnchor.constraint(equalToConstant: 112),
            requestScroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 6),
            requestScroll.leadingAnchor.constraint(equalTo: search.leadingAnchor), requestScroll.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: previewScroll.bottomAnchor, constant: 7),
            bottom.leadingAnchor.constraint(equalTo: search.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -11), bottom.heightAnchor.constraint(equalToConstant: 28),
            openButton.widthAnchor.constraint(equalToConstant: 98),
            openProgress.widthAnchor.constraint(equalToConstant: 16), openProgress.heightAnchor.constraint(equalToConstant: 16)
        ])
        for control in [scope, archived, requestsButton, openButton] as [NSControl] {
            control.refusesFirstResponder = false
        }
        search.nextKeyView = scope; scope.nextKeyView = archived
        archived.nextKeyView = requestsButton; requestsButton.nextKeyView = table
        table.nextKeyView = preview; preview.nextKeyView = openButton; openButton.nextKeyView = search
        window.initialFirstResponder = search
        return window
    }
    private func handleKey(_ event: NSEvent, window: NSWindow) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 { if requestsMode { hideRequests() } else { close() }; return true }
        if modifiers == .command {
            switch event.keyCode {
            case 3: window.makeFirstResponder(search); return true // F
            case 37: window.makeFirstResponder(scope); scope.performClick(nil); return true // L
            case 15: showNextRequest(); return true // R
            default: break
            }
        }
        if modifiers == [.command, .shift], event.keyCode == 0 {
            archived.state = archived.state == .on ? .off : .on; archiveChanged(); return true
        }
        let responder = window.firstResponder
        let searching = CodexQuickAccessFocus.owns(search, responder: responder)
        let browsing = searching || responder === table
        let markedText = (responder as? NSTextView)?.hasMarkedText() == true
        if event.keyCode == 48, !markedText, modifiers.isEmpty || modifiers == .shift {
            moveFocus(in: window, reverse: modifiers == .shift)
            return true
        }
        if !markedText, modifiers.isEmpty, [UInt16(36), 76, 49].contains(event.keyCode),
           let button = responder as? NSButton, button.isEnabled {
            button.performClick(nil); return true
        }
        if let action = CodexQuickAccessAction.action(keyCode: event.keyCode, modifiers: modifiers,
                hasMarkedText: (responder as? NSTextView)?.hasMarkedText() == true),
           !requestsMode, browsing || action == .open {
            if action == .bind { bindSelected() } else { openSelected() }; return true
        }
        if browsing, let command = CodexPickerNavigationCommand.command(keyCode: event.keyCode,
                modifiers: modifiers, hasMarkedText: (responder as? NSTextView)?.hasMarkedText() == true) {
            switch command {
            case .move(let delta): moveSelection(delta)
            case .page(let delta): moveSelection(delta * 5)
            case .activate: bindSelected()
            case .back: close()
            }; return true
        }
        // Clicking a row should not strand subsequent typing in table type-select.
        if responder === table, modifiers.isEmpty, let text = event.characters,
           !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            window.makeFirstResponder(search); window.sendEvent(event); return true
        }
        return false
    }
    private var requestControls: [NSControl] {
        requestStack.arrangedSubviews.compactMap { $0 as? NSControl }.filter {
            !($0 is NSTextField) || ($0 as? NSTextField)?.isEditable == true
        }
    }
    private func moveFocus(in window: NSWindow, reverse: Bool) {
        var ring: [NSView] = [search, scope, archived, requestsButton]
        ring += requestsMode ? requestControls.map { $0 as NSView } : [table, preview]
        ring.append(openButton)
        var responder = window.firstResponder
        // A disabled or temporarily unavailable control is skipped, never
        // allowed to leak Tab into the previously focused application.
        for _ in 0..<ring.count {
            guard let next = CodexQuickAccessFocus.next(in: ring, from: responder, reverse: reverse) else { return }
            if window.makeFirstResponder(next) {
                next.scrollToVisible(next.bounds)
                return
            }
            responder = next
        }
    }

    @objc private func archiveChanged() {
        cancelPendingOpen()
        reloadGeneration &+= 1; loadingCatalog = false; nextCursor = nil
        hasLoadedContinuation = false
        all = []; hasLoadedCatalog = false; searchedIDs = nil
        reloadCatalog(); applyFilter(); runSearch()
    }
    @objc private func scopeChanged() {
        cancelPendingOpen()
        selectedCWD = scope.selectedItem?.representedObject as? String
        searchedIDs = nil; statusMessage = nil; applyFilter(); runSearch(); panel?.makeFirstResponder(search)
    }
    private func rebuildScope() {
        scope.removeAllItems(); scope.addItem(withTitle: "All folders")
        for cwd in Set(all.map(\.cwd)).sorted() {
            scope.addItem(withTitle: cwd.isEmpty ? "No recorded folder" : (cwd as NSString).abbreviatingWithTildeInPath)
            scope.lastItem?.representedObject = cwd; scope.lastItem?.toolTip = cwd
        }
        scope.selectItem(at: selectedCWD.flatMap { cwd in scope.itemArray.firstIndex { $0.representedObject as? String == cwd } } ?? 0)
    }
    private func reloadCatalog(continuing: Bool = false) {
        guard panel != nil, !loadingCatalog else { return }
        if continuing && nextCursor == nil { return }
        loadingCatalog = true; reloadGeneration &+= 1
        let generation = reloadGeneration, includeArchived = archived.state == .on
        let cursor = continuing ? nextCursor : nil
        chrome()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try CodexBridge.conversationPage(limit: 100, cursor: cursor, includeArchived: includeArchived, quickOnly: true) }
            DispatchQueue.main.async {
                guard let self, Self.acceptsResult(expected: generation, current: self.reloadGeneration, panelOpen: self.panel != nil) else { return }
                self.loadingCatalog = false
                switch result {
                case .success(let page):
                    let selected = self.selectedChat?.id
                    let ids = Set(page.conversations.map(\.id))
                    let previous = self.all
                    if continuing { self.all += page.conversations.filter { chat in !self.all.contains { $0.id == chat.id } } }
                    else { self.all = page.conversations + self.all.filter { !ids.contains($0.id) && (includeArchived || !$0.archived) } }
                    if continuing || !self.hasLoadedContinuation { self.nextCursor = page.nextCursor }
                    if continuing { self.hasLoadedContinuation = true }
                    self.cachedArchived = includeArchived; self.hasLoadedCatalog = true
                    if self.all != previous { self.rebuildScope(); self.applyFilter(preferredID: selected) }
                    else {
                        if self.visibleConversations.isEmpty { self.setPreview("No matching chats.") }
                        self.chrome()
                    }
                    self.applyPendingBrowse()
                case .failure(let error): self.statusMessage = "Could not refresh chats: \(error.localizedDescription)"; self.chrome()
                }
            }
        }
    }
    private func reloadBackground() {
        let generation = openingGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let background = try? CodexBridge.backgroundStatus() else { return }
            DispatchQueue.main.async {
                guard let self, Self.acceptsResult(expected: generation, current: self.openingGeneration, panelOpen: self.panel != nil) else { return }
                self.allRequests = background.requests
                let previous = self.backgroundStates
                self.backgroundStates = Dictionary(background.threads.map { ($0.id, $0.state) }, uniquingKeysWith: { _, new in new })
                if self.requestsMode {
                    self.pendingRequests = background.requests.filter { request in self.displayedRequestID == request.id }
                    if self.pendingRequests.isEmpty { self.hideRequests() } else { self.renderRequests() }
                }
                let changed = IndexSet(self.visibleConversations.indices.filter {
                    previous[self.visibleConversations[$0].id] != self.backgroundStates[self.visibleConversations[$0].id]
                })
                if !changed.isEmpty { self.table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
                self.chrome()
            }
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        cancelPendingOpen()
        statusMessage = nil; searchedIDs = nil; applyFilter(); runSearch()
    }
    private func runSearch() {
        searchWork?.cancel(); searchGeneration &+= 1
        guard let cwd = selectedCWD else { return }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searchedIDs = nil; applyFilter(); return }
        let generation = searchGeneration, includeArchived = archived.state == .on
        let knownIDs = Set(all.map(\.id))
        let work = DispatchWorkItem { [weak self] in
            let result = Result { () throws -> (Set<String>, [CodexBridge.Conversation]) in
                let ids = try CodexBridge.searchConversationIDs(query: query, cwd: cwd, includeArchived: includeArchived)
                let missing = ids.subtracting(knownIDs).sorted().compactMap { try? CodexBridge.conversation($0) }
                return (ids, missing)
            }
            DispatchQueue.main.async {
                guard let self, Self.acceptsResult(expected: generation, current: self.searchGeneration, panelOpen: self.panel != nil),
                      self.selectedCWD == cwd, self.search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                switch result {
                case .success(let (ids, missing)):
                    self.searchedIDs = ids
                    self.all += missing.filter { chat in chat.cwd == cwd && !self.all.contains { $0.id == chat.id } }
                    self.applyFilter(preferredID: self.selectedChat?.id)
                case .failure(let error): self.statusMessage = "Message search unavailable: \(error.localizedDescription)"; self.chrome()
                }
            }
        }
        searchWork = work; DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    private func applyFilter(preferredID: String? = nil) {
        let previous = preferredID ?? selectedChat?.id
        let terms = search.stringValue.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        visibleConversations = all.filter { chat in
            guard selectedCWD == nil || chat.cwd == selectedCWD else { return false }
            guard archived.state == .on || !chat.archived else { return false }
            let haystack = (chat.title + " " + chat.cwd).lowercased()
            return terms.isEmpty || terms.allSatisfy(haystack.contains) || (selectedCWD != nil && searchedIDs?.contains(chat.id) == true)
        }
        applyingFilter = true; table.reloadData(); table.deselectAll(nil)
        if !visibleConversations.isEmpty {
            let index = previous.flatMap { id in visibleConversations.firstIndex { $0.id == id } } ?? 0
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        applyingFilter = false; selectionChanged(); chrome()
    }
    private var selectedChat: CodexBridge.Conversation? {
        visibleConversations.indices.contains(table.selectedRow) ? visibleConversations[table.selectedRow] : nil
    }
    private func moveSelection(_ delta: Int) {
        guard !visibleConversations.isEmpty else { return }
        let next = max(0, min(visibleConversations.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false); table.scrollRowToVisible(next)
        if next >= visibleConversations.count - 5 { reloadCatalog(continuing: true) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visibleConversations.count }
    func tableViewSelectionDidChange(_ notification: Notification) { if !applyingFilter { selectionChanged(userInitiated: true) } }
    private func selectionChanged(userInitiated: Bool = false) {
        if requestsMode && userInitiated { hideRequests() }
        if selectedChat?.id != previewID {
            cancelPendingOpen()
            previewWork?.cancel(); previewGeneration &+= 1; loadingPreview = false
            previewID = selectedChat?.id; messages = []
            setPreview(previewID == nil ? (hasLoadedCatalog ? "No matching chats." : "Loading recent chats…") : "Loading last prompt and answer…")
            let generation = previewGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.previewGeneration == generation else { return }; self.loadPreview()
            }
            previewWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
        chrome()
    }
    private func loadPreview() {
        guard let id = previewID, panel != nil, !loadingPreview else { return }
        loadingPreview = true
        let generation = previewGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try CodexBridge.latestHistory(id: id) }
            DispatchQueue.main.async {
                guard let self, Self.acceptsResult(expected: generation, current: self.previewGeneration, panelOpen: self.panel != nil), self.previewID == id else { return }
                self.loadingPreview = false
                switch result {
                case .success(let messages):
                    self.messages = messages
                    self.renderMessages()
                case .failure: self.setPreview("Last prompt and answer unavailable.")
                }
            }
        }
    }
    private func renderMessages() {
        let text = NSMutableAttributedString(string: "")
        for (index, message) in messages.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n\n")) }
            text.append(NSAttributedString(string: message.role + "  ", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]))
            // Bound the preview's display work; the full result belongs in Codex.
            text.append(NSAttributedString(string: String(message.text.prefix(6000)), attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
        }
        if messages.isEmpty { setPreview("No prompt or answer yet.") }
        else if preview.string != text.string { preview.textStorage?.setAttributedString(text); preview.scrollToBeginningOfDocument(nil) }
    }
    private func setPreview(_ text: String) {
        preview.textStorage?.setAttributedString(NSAttributedString(string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
    }
    @objc private func bindSelected() {
        guard !requestsMode, !isOpening, let chat = selectedChat, let onPick else { return }
        onPick(chat); close()
    }
    @objc private func openSelected() {
        guard !requestsMode, !isOpening, let chat = selectedChat, let onOpen else { return }
        isOpening = true; statusMessage = nil; chrome()
        let generation = openingGeneration
        actionGeneration &+= 1
        let token = actionGeneration
        let destination = Self.defaultDestination(client: NewChatClient.preferred())
        onOpen(chat.id, chat.cwd, destination, { [weak self] in
            guard let self else { return false }
            return Self.acceptsResult(expected: token, current: self.actionGeneration, panelOpen: self.panel != nil)
                && self.openingGeneration == generation && self.isOpening && self.selectedChat?.id == chat.id
        }) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, Self.acceptsResult(expected: token, current: self.actionGeneration, panelOpen: self.panel != nil), self.openingGeneration == generation else { return }
                self.isOpening = false
                if let error { self.statusMessage = error; self.chrome() }
                else { self.close() }
            }
        }
    }
    private func cancelPendingOpen() {
        actionGeneration &+= 1; isOpening = false
        openProgress.stopAnimation(nil)
    }
    @objc private func showNextRequest() {
        guard !allRequests.isEmpty else { return }
        cancelPendingOpen()
        let index = lastVisitedRequestID.flatMap { id in allRequests.firstIndex { $0.id == id } }
            .map { ($0 + 1) % allRequests.count } ?? 0
        let request = allRequests[index]; lastVisitedRequestID = request.id
        requestsMode = true; pendingRequests = [request]; displayedRequestID = nil; statusMessage = nil
        renderRequests(); chrome()
        if let first = requestControls.first {
            panel?.makeFirstResponder(first); first.scrollToVisible(first.bounds)
        } else { panel?.makeFirstResponder(search) }
    }
    private func hideRequests() {
        requestsMode = false; pendingRequests = []; displayedRequestID = nil
        requestsButton.nextKeyView = table
        renderRequests(); chrome(); panel?.makeFirstResponder(search)
    }
    private func clearRequestViews() {
        requestStack.arrangedSubviews.forEach { requestStack.removeArrangedSubview($0); $0.removeFromSuperview() }
    }
    private func renderRequests() {
        requestScroll.isHidden = !requestsMode; previewScroll.isHidden = requestsMode
        requestHeight?.constant = requestsMode ? 112 : 0
        if !requestsMode {
            requestsButton.nextKeyView = table
            displayedRequestID = nil; questionInputs = []; clearRequestViews()
            return
        }
        guard pendingRequests.first?.id != displayedRequestID || requestStack.arrangedSubviews.isEmpty else { return }
        displayedRequestID = pendingRequests.first?.id; questionInputs = []; clearRequestViews()
        guard requestsMode, let request = pendingRequests.first else { return }
        let title = NSTextField(wrappingLabelWithString: request.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold); requestStack.addArrangedSubview(title)
        title.widthAnchor.constraint(equalTo: requestStack.widthAnchor).isActive = true
        if !request.detail.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: request.detail)
            detail.font = .systemFont(ofSize: 12); detail.isSelectable = true
            requestStack.addArrangedSubview(detail); detail.widthAnchor.constraint(equalTo: requestStack.widthAnchor).isActive = true
        }
        if request.kind == "questions" {
            for question in request.questions {
                let label = NSTextField(wrappingLabelWithString: question.title)
                label.font = .systemFont(ofSize: 12); requestStack.addArrangedSubview(label)
                label.widthAnchor.constraint(equalTo: requestStack.widthAnchor).isActive = true
                if !question.options.isEmpty {
                    let options = CodexQuickPopup(); options.addItems(withTitles: ["Choose an answer…"] + question.options)
                    requestStack.addArrangedSubview(options); questionInputs.append((question.id, options))
                }
                let field: NSTextField = question.secret ? NSSecureTextField() : NSTextField()
                field.placeholderString = question.options.isEmpty ? "Your answer" : "Or enter your own answer"
                field.setAccessibilityLabel(question.title)
                requestStack.addArrangedSubview(field); field.widthAnchor.constraint(equalTo: requestStack.widthAnchor).isActive = true
                questionInputs.append((question.id, field))
            }
            requestStack.addArrangedSubview(CodexQuickButton(title: "Send Answers", target: self, action: #selector(answerQuestions)))
        } else if !request.choices.isEmpty {
            for (index, choice) in request.choices.enumerated() {
                let button = CodexQuickButton(title: choice.label, target: self, action: #selector(answerChoice(_:)))
                button.tag = index; requestStack.addArrangedSubview(button)
            }
        } else {
            let label = NSTextField(wrappingLabelWithString: "This request needs a Codex capability Walkie cannot display yet. It remains paused.")
            label.font = .systemFont(ofSize: 12); requestStack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: requestStack.widthAnchor).isActive = true
        }
        for (index, control) in requestControls.enumerated() {
            control.refusesFirstResponder = false
            control.nextKeyView = index + 1 < requestControls.count ? requestControls[index + 1] : search
        }
        if let first = requestControls.first { requestsButton.nextKeyView = first }
        panel?.recalculateKeyViewLoop()
    }
    @objc private func answerChoice(_ sender: NSButton) {
        guard let request = pendingRequests.first, request.choices.indices.contains(sender.tag) else { return }
        respond(request, response: request.choices[sender.tag].response)
    }
    @objc private func answerQuestions() {
        guard let request = pendingRequests.first else { return }
        var values: [String: String] = [:]
        for (id, input) in questionInputs {
            if let options = input as? NSPopUpButton, options.indexOfSelectedItem > 0 { values[id] = options.titleOfSelectedItem }
            if let field = input as? NSTextField, !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { values[id] = field.stringValue }
        }
        guard request.questions.allSatisfy({ values[$0.id] != nil }) else { statusMessage = "Answer each question before sending."; chrome(); return }
        respond(request, response: ["answers": values.mapValues { ["answers": [$0]] }])
    }
    private func respond(_ request: CodexBridge.BackgroundRequest, response: [String: Any]) {
        guard !responding else { return }; responding = true; chrome()
        let generation = openingGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try CodexBridge.respondBackground(requestID: request.id, response: response) }
            DispatchQueue.main.async {
                guard let self, Self.acceptsResult(expected: generation, current: self.openingGeneration, panelOpen: self.panel != nil) else { return }
                self.responding = false
                switch result {
                case .success:
                    self.allRequests.removeAll { $0.id == request.id }; self.hideRequests(); self.statusMessage = "Response sent."
                case .failure(let error): self.statusMessage = "Could not send response: \(error.localizedDescription)"
                }; self.chrome()
            }
        }
    }
    private func chrome() {
        requestsButton.title = "Requests (\(allRequests.count))"; requestsButton.isHidden = allRequests.isEmpty
        requestsButton.isEnabled = !responding
        search.placeholderString = selectedCWD == nil ? "Find a chat by title or folder…" : "Search prompts and answers in this folder…"
        countLabel.stringValue = loadingCatalog && !hasLoadedCatalog ? "Loading…" : "\(visibleConversations.count) chats"
        let destination = Self.defaultDestination(client: NewChatClient.preferred())
        openButton.isEnabled = selectedChat != nil && !isOpening && !requestsMode
        if isOpening { openProgress.startAnimation(nil) } else { openProgress.stopAnimation(nil) }
        openButton.toolTip = "Open in \(destination == .desktop ? "Codex Desktop" : "Terminal") · ⌘↩"
        footer.stringValue = statusMessage ?? (isOpening
            ? (destination == .desktop ? "Opening in Codex… · Esc cancels" : "Opening in Terminal… · Esc cancels")
            : requestsMode ? "Tab through choices · ⌘R next request · Esc back" : "↑↓ select   ↩ bind   ⌘↩ open   ⌘L folder   Esc close")
        footer.textColor = statusMessage == nil ? .secondaryLabelColor : .labelColor
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleConversations.indices.contains(row) else { return nil }
        let chat = visibleConversations[row]
        let identifier = NSUserInterfaceItemIdentifier("quick-chat")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        let label: NSTextField
        if let existing = cell.textField { label = existing }
        else {
            label = NSTextField(wrappingLabelWithString: ""); label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label); cell.textField = label
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        let state = backgroundStates[chat.id] ?? chat.status
        let activity = state == "waitingOnApproval" ? "Approval needed · " : state == "waitingOnUserInput" ? "Answer needed · " : state == "active" || chat.busy ? "Working · " : ""
        let folder = chat.cwd.isEmpty ? "No recorded folder" : (chat.cwd as NSString).abbreviatingWithTildeInPath
        let subtitle = activity + folder + (chat.archived ? " · Archived" : "")
        let value = NSMutableAttributedString(string: chat.title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor])
        value.append(NSAttributedString(string: subtitle, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        label.attributedStringValue = value; label.maximumNumberOfLines = 2; label.lineBreakMode = .byTruncatingMiddle
        cell.toolTip = chat.cwd; cell.setAccessibilityLabel(chat.title + ", " + subtitle)
        return cell
    }
    func testBrowse(cwd: String? = nil, threadID: String? = nil, query: String? = nil) {
        guard Thread.isMainThread else { return }
        if panel == nil { show() }
        pendingBrowse = (cwd, threadID, query); applyPendingBrowse()
    }
    private func applyPendingBrowse() {
        guard let browse = pendingBrowse else { return }
        let chat = browse.threadID.flatMap { id in all.first { $0.id == id } }
        if browse.threadID != nil, chat == nil { return }
        pendingBrowse = nil; selectedCWD = browse.cwd ?? chat?.cwd; search.stringValue = browse.query ?? ""
        searchedIDs = nil; rebuildScope(); applyFilter(preferredID: browse.threadID); runSearch()
    }
    func testState(snapshot: Bool = false) -> [String: Any] {
        var state: [String: Any] = ["open": panel?.isVisible == true, "mode": requestsMode ? "requests" : "chats",
            "query": search.stringValue, "rowCount": visibleConversations.count, "cached": hasLoadedCatalog,
            "loading": loadingCatalog, "checking": isOpening, "selectedChatID": selectedChat?.id as Any? ?? NSNull(),
            "selectedProjectCWD": selectedCWD as Any? ?? NSNull(), "previewMessageCount": messages.count,
            "requestCount": pendingRequests.count, "includeArchived": archived.state == .on,
            "style": "quickAccess", "defaultDestination": Self.defaultDestination(client: NewChatClient.preferred()).rawValue]
        if let statusMessage { state["statusMessage"] = statusMessage }
        if let panel { state["frame"] = ["x": panel.frame.minX, "y": panel.frame.minY, "w": panel.frame.width, "h": panel.frame.height] }
        if snapshot, let content = panel?.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                let url = Outbox.cacheRoot.appendingPathComponent("codex-picker-test.png")
                do { try FileManager.default.createDirectory(at: Outbox.cacheRoot, withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic); state["snapshotPath"] = url.path
                } catch { state["snapshotError"] = error.localizedDescription }
            }
        }
        return state
    }
}
