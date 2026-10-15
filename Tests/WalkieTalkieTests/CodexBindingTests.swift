import XCTest
@testable import WalkieTalkie

final class CodexBindingTests: XCTestCase {
    func testDesktopBindingRestoresTheConversationWithoutATerminal() {
        let handle = TerminalBinding.Handle.codex(threadID: "chat-a", tty: nil)
        XCTAssertEqual(handle.restoreKey, "codex:chat-a")
        XCTAssertNil(handle.deviceTTY)
        XCTAssertNotEqual(handle, .codex(threadID: "chat-b", tty: nil))
    }

    func testCLIBindingKeepsConversationAndTerminalIdentitiesSeparate() {
        let handle = TerminalBinding.Handle.codex(threadID: "chat-a", tty: "/dev/ttys009")
        XCTAssertEqual(handle.tty, "ttys009")
        XCTAssertEqual(handle.restoreKey, "codex:chat-a")
    }

    func testChatMetadataDoesNotInventATitleOrProject() {
        XCTAssertNil(CodexBridge.Conversation(["title": "missing id"]))
        let chat = CodexBridge.Conversation(["id": "chat-a", "title": "", "cwd": "/projects/example", "busy": true])
        XCTAssertEqual(chat?.title, "Untitled Codex chat")
        XCTAssertEqual(chat?.folder, "example")
        XCTAssertEqual(chat?.key, "codex:chat-a")
        XCTAssertEqual(chat?.busy, true)
    }

    func testPickerCLIIdentityKeepsOnlyTheVerifiedLiveTerminal() {
        let row: [String: Any] = ["id": "chat-a", "live": true, "ttyOwner": true, "tty": "/dev/ttys009"]
        let chat = CodexBridge.Conversation(row)
        XCTAssertEqual(chat?.handle, .codex(threadID: "chat-a", tty: "/dev/ttys009"))
        XCTAssertEqual(chat?.locationLabel, "CLI · ttys009")
        var unverified = row
        unverified["ttyOwner"] = false
        XCTAssertNil(CodexBridge.Conversation(unverified)?.terminalTTY)
        var saved = row
        saved["live"] = false
        XCTAssertNil(CodexBridge.Conversation(saved)?.terminalTTY)
        XCTAssertTrue(CodexBridge.Conversation(saved)?.locationLabel.hasPrefix("Status unverified") == true)
        for invalid in ["codex:chat-a", "ttys009", "/dev/ttys009;kill", "/tmp/ttys009"] {
            var malformed = row
            malformed["tty"] = invalid
            XCTAssertNil(CodexBridge.Conversation(malformed)?.terminalTTY)
        }
    }

    func testAttachmentParserDoesNotReadAnUnrelatedDirectory() {
        XCTAssertEqual(CodexBridge.attachmentPaths(in: "[📁=/etc]"), [])
        XCTAssertEqual(CodexBridge.attachmentPaths(in: "plain dictation"), [])
        XCTAssertEqual(CodexBridge.attachmentPaths(in: "[📁=$WALKIE_SHOTS/../../../../etc]"), [])
    }

    func testNativeDesktopAppIsBindable() {
        XCTAssertTrue(TerminalBinding.isBindable(bundleID: "com.openai.codex"))
        XCTAssertFalse(TerminalBinding.isBindable(bundleID: "com.apple.finder"))
    }

    func testRebindActivationBindsFreshlyVerifiedLiveOwner() throws {
        let live = CodexBridge.Conversation([
            "id": "chat-a", "cwd": "/recorded/project", "live": true,
            "ttyOwner": true, "tty": "codex:chat-a",
        ])!

        XCTAssertEqual(try CodexBridge.rebindDisposition(
            session: "chat-a", recordedCWD: "/stale/path", load: { _ in live }),
            .bind(live))
    }

    func testRebindActivationResumesOnlyConfirmedClosedMetadata() throws {
        let closed = CodexBridge.Conversation([
            "id": "chat-a", "cwd": "/fresh/project", "live": false,
        ])!

        XCTAssertEqual(try CodexBridge.rebindDisposition(
            session: "chat-a", recordedCWD: "/stale/path", load: { _ in closed }),
            .resume(session: "chat-a", cwd: "/fresh/project"))
    }

    func testRebindActivationPropagatesUnknownOwnershipWithoutResume() {
        let unknown = NSError(domain: "test", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "ownership unknown"])

