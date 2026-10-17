import XCTest
import AppKit
@testable import WalkieTalkie

final class CodexBindingTests: XCTestCase {
    func testPickerHardwareNavigationWorksOutsideTheSearchFieldEditor() {
        let plain: NSEvent.ModifierFlags = []
        XCTAssertEqual(CodexPickerNavigationCommand.command(
            keyCode: 125, modifiers: plain, hasMarkedText: false), .move(1))
        XCTAssertEqual(CodexPickerNavigationCommand.command(
            keyCode: 126, modifiers: plain, hasMarkedText: false), .move(-1))
        XCTAssertEqual(CodexPickerNavigationCommand.command(
            keyCode: 121, modifiers: plain, hasMarkedText: false), .page(1))
        XCTAssertEqual(CodexPickerNavigationCommand.command(
            keyCode: 116, modifiers: plain, hasMarkedText: false), .page(-1))
        XCTAssertEqual(CodexPickerNavigationCommand.command(
            keyCode: 36, modifiers: plain, hasMarkedText: false), .activate)
        XCTAssertEqual(CodexPickerNavigationCommand.command(
            keyCode: 76, modifiers: plain, hasMarkedText: false), .activate)
        XCTAssertEqual(CodexPickerNavigationCommand.command(
            keyCode: 53, modifiers: plain, hasMarkedText: false), .back)

        // Ordinary typing and editor shortcuts must still reach the field
        // editor, and marked text must remain under the input method's control.
        XCTAssertNil(CodexPickerNavigationCommand.command(
            keyCode: 0, modifiers: plain, hasMarkedText: false))
        XCTAssertNil(CodexPickerNavigationCommand.command(
            keyCode: 125, modifiers: .shift, hasMarkedText: false))
        XCTAssertNil(CodexPickerNavigationCommand.command(
            keyCode: 36, modifiers: plain, hasMarkedText: true))
    }

