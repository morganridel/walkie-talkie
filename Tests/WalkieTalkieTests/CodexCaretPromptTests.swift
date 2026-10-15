import XCTest
@testable import WalkieTalkie

final class CodexCaretPromptTests: XCTestCase {
    private struct SendFailure: LocalizedError {
        var errorDescription: String? { "acknowledgement lost; check the chat before retrying" }
    }
    private let thread = "01a13e80-e6c4-7fc1-8765-9e2f08f97527"
    private let tty = "/dev/ttys009"

    private func conversation(live: Bool = true, owner: Bool = true,
                              tty: String = "/dev/ttys009") -> CodexBridge.Conversation? {
        CodexBridge.Conversation([
            "id": thread, "live": live, "ttyOwner": owner, "tty": tty,
        ])
    }

    private func processes(_ command: String, status: String = "S+") -> [TerminalBinding.PromptProcess] {
        TerminalBinding.parsePromptProcesses("4242 \(status) \(command)\n", tty: tty)
    }

    func testVerifiedForegroundCodexResumeOwnsTheCaretPrompt() {
        let command = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex --remote unix:// resume \(thread)"
        XCTAssertTrue(TerminalBinding.verifiedCodexPrompt(
            onTTY: tty, conversation: conversation(), processes: processes(command)))
    }

    func testSavedStaleAndMissingMappingsNeverOwnThePrompt() {
        let command = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex --remote unix:// resume \(thread)"
        let rows = processes(command)
        XCTAssertFalse(TerminalBinding.verifiedCodexPrompt(onTTY: tty, conversation: nil, processes: rows))
        XCTAssertFalse(TerminalBinding.verifiedCodexPrompt(onTTY: tty, conversation: conversation(live: false), processes: rows))
        XCTAssertFalse(TerminalBinding.verifiedCodexPrompt(onTTY: tty, conversation: conversation(owner: false), processes: rows))
        XCTAssertFalse(TerminalBinding.verifiedCodexPrompt(onTTY: tty,
            conversation: conversation(tty: "/dev/ttys010"), processes: rows))
    }

    func testWrongConversationAndShellDoNotOwnThePrompt() {
        let other = "01a13e80-e6c4-7fc1-8765-9e2f08f97528"
        XCTAssertFalse(TerminalBinding.verifiedCodexPrompt(onTTY: tty, conversation: conversation(),
            processes: processes("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex --remote unix:// resume \(other)")))
        XCTAssertFalse(TerminalBinding.verifiedCodexPrompt(onTTY: tty, conversation: conversation(),
            processes: processes("/bin/zsh -l")))
    }

    func testBackgroundCodexAndCodexOnAnotherTTYDoNotOwnThePrompt() {
        let command = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex --remote unix:// resume \(thread)"
        XCTAssertFalse(TerminalBinding.verifiedCodexPrompt(onTTY: tty, conversation: conversation(),
            processes: processes(command, status: "S")))
        let otherTTY = TerminalBinding.parsePromptProcesses("4242 S+ \(command)\n", tty: "/dev/ttys010")
        XCTAssertFalse(TerminalBinding.verifiedCodexPrompt(onTTY: tty, conversation: conversation(),
                                                          processes: otherTTY))
    }

    func testTransitionFromCodexTUIToShellFailsClosed() {
        let command = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex --remote unix:// resume \(thread)"
        XCTAssertTrue(TerminalBinding.verifiedCodexPrompt(onTTY: tty, conversation: conversation(),
            processes: processes(command)))
        XCTAssertFalse(TerminalBinding.verifiedCodexPrompt(onTTY: tty, conversation: conversation(),
            processes: processes("-zsh")))
    }

    func testCodexCaretDispatchUsesStableThreadAndPreservesRealImageInput() throws {
        let folder = Outbox.cacheRoot.appendingPathComponent("caret-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("screenshot-0-800px.jpg")
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: image)
        let text = "What is in this image?\n\n[📁=\(folder.path)]"
        let target = TerminalBinding.CaretPromptTarget.codex(threadID: thread, tty: tty)
        var calls: [(String, String)] = []
        let result = TerminalBinding.sendCodexCaretPrompt(text, to: target) { calls.append(($0, $1)) }

        XCTAssertEqual(result, .delivered(threadID: thread, tty: tty))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, text)
        XCTAssertEqual(calls.first?.1, thread)
        XCTAssertEqual(CodexBridge.attachmentPaths(in: calls[0].0), [image.path])
    }

    func testAttemptedCodexFailureIsDistinctFromLegacyFallbackAndIsNeverRetried() {
        let target = TerminalBinding.CaretPromptTarget.codex(threadID: thread, tty: tty)
        var attempts = 0
        let failed = TerminalBinding.sendCodexCaretPrompt("hello", to: target) { _, _ in
            attempts += 1
            throw SendFailure()
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(failed, .failed(threadID: thread, tty: tty,
            reason: "acknowledgement lost; check the chat before retrying"))

        var legacyCalls = 0
        let legacy = TerminalBinding.sendCodexCaretPrompt("hello", to: .legacy(tty: tty)) { _, _ in
            legacyCalls += 1
        }
        XCTAssertEqual(legacy, .notCodex)
        XCTAssertEqual(legacyCalls, 0)
    }

    /// Opt-in integration check for a disposable native CLI PTY. The normal
    /// suite skips it; a harness supplies the isolated tty/sidecar environment
    /// and the expected state before and after the TUI exits.
    func testDisposableNativePTYWhenRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let tty = environment["WALKIE_CARET_TEST_TTY"],
              let expected = environment["WALKIE_CARET_EXPECTED"].flatMap(Bool.init)
        else { throw XCTSkip("requires an explicitly created disposable Codex CLI PTY") }
        XCTAssertEqual(TerminalBinding.agentPromptOn(tty: tty), expected)
    }

    /// Opt-in end-to-end dispatch through the real bridge. Only the disposable
    /// PTY harness sets these values; ordinary tests never send a Codex message.
    func testDisposableNativePTYSendWhenRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let tty = environment["WALKIE_CARET_TEST_TTY"],
              let text = environment["WALKIE_CARET_SEND_TEXT"],
              let expectedThread = environment["WALKIE_CARET_THREAD"]
        else { throw XCTSkip("requires an explicitly created disposable Codex CLI PTY") }
        guard let target = TerminalBinding.agentPromptTarget(onTTY: tty) else {
            return XCTFail("disposable PTY was not recognized")
        }
        XCTAssertEqual(target, .codex(threadID: expectedThread, tty: tty))
        XCTAssertEqual(TerminalBinding.sendCodexCaretPrompt(text, to: target),
                       .delivered(threadID: expectedThread, tty: tty))
    }
}
