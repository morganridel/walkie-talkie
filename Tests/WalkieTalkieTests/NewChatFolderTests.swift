import Foundation
import XCTest
@testable import WalkieTalkie

final class NewChatFolderTests: XCTestCase {
    private func withPreferences(_ body: (UserDefaults) -> Void) {
        let name = "WalkieTalkie.NewChatFolderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    func testFreshProfileUsesWorkspace() {
        withPreferences { defaults in
            XCTAssertEqual(NewChatFolder.resolve(defaults: defaults, environment: [:],
                home: URL(fileURLWithPath: "/Users/test")), "/Users/test/workspace")
        }
    }

    func testLegacyEnvironmentExpandsHome() {
        withPreferences { defaults in
            XCTAssertEqual(NewChatFolder.resolve(defaults: defaults,
                environment: ["WT_PROJECT_ROOT": "~/other"]),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("other").path)
        }
    }

    func testSavedChoiceWinsOverEnvironmentAndKeepsSpaces() {
        withPreferences { defaults in
            NewChatFolder.select(URL(fileURLWithPath: "/tmp/Chosen folder/../Chosen folder"), defaults: defaults)
            XCTAssertEqual(defaults.string(forKey: NewChatFolder.preferenceKey), "/tmp/Chosen folder")
            XCTAssertEqual(NewChatFolder.resolve(defaults: defaults,
                environment: ["WT_PROJECT_ROOT": "/tmp/old"]), "/tmp/Chosen folder")
            NewChatFolder.select(NewChatFolder.workspace, defaults: defaults)
            XCTAssertEqual(NewChatFolder.resolve(defaults: defaults,
                environment: ["WT_PROJECT_ROOT": "/tmp/old"]), NewChatFolder.workspace.path)
        }
    }

    func testInvalidRelativeChoicesDoNotDependOnLaunchDirectory() {
        withPreferences { defaults in
            defaults.set("relative/folder", forKey: NewChatFolder.preferenceKey)
            XCTAssertEqual(NewChatFolder.resolve(defaults: defaults,
                environment: ["WT_PROJECT_ROOT": "also-relative"],
                home: URL(fileURLWithPath: "/Users/test")), "/Users/test/workspace")
        }
    }
}