    func testPickerKeyPanelRoutesNavigationForFieldAndTableFirstResponders() throws {
        let panel = CodexPickerKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let field = NSTextField(frame: NSRect(x: 0, y: 60, width: 200, height: 30))
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        panel.contentView?.addSubview(field)
        panel.contentView?.addSubview(table)
        var commands: [CodexPickerNavigationCommand] = []
        panel.onNavigationKey = { event in
            guard let command = CodexPickerNavigationCommand.command(
                keyCode: event.keyCode, modifiers: event.modifierFlags,
                hasMarkedText: false) else { return false }
            commands.append(command)
            return true
        }

        XCTAssertTrue(panel.makeFirstResponder(field))
        let down = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil,
            characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false, keyCode: 125))
        panel.sendEvent(down)

        XCTAssertTrue(panel.makeFirstResponder(table))
        let enter = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        panel.sendEvent(enter)
        XCTAssertEqual(commands, [.move(1), .activate])
    }

    func testDesktopKeyboardSwitchDoesNotConsultOrBindTheForegroundApp() {
        var pickerOpenings = 0
        var foregroundBindings = 0
        CodexBindShortcut.perform(bound: .codex(threadID: "desktop-chat", tty: nil),
            showPicker: { pickerOpenings += 1 },
            bindFrontmost: { foregroundBindings += 1 })
        XCTAssertEqual(pickerOpenings, 1)
        XCTAssertEqual(foregroundBindings, 0)
    }

    func testExplicitPickerShortcutWorksWithoutABindingOrWithACLI() {
        let targets: [TerminalBinding.Handle?] = [
            nil, .codex(threadID: "cli-chat", tty: "/dev/ttys009"),
            .terminalApp(tty: "/dev/ttys009")
        ]
        for target in targets {
            var pickerOpenings = 0
            var foregroundBindings = 0
            CodexBindShortcut.perform(bound: target, forcePicker: true,
                showPicker: { pickerOpenings += 1 },
                bindFrontmost: { foregroundBindings += 1 })
            XCTAssertEqual(pickerOpenings, 1)
            XCTAssertEqual(foregroundBindings, 0)
        }
    }

    func testKeyboardBindingPreservesDirectTerminalAndUnboundRoutes() {
        let targets: [TerminalBinding.Handle?] = [
            nil, .codex(threadID: "cli-chat", tty: "/dev/ttys009"),
            .terminalApp(tty: "/dev/ttys009")
        ]
        for target in targets {
            var pickerOpenings = 0
            var foregroundBindings = 0
            CodexBindShortcut.perform(bound: target,
                showPicker: { pickerOpenings += 1 },
                bindFrontmost: { foregroundBindings += 1 })
            XCTAssertEqual(pickerOpenings, 0)
            XCTAssertEqual(foregroundBindings, 1)
        }
    }

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
        XCTAssertEqual(CodexBridge.Conversation(saved)?.locationLabel, "Saved chat")
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

        let result = try CodexBridge.pickerDisposition(
            session: listed.id, recordedCWD: listed.cwd) { id in
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
            session: "chat-a", recordedCWD: "/recorded/project", load: { _ in closed }),
            .resume(session: "chat-a", cwd: "/recorded/project"))
        let moved = CodexBridge.Conversation([
            "id": "chat-a", "cwd": "/fresh/project", "live": false,
        ])!
        XCTAssertEqual(try CodexBridge.pickerDisposition(
            session: "chat-a", recordedCWD: "/recorded/project", load: { _ in moved }),
            .resume(session: "chat-a", cwd: "/fresh/project"))

        let unknown = NSError(domain: "test", code: 9,
                              userInfo: [NSLocalizedDescriptionKey: "owner lookup timed out"])
        XCTAssertThrowsError(try CodexBridge.pickerDisposition(
            session: "chat-a", recordedCWD: "/recorded/project",
            load: { _ in throw unknown })) {
            XCTAssertEqual(($0 as NSError).localizedDescription, "owner lookup timed out")
        }

        let wrong = CodexBridge.Conversation(["id": "chat-b", "live": true])!
        XCTAssertThrowsError(try CodexBridge.pickerDisposition(
            session: "chat-a", recordedCWD: "/recorded/project",
            load: { _ in wrong })) {
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

    func testPickerProjectsFollowTheirMostRecentChatOrder() {
        let chats = [
            CodexBridge.Conversation(["id": "z-new", "cwd": "/work/zebra"])!,
            CodexBridge.Conversation(["id": "a-new", "cwd": "/work/alpha"])!,
            CodexBridge.Conversation(["id": "z-old", "cwd": "/work/zebra"])!,
            CodexBridge.Conversation(["id": "b-old", "cwd": "/work/beta"])!,
        ]
        let projects = CodexPickerCatalog.projects(from: chats)
        XCTAssertEqual(projects.map(\.cwd), ["/work/zebra", "/work/alpha", "/work/beta"])
        XCTAssertEqual(projects[0].conversations.map(\.id), ["z-new", "z-old"])
        XCTAssertEqual(CodexPickerCatalog.projects(projects, matching: "work").map(\.cwd),
                       ["/work/zebra", "/work/alpha", "/work/beta"])
    }

    func testPickerCatalogGroupsEveryChatByRecordedWorkingFolder() {
        let chats = [
            CodexBridge.Conversation(["id": "a", "title": "Newest", "cwd": "/work/alpha", "live": true])!,
            CodexBridge.Conversation(["id": "b", "title": "Past", "cwd": "/work/alpha", "live": false])!,
            CodexBridge.Conversation(["id": "c", "title": "No folder", "cwd": "", "live": false])!,
        ]
        let projects = CodexPickerCatalog.projects(from: chats)
        let alpha = projects.first { $0.cwd == "/work/alpha" }
        XCTAssertEqual(alpha?.title, "alpha")
        XCTAssertEqual(alpha?.conversations.map(\.id), ["a", "b"])
        XCTAssertEqual(alpha?.liveCount, 1)
        XCTAssertEqual(projects.first { $0.cwd.isEmpty }?.title, "No recorded folder")
        XCTAssertEqual(CodexPickerCatalog.projects(projects, matching: "work alpha").map(\.cwd),
                       ["/work/alpha"])
    }

    func testPickerCatalogWalksOlderPagesWithoutDuplicatingChats() throws {
        let a = CodexBridge.Conversation(["id": "a", "cwd": "/new"] )!
        let b = CodexBridge.Conversation(["id": "b", "cwd": "/old"] )!
        var cursors: [String?] = []
        let chats = try CodexBridge.conversationCatalog { cursor in
            cursors.append(cursor)
            if cursor == nil {
                return .init(conversations: [a], nextCursor: "older")
            }
            return .init(conversations: [a, b], nextCursor: nil)
        }
        XCTAssertEqual(cursors.count, 2)
        XCTAssertNil(cursors[0])
        XCTAssertEqual(cursors[1], "older")
        XCTAssertEqual(chats.map(\.id), ["a", "b"])
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
