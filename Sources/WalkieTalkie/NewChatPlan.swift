import Foundation

enum NewChatClient: String {
    case background
    case cli
    var label: String { self == .background ? "Codex · background" : "Codex CLI" }

    static let terminalPreferenceKey = "openTerminalForNewCodexChats"
    static func preferred(defaults: UserDefaults = .standard) -> Self {
        defaults.bool(forKey: terminalPreferenceKey) ? .cli : .background
    }
}

/// A new-chat gesture changes only this recording, never the bound chat.
struct NewChatPlan: Equatable {
    var directory: String
    var client: NewChatClient = .background

    static func first(boundDirectory: String?, defaultDirectory: String) -> Self {
        let directory = boundDirectory.flatMap { $0.hasPrefix("/") ? $0 : nil }
        return Self(directory: directory ?? defaultDirectory)
    }

}
