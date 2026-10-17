import AppKit
import XCTest
@testable import WalkieTalkie

final class KeyboardShortcutTests: XCTestCase {
    private let modifiers: CGEventFlags = [.maskControl, .maskCommand]

    func testLettersFollowTheLayoutAndDoNotClaimMacLock() {
        XCTAssertEqual(WalkieKeyboardShortcut.match(keyCode: 0x0C, letter: "a", flags: modifiers), .ask,
                       "A on an AZERTY layout is not the QWERTY A keycode")
        XCTAssertNil(WalkieKeyboardShortcut.match(keyCode: 0x00, letter: "q", flags: modifiers),
                     "Control-Command-Q belongs to macOS Lock Screen")
        XCTAssertEqual(WalkieKeyboardShortcut.match(keyCode: 0x2D, letter: "N", flags: modifiers), .newChat)
    }

    func testOtherModifierFamiliesAndUnrecognizedLettersPassThrough() {
        for flags: CGEventFlags in [[], .maskCommand, .maskControl,
                                   [.maskControl, .maskCommand, .maskShift],
                                   [.maskControl, .maskCommand, .maskAlternate]] {
            XCTAssertNil(WalkieKeyboardShortcut.match(keyCode: 0x2D, letter: "n", flags: flags))
        }
        XCTAssertNil(WalkieKeyboardShortcut.match(keyCode: 0x2D, letter: nil, flags: modifiers))
        XCTAssertNil(WalkieKeyboardShortcut.match(keyCode: 0x2D, letter: "z", flags: modifiers))
    }

    func testEachLegacyActionHasAnAliasAndCancelIsDistinctFromAsk() {
        XCTAssertEqual(Set(WalkieKeyboardShortcut.allCases.map(\.legacyKeyCode)), Set(HotkeyTap.gestureNames.keys))
        XCTAssertEqual(Set(WalkieKeyboardShortcut.allCases.map(\.shortcut)).count,
                       WalkieKeyboardShortcut.allCases.count)
        XCTAssertEqual(WalkieKeyboardShortcut.match(keyCode: 0x35, letter: nil, flags: modifiers), .cancel)
        XCTAssertEqual(WalkieKeyboardShortcut.match(keyCode: 0x24, letter: nil, flags: modifiers), .enter)
        XCTAssertEqual(WalkieKeyboardShortcut.match(keyCode: 0x4C, letter: nil, flags: modifiers), .enter)
    }

