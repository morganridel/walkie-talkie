import XCTest
import AppKit
@testable import WalkieTalkie

final class CodexExplorerTests: XCTestCase {
    func testDesktopHistoryOpenNeverCallsWriterPreflight() throws {
        try CodexBridge.prepareOpen(id: "externally-running-chat", destination: .desktop) { _ in
            XCTFail("Viewing Desktop history must not probe, release, or acquire its writer")
            throw NSError(domain: "ExternalWriter", code: 1)
        }
    }
    func testCLIAttachmentStillChecksExactOwnerAndPropagatesRefusal() throws {
        var calls = [[String]]()
        try CodexBridge.prepareOpen(id: "exact-chat", destination: .cli) { arguments in
            calls.append(arguments)
            return ["ok": true, "safe": true, "threadId": "exact-chat"]
        }
        XCTAssertEqual(calls, [["prepare-open", "--id", "exact-chat", "--destination", "cli"]])
        XCTAssertThrowsError(try CodexBridge.prepareOpen(id: "exact-chat", destination: .cli) { _ in
            ["ok": true, "safe": true, "threadId": "different-chat"]
        })
        XCTAssertThrowsError(try CodexBridge.prepareOpen(id: "exact-chat", destination: .cli) { _ in
            throw NSError(domain: "ExternalWriter", code: 42)
        }) { error in XCTAssertEqual((error as NSError).code, 42) }
    }
    func testQuickAccessReturnBindsAndCommandReturnOpens() {
        XCTAssertEqual(CodexQuickAccessAction.action(keyCode: 36, modifiers: [], hasMarkedText: false), .bind)
        XCTAssertEqual(CodexQuickAccessAction.action(keyCode: 76, modifiers: .command, hasMarkedText: false), .open)
        XCTAssertNil(CodexQuickAccessAction.action(keyCode: 36, modifiers: .option, hasMarkedText: false))
        XCTAssertNil(CodexQuickAccessAction.action(keyCode: 36, modifiers: [.command, .shift], hasMarkedText: false))
        XCTAssertNil(CodexQuickAccessAction.action(keyCode: 36, modifiers: [], hasMarkedText: true))
    }
    func testQuickAccessDestinationFollowsTerminalPreference() {
        XCTAssertEqual(CodexChatPicker.defaultDestination(client: .background), .desktop)
        XCTAssertEqual(CodexChatPicker.defaultDestination(client: .cli), .cli)
    }
    func testFocusRingSkipsUnavailableActionsAndWrapsInBothDirections() {
        let search = NSSearchField()
        let disabled = NSButton(); disabled.isEnabled = false
        let hidden = NSButton(); hidden.isHidden = true
        let table = NSTableView()
        let open = NSButton()
        let views: [NSView] = [search, disabled, hidden, table, open]
        XCTAssertTrue(CodexQuickAccessFocus.next(in: views, from: search, reverse: false) === table)
        XCTAssertTrue(CodexQuickAccessFocus.next(in: views, from: table, reverse: true) === search)
        XCTAssertTrue(CodexQuickAccessFocus.next(in: views, from: open, reverse: false) === search)
        XCTAssertTrue(CodexQuickAccessFocus.next(in: views, from: search, reverse: true) === open)
    }
    func testFocusRingTreatsSearchFieldEditorAsSearchControl() throws {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let search = NSSearchField(frame: NSRect(x: 0, y: 50, width: 200, height: 25))
        let next = NSButton()
        panel.contentView?.addSubview(search)
        panel.contentView?.addSubview(next)
        XCTAssertTrue(panel.makeFirstResponder(search))
        let editor = try XCTUnwrap(search.currentEditor())
        XCTAssertTrue(CodexQuickAccessFocus.owns(search, responder: editor))
        XCTAssertTrue(CodexQuickAccessFocus.next(in: [search, next], from: editor, reverse: false) === next)
        panel.makeFirstResponder(nil)
    }
    func testQuickAccessIgnoresResultsFromClosedOrPreviousOpening() {
        XCTAssertTrue(CodexChatPicker.acceptsResult(expected: 4, current: 4, panelOpen: true))
        XCTAssertFalse(CodexChatPicker.acceptsResult(expected: 4, current: 5, panelOpen: true))
        XCTAssertFalse(CodexChatPicker.acceptsResult(expected: 4, current: 4, panelOpen: false))
    }
    func testPreviewContainsOnlyLastPromptAndFinalAnswer() {
        let messages = [
            CodexBridge.HistoryMessage(id: "old-u", role: "You", text: "Old prompt", turnID: "old"),
            CodexBridge.HistoryMessage(id: "old-a", role: "Codex", text: "Old answer", turnID: "old"),
            CodexBridge.HistoryMessage(id: "new-u", role: "You", text: "New prompt", turnID: "new"),
            CodexBridge.HistoryMessage(id: "progress", role: "Codex", text: "Checking…", turnID: "new"),
            CodexBridge.HistoryMessage(id: "tool", role: "Command", text: "tool output", turnID: "new"),
            CodexBridge.HistoryMessage(id: "new-a", role: "Codex", text: "Final answer", turnID: "new"),
        ]
        XCTAssertEqual(CodexBridge.latestExchange(messages).map(\.id), ["new-u", "new-a"])
        XCTAssertEqual(CodexBridge.latestExchange(Array(messages.prefix(3))).map(\.id), ["new-u"])
        XCTAssertEqual(CodexBridge.latestExchange([]), [])
    }
    func testSavedChatCanBeBoundWithoutResumingOrChangingItsID() throws {
        let saved = CodexBridge.Conversation(["id": "saved", "cwd": "/project", "live": false])!
        var lookup: String?
        let bound = try CodexBridge.explorerBinding(id: "saved") { id in lookup = id; return saved }
        XCTAssertEqual(lookup, "saved")
        XCTAssertEqual(bound.id, "saved")
        XCTAssertEqual(bound.handle, .codex(threadID: "saved", tty: nil))
    }
    func testBindingRefusesMissingOrWrongChat() {
        XCTAssertThrowsError(try CodexBridge.explorerBinding(id: "a", load: { _ in nil }))
        XCTAssertThrowsError(try CodexBridge.explorerBinding(id: "a", load: { _ in
            CodexBridge.Conversation(["id": "b"])
        }))
    }
    func testTranscriptOrdersNewestFirstTurnsChronologicallyWithoutDumpingMetadata() {
        let messages = CodexBridge.historyMessages([
            ["id": "new", "items": [["id": "a2", "type": "agentMessage", "text": "Latest answer"],
                                      ["id": "internal", "type": "reasoning", "private": "internal details"]]],
            ["id": "old", "items": [["id": "u", "type": "userMessage", "content": [
                ["type": "text", "text": "Explain this"], ["type": "localImage", "path": "/private/file"]]],
                ["id": "a", "type": "agentMessage", "text": "First answer"]]],
        ], newestFirst: true)
        XCTAssertEqual(messages.map(\.id), ["u", "a", "a2"])
        XCTAssertEqual(messages.map(\.role), ["You", "Codex", "Codex"])
        XCTAssertEqual(messages.first?.text, "Explain this\n[Image attachment]")
        XCTAssertFalse(messages.map(\.text).joined().contains("internal details"))
        XCTAssertFalse(messages.map(\.text).joined().contains("/private/file"))
    }
    func testPendingRequestKeepsNativeChoicePayloadAndSecretQuestion() throws {
        let status = CodexBridge.BackgroundStatus([
            "threads": [["threadId": "a", "state": "waitingOnApproval", "busy": false]],
            "requests": [["id": "r", "threadId": "a", "kind": "approval", "choices": [
                ["id": "approve", "label": "Approve Once", "response": ["decision": "accept"]]
            ]], ["id": "q", "threadId": "a", "kind": "questions", "questions": [
                ["id": "secret", "question": "Token", "isSecret": true,
                 "options": [["label": "One"], ["label": "Two"]]]
            ]]],
            "completions": [["id": "event", "threadId": "a", "timestamp": 17.5, "status": "completed"]],
        ])
        XCTAssertEqual(status.threads.first?.state, "waitingOnApproval")
        XCTAssertEqual(status.requests.first?.choices.first?.response["decision"] as? String, "accept")
        XCTAssertEqual(status.requests.last?.questions.first?.options, ["One", "Two"])
        XCTAssertEqual(status.requests.last?.questions.first?.secret, true)
        XCTAssertEqual(status.completions.first?.threadID, "a")
    }
    func testBackgroundConversationIsNotMislabelledAsDesktopOrTerminal() {
        let chat = CodexBridge.Conversation(["id": "a", "live": true, "background": true,
                                             "busy": true, "tty": "codex:a", "ttyOwner": false])!
        XCTAssertEqual(chat.locationLabel, "Background · working")
        XCTAssertNil(chat.terminalTTY)
    }
    func testAccountLevelRequestRemainsReviewableWithoutThreadMetadata() {
        let request = CodexBridge.BackgroundRequest(["id": "account-request", "kind": "approval",
            "title": "Allow account access", "choices": [["id": "deny", "label": "Deny", "response": ["decision": "decline"]]]])
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.threadID, "")
        XCTAssertEqual(request?.choices.first?.label, "Deny")
    }
    func testRefreshingLatestHistoryRetainsExplicitlyLoadedOlderMessagesEvenWhenLatestGrows() {
        let old = CodexBridge.HistoryMessage(id: "old", role: "You", text: "Older prompt", turnID: "t1")
        let before = CodexBridge.HistoryMessage(id: "stream", role: "Codex", text: "Partial", turnID: "t2")
        let updated = CodexBridge.HistoryMessage(id: "stream", role: "Codex", text: "Complete", turnID: "t2")
        let newest = CodexBridge.HistoryMessage(id: "new", role: "Codex", text: "Latest", turnID: "t3")
        let result = CodexBridge.mergeHistory([old, before], latest: [updated, newest], preserveOlder: true)
        XCTAssertEqual(result.map(\.id), ["old", "stream", "new"])
        XCTAssertEqual(result[1].text, "Complete")
        XCTAssertEqual(CodexBridge.mergeHistory([old, before], latest: [updated], preserveOlder: false), [updated])
    }

}
