import Foundation

/// The fallback folder for new chats and the second new-chat gesture.
/// A folder selected in the app wins over the legacy launch-environment hint.
enum NewChatFolder {
    static let preferenceKey = "newChatFolder"
    static var path: String { resolve() }
    static var workspace: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("workspace")
    }

    static func resolve(defaults: UserDefaults = .standard,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        for candidate in [defaults.string(forKey: preferenceKey), environment["WT_PROJECT_ROOT"]] {
            guard let candidate, !candidate.isEmpty else { continue }
            let expanded = (candidate as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { continue }
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
        }
        return home.appendingPathComponent("workspace").path
    }

    static func select(_ directory: URL, defaults: UserDefaults = .standard) {
        defaults.set(directory.standardizedFileURL.path, forKey: preferenceKey)
    }
}