    func testNewChatAliasDispatchesOnceInWheelModeWithoutPostingKeys() throws {
        HotkeyTap.refreshKeyboardLayout()
        let tap = HotkeyTap()
        tap.useLogiGestures = false
        let first = expectation(description: "one new-chat action")
        tap.onGestureSpawn = { first.fulfill() }
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x2D, keyDown: true))
        event.flags = modifiers
        XCTAssertNil(tap.handle(type: .keyDown, event: event))
        waitForExpectations(timeout: 2)
        let repeated = expectation(description: "repeat must not create another chat")
        repeated.isInverted = true
        tap.onGestureSpawn = { repeated.fulfill() }
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertNil(tap.handle(type: .keyDown, event: event))
        waitForExpectations(timeout: 0.05)
    }

    func testModifiedEscapeUsesCancelOnlyInTheEventHandler() throws {
        let tap = HotkeyTap()
        tap.useLogiGestures = false
        let cancel = expectation(description: "cancel only")
        let ask = expectation(description: "must not start Quick Ask")
        ask.isInverted = true
        tap.onKeyboardCancel = { cancel.fulfill() }
        tap.onLocalCancel = { ask.fulfill() }
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: true))
        event.flags = modifiers
        XCTAssertNil(tap.handle(type: .keyDown, event: event))
        waitForExpectations(timeout: 0.05)
    }

    func testRecordingHintsFollowFilmNewChatAndCloseCueState() {
        let prompt = GestureHintBar.keyboardHints(for: .init(listening: true, prompting: true))
        XCTAssertTrue(prompt.contains(.init(label: "Screenshot", shortcut: "⌃⌘S")))
        XCTAssertTrue(prompt.contains(.init(label: "New chat", shortcut: "⌃⌘N")))
        XCTAssertTrue(prompt.contains(.init(label: "Cancel", shortcut: "⌃⌘Esc")))
        let changed = GestureHintBar.keyboardHints(for: .init(listening: true, prompting: true,
            filming: true, kamikaze: true, spawn: true))
        XCTAssertTrue(changed.contains(.init(label: "Stop film", shortcut: "⌃⌘V")))
        XCTAssertTrue(changed.contains(.init(label: "Change new-chat folder", shortcut: "⌃⌘N")))
        XCTAssertTrue(changed.contains(.init(label: "Close when done: ON", shortcut: "⌃⌘K")))
    }

    func testPlainAndQuickHintsDoNotOfferPromptAttachments() {
        XCTAssertEqual(GestureHintBar.keyboardHints(for: .init()), [])
        XCTAssertEqual(GestureHintBar.keyboardHints(for: .init(listening: true, held: true)), [])
        let plain = GestureHintBar.keyboardHints(for: .init(listening: true))
        XCTAssertEqual(plain.map(\.shortcut), ["⌃⌘I", "⌃⌘E", "⌃⌘Esc"])
        let quick = GestureHintBar.keyboardHints(for: .init(listening: true, quick: true))
        XCTAssertEqual(quick.map(\.label), ["Stop and ask", "Cancel"])
        XCTAssertEqual(GestureHintBar.keyboardHints(for: .init(listening: true, crop: .selecting)), [])
    }

    func testKeyboardHintsKeepACompactScaleOnAnExternalDisplay() throws {
        let displays = [GestureHintBar.Display(frame: NSRect(x: 0, y: 0, width: 1728, height: 1117),
            visible: NSRect(x: 0, y: 0, width: 1728, height: 1079), builtIn: true),
            GestureHintBar.Display(frame: NSRect(x: 1728, y: 0, width: 1920, height: 1080),
            visible: NSRect(x: 1728, y: 0, width: 1920, height: 1080), builtIn: false)]
        let spot = try XCTUnwrap(GestureHintBar.spot(base: NSSize(width: 400, height: 122),
            on: displays, pointer: NSPoint(x: 500, y: 500), scaleOverride: 1))
        XCTAssertEqual(spot.scale, 1)
        XCTAssertEqual(spot.rect.size, NSSize(width: 400, height: 122))
    }

    func testHintMeasurementSurvivesTheReportedCoreTextException() {
        let font = NSFont.systemFont(ofSize: 12)
        let size = GestureHintBar.Board.textSize("⌃⌘N", font: font) {
            NSException(name: .invalidArgumentException,
                        reason: "attempt to insert nil object from objects[0]", userInfo: nil).raise()
            return .zero
        }
        XCTAssertGreaterThanOrEqual(size.width, 36)
        XCTAssertGreaterThan(size.height, 12)
        XCTAssertGreaterThan(GestureHintBar.Board.textSize("New chat", font: font).width, 0)
    }

    func testHintLayoutRemainsStableAcrossPointerMovementAndStageChanges() {
        let board = GestureHintBar.Board(frame: .zero)
        let screen = GestureHintBar.Display(frame: NSRect(x: 0, y: 0, width: 1728, height: 1117),
            visible: NSRect(x: 0, y: 0, width: 1728, height: 1079), builtIn: true)
        for stage in [GestureHintBar.Stage(listening: true, prompting: true),
                      .init(listening: true, prompting: true, filming: true, spawn: true),
                      .init(listening: true), .init(listening: true, quick: true)] {
            board.keyboard = GestureHintBar.keyboardHints(for: stage)
            let size = board.baseSize
            XCTAssertGreaterThan(size.width, 0)
            XCTAssertLessThanOrEqual(size.width, 600)
            for i in 0..<1000 {
                let spot = GestureHintBar.spot(base: board.baseSize, on: [screen],
                    pointer: NSPoint(x: i % 1728, y: i % 1117), scaleOverride: 1)
                XCTAssertEqual(spot?.rect.size, size)
            }
        }
    }

    func testRenderKeyboardHintsForReview() throws {
        guard let directory = ProcessInfo.processInfo.environment["KEYBOARD_HINT_PNG"] else { return }
        for (name, stage) in [("prompt", GestureHintBar.Stage(listening: true, prompting: true)),
            ("filming", .init(listening: true, prompting: true, filming: true, kamikaze: true, spawn: true)),
            ("plain", .init(listening: true)), ("quick", .init(listening: true, quick: true))] {
            let hints = GestureHintBar.keyboardHints(for: stage)
            let size = GestureHintBar.Board.size(for: [], mouse: nil, keyboard: hints)
            XCTAssertLessThanOrEqual(size.width, 600)
            for (theme, color) in [("dark", NSColor(white: 0.12, alpha: 1)), ("light", NSColor(white: 0.93, alpha: 1))] {
                let board = GestureHintBar.Board(frame: NSRect(origin: NSPoint(x: 16, y: 16), size: size))
                board.keyboard = hints
                board.opacity = 1
                let host = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 32, height: size.height + 32))
                host.wantsLayer = true
                host.layer?.backgroundColor = color.cgColor
                host.addSubview(board)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(theme).png"))
            }
        }
    }
}
