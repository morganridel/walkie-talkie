import AppKit

/// Keyboard aliases and their labels share one definition with menus and hints.
/// The existing mouse mappings keep using their original function-key codes.
enum WalkieKeyboardShortcut: String, CaseIterable {
    case enter, film, dictate, dictateAndEnter, caret, newChat, finish, route, ask, cancel, note

    var letter: String? {
        switch self {
        case .enter, .cancel: return nil
        case .film: return "v"
        case .dictate: return "i"
        case .dictateAndEnter: return "e"
        case .caret: return "p"
        case .newChat: return "n"
        case .finish: return "k"
        case .route: return "r"
        case .ask: return "a"
        case .note: return "t"
        }
    }

    var shortcut: String {
        switch self {
        case .enter: return "⌃⌘↩"
        case .cancel: return "⌃⌘Esc"
        default: return "⌃⌘" + (letter ?? "").uppercased()
        }
    }

    var title: String {
        switch self {
        case .enter: return "Type Return"
        case .film: return "Start / stop film"
        case .dictate: return "Dictate without Return / stop Quick Ask"
        case .dictateAndEnter: return "Dictate + Return / screenshot during a prompt"
        case .caret: return "Prompt at caret / stop"
        case .newChat: return "New chat / default folder picker"
        case .finish: return "Toggle finish-and-close cue"
        case .route: return "Bound prompt / switch bound and caret"
        case .ask: return "Quick Ask at rest / cancel active work"
        case .cancel: return "Cancel recording, held prompt or quick answer"
        case .note: return "Typed note / stop plain dictation / disconnect"
        }
    }

    var legacyKeyCode: CGKeyCode {
        switch self {
        case .enter: return 0x63
        case .film: return 0x76
        case .dictate: return 0x60
        case .dictateAndEnter: return 0x61
        case .caret: return 0x62
        case .newChat: return 0x64
        case .finish: return 0x65
        case .route: return 0x6D
        case .ask, .cancel: return 0x67
        case .note: return 0x6F
        }
    }

    /// `letter` is translated using the current layout, not a QWERTY position.
    /// Extra Option/Shift modifiers are left to the foreground application.
    static func match(keyCode: CGKeyCode, letter: String?, flags: CGEventFlags) -> Self? {
        guard flags.contains(.maskControl), flags.contains(.maskCommand),
              !flags.contains(.maskAlternate), !flags.contains(.maskShift) else { return nil }
        if keyCode == 0x35 { return .cancel }
        if keyCode == 0x24 || keyCode == 0x4C { return .enter }
        guard let letter else { return nil }
        return allCases.first { $0.letter == letter.lowercased() }
    }
}

enum RecordingHintMode: String, CaseIterable {
    case keyboard, mouse
    static let preferenceKey = "recordingHintMode"
    static var selected: Self {
        get { UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .keyboard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey) }
    }
    var title: String { self == .keyboard ? "Keyboard shortcuts" : "Mouse gestures" }
}