        XCTAssertThrowsError(try CodexBridge.rebindDisposition(
            session: "chat-a", recordedCWD: "/recorded/project", load: { _ in throw unknown })) {
            XCTAssertEqual(($0 as NSError).localizedDescription, "ownership unknown")
        }
    }

    func testPickerActivationBindsFreshlyVerifiedOwnerFromUnverifiedRow() throws {
        let listed = CodexBridge.Conversation([
            "id": "chat-a", "cwd": "/stale/project", "live": false,
        ])!
        let fresh = CodexBridge.Conversation([
            "id": "chat-a", "cwd": "/fresh/project", "live": true,
            "ttyOwner": true, "tty": "/dev/ttys009",
        ])!
        var loadedID: String?

        let result = try CodexBridge.pickerDisposition(session: listed.id) { id in
            loadedID = id
            return fresh
        }

        XCTAssertEqual(loadedID, "chat-a")
        XCTAssertEqual(result, .bind(fresh))
        XCTAssertEqual(fresh.handle, .codex(threadID: "chat-a", tty: "/dev/ttys009"))
    }

    func testPickerActivationRejectsClosedUnknownAndWrongConversation() throws {
        let closed = CodexBridge.Conversation(["id": "chat-a", "live": false])!
        XCTAssertEqual(try CodexBridge.pickerDisposition(
            session: "chat-a", load: { _ in closed }), .closed)

        let unknown = NSError(domain: "test", code: 9,
                              userInfo: [NSLocalizedDescriptionKey: "owner lookup timed out"])
        XCTAssertThrowsError(try CodexBridge.pickerDisposition(
            session: "chat-a", load: { _ in throw unknown })) {
            XCTAssertEqual(($0 as NSError).localizedDescription, "owner lookup timed out")
        }

        let wrong = CodexBridge.Conversation(["id": "chat-b", "live": true])!
        XCTAssertThrowsError(try CodexBridge.pickerDisposition(
            session: "chat-a", load: { _ in wrong })) {
            XCTAssertTrue(($0 as NSError).localizedDescription.contains("different chat"))
        }
    }

    func testPickerOwnerCheckInvalidatesStaleCompletionAndDuplicateClick() {
        let gate = CodexPickerCheckGate()
        let first = gate.begin(threadID: "chat-a")!
        XCTAssertNil(gate.begin(threadID: "chat-a"))

        gate.invalidate()
        XCTAssertFalse(gate.accept(first))

        let reopened = gate.begin(threadID: "chat-b")!
        XCTAssertFalse(gate.accept(first))
        XCTAssertTrue(gate.accept(reopened))
        XCTAssertFalse(gate.isChecking)
    }

    func testCropKeepsContextAndFilmCarriesItsContactSheet() throws {
        let folder = Outbox.cacheRoot.appendingPathComponent("attachment-test-\(UUID().uuidString)")
        let film = folder.appendingPathComponent("film-test")
        try FileManager.default.createDirectory(at: film, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = ["screenshot-0.jpg", "screenshot-0-800px.jpg", "screenshot-0-original.jpg"]
        for name in names { try Data([0]).write(to: folder.appendingPathComponent(name)) }
        let sheet = film.appendingPathComponent("sheet.png")
        try Data([0]).write(to: sheet)
        let text = "[📁=\(folder.path)]\n[🎬=\(sheet.path)]"
        XCTAssertEqual(Set(CodexBridge.attachmentPaths(in: text)), Set([
            folder.appendingPathComponent("screenshot-0.jpg").path,
            folder.appendingPathComponent("screenshot-0-800px.jpg").path, sheet.path
        ]))
    }

    func testCompletionCueIsExplicitAndOnlyAddedOnce() {
        let ordinary = "Please fix the layout"
        XCTAssertEqual(CodexBridge.withCompletionCue(ordinary), ordinary)
        let marked = CodexBridge.withCompletionCue(ordinary + "\n\nkamikaze")
        XCTAssertTrue(marked.contains("close only this session"))
        XCTAssertEqual(CodexBridge.withCompletionCue(marked), marked)
    }

    func testMixedScreenshotsAndFilmsResolveSeparateSessionFolders() throws {
        let root = Outbox.cacheRoot.appendingPathComponent("mixed-test-\(UUID().uuidString)")
        let shots = root.appendingPathComponent("dictation")
        let film = root.appendingPathComponent("app-session/film-test")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: film, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shot = shots.appendingPathComponent("screenshot-0-800px.jpg")
        let sheet = film.appendingPathComponent("sheet.png")
        try Data([0]).write(to: shot)
        try Data([0]).write(to: sheet)
        let relativeSheet = sheet.path.replacingOccurrences(of: Outbox.cacheRoot.path, with: "$WALKIE_SHOTS")
        let text = "[📁=\(shots.path)]\n[🎬1 = \(relativeSheet), a contact sheet]"
        XCTAssertEqual(Set(CodexBridge.attachmentPaths(in: text)), Set([shot.path, sheet.path]))
    }

    func testAttachmentSymlinkCannotEscapeTheCache() throws {
        let folder = Outbox.cacheRoot.appendingPathComponent("symlink-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("screenshot-0.jpg").path,
                                                  withDestinationPath: "/etc/hosts")
        XCTAssertEqual(CodexBridge.attachmentPaths(in: "[📁=\(folder.path)]"), [])
    }
}
