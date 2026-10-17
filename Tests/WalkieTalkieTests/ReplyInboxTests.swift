import Foundation
import XCTest
@testable import WalkieTalkie

final class ReplyInboxTests: XCTestCase {
    func testAuthenticatedReplyIsClaimedOnceAndPreservesSuppressionReceipt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let inbox = try ReplyInbox(home: root, temporary: root) { body in
            calls += 1
            guard body["token"] as? String == "test-token" else { return (403, ["ok": false]) }
            XCTAssertEqual(body["text"] as? String, "answer")
            XCTAssertEqual(body["tty"] as? String, "codex:test-thread")
            return (200, ["ok": true, "shown": false, "reason": "sender in front"])
        }
        let request = inbox.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: request, withIntermediateDirectories: false)
        try JSONSerialization.data(withJSONObject: ["token": "test-token", "text": "answer", "tty": "codex:test-thread"])
            .write(to: request.appendingPathComponent("request.json"))
        inbox.poll()
        inbox.poll()
        XCTAssertEqual(calls, 1)
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: request.appendingPathComponent("response.json"))) as? [String: Any]
        XCTAssertEqual(receipt?["status"] as? Int, 200)
        XCTAssertEqual((receipt?["body"] as? [String: Any])?["shown"] as? Bool, false)

        let refused = inbox.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: refused, withIntermediateDirectories: false)
        try Data(#"{"token":"wrong"}"#.utf8).write(to: refused.appendingPathComponent("request.json"))
        inbox.poll()
        let rejection = try JSONSerialization.jsonObject(with: Data(contentsOf: refused.appendingPathComponent("response.json"))) as? [String: Any]
        XCTAssertEqual(rejection?["status"] as? Int, 403)
    }

    func testIncompleteMalformedOversizedAndSymlinkRequestsNeverReachHandler() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        var calls = 0
        let inbox = try ReplyInbox(home: root, temporary: root) { _ in
            calls += 1
            return (200, ["ok": true])
        }
        for content in [Data("{".utf8), Data(repeating: 32, count: 512 * 1024 + 1)] {
            let request = inbox.directory.appendingPathComponent(UUID().uuidString)
            try files.createDirectory(at: request, withIntermediateDirectories: false)
            try content.write(to: request.appendingPathComponent("pending.json"))
            inbox.poll()
            XCTAssertFalse(files.fileExists(atPath: request.appendingPathComponent("response.json").path))
            try files.moveItem(at: request.appendingPathComponent("pending.json"), to: request.appendingPathComponent("request.json"))
            inbox.poll()
            XCTAssertTrue(files.fileExists(atPath: request.appendingPathComponent("response.json").path))
        }
        let outside = root.appendingPathComponent("outside")
        try files.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: outside.appendingPathComponent("request.json"))
        try files.createSymbolicLink(at: inbox.directory.appendingPathComponent(UUID().uuidString), withDestinationURL: outside)
        inbox.poll()
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(files.fileExists(atPath: outside.appendingPathComponent("request.json").path))
    }
}
