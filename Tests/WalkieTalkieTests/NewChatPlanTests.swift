import XCTest
@testable import WalkieTalkie

final class NewChatPlanTests: XCTestCase {
    func testNewChatReusesFullBoundFolderAndDefaultsToBackground() {
        let plan = NewChatPlan.first(boundDirectory: "/tmp/one/Project with spaces", defaultDirectory: "/tmp/workspace")
        XCTAssertEqual(plan.directory, "/tmp/one/Project with spaces")
        XCTAssertEqual(plan.client, .background)
        XCTAssertEqual(plan.client.label, "Codex · background")
    }

    func testUnboundOrInvalidFolderUsesDefault() {
        for bound in [nil, "", "just-a-display-name"] as [String?] {
            XCTAssertEqual(NewChatPlan.first(boundDirectory: bound, defaultDirectory: "/tmp/workspace").directory,
                           "/tmp/workspace")
        }
    }

    func testDefaultFolderSwitchPreservesExplicitCLIChoiceAndRecordedCopy() {
        var recording = NewChatPlan.first(boundDirectory: "/tmp/project", defaultDirectory: "/tmp/workspace")
        recording.client = .cli
        let held = recording
        recording.directory = "/tmp/workspace"
        XCTAssertEqual(recording.directory, "/tmp/workspace")
        XCTAssertEqual(recording.client, .cli)
        XCTAssertEqual(held.directory, "/tmp/project")
    }

    func testTerminalPreferenceDefaultsOffAndPersistsInIsolatedDefaults() {
        let suiteName = "NewChatPlanTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(NewChatClient.preferred(defaults: defaults), .background)
        defaults.set(true, forKey: NewChatClient.terminalPreferenceKey)
        XCTAssertEqual(NewChatClient.preferred(defaults: defaults), .cli)
        defaults.set(false, forKey: NewChatClient.terminalPreferenceKey)
        XCTAssertEqual(NewChatClient.preferred(defaults: defaults), .background)
    }
}
