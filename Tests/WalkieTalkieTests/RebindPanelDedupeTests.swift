import XCTest
@testable import WalkieTalkie

final class RebindPanelDedupeTests: XCTestCase {
    private let tty = "codex:01a13e80-e6c4-7fc1-8765-9e2f08f97527"

    private func destination(_ title: String, tty: String? = nil) -> RebindPanel.Row {
        RebindPanel.Row(kind: .destination, tty: tty ?? self.tty, icon: nil,
                        title: title, subtitle: "", enabled: true,
                        haystack: title.lowercased())
    }

    func testSameTTYTitleQueryKeepsOnlyTheDestinationRow() {
        let rows = [destination("Walkie Talkie integration test")]
        XCTAssertTrue(RebindPanel.visibleDestinationOwns(
            tty: tty, destinations: rows, terms: ["walkie", "integration"]))
    }

    func testSameTTYBodyOnlyQueryRetainsTheSessionHit() {
        let rows = [destination("Walkie Talkie integration test")]
        XCTAssertFalse(RebindPanel.visibleDestinationOwns(
            tty: tty, destinations: rows, terms: ["walkie_desktop_ready"]))
    }

    func testMultiTermPartialTitleMismatchRetainsTheSessionHit() {
        let rows = [destination("Walkie Talkie integration test")]
        XCTAssertFalse(RebindPanel.visibleDestinationOwns(
            tty: tty, destinations: rows, terms: ["walkie", "desktop_ready"]))
    }

    func testNoQueryPreservesExistingSameTTYDeduplication() {
        let rows = [destination("Walkie Talkie integration test")]
        XCTAssertTrue(RebindPanel.visibleDestinationOwns(
            tty: tty, destinations: rows, terms: []))
        XCTAssertFalse(RebindPanel.visibleDestinationOwns(
            tty: "codex:a-different-chat", destinations: rows, terms: []))
        XCTAssertFalse(RebindPanel.visibleDestinationOwns(
            tty: nil, destinations: rows, terms: []))
    }

    func testOnlyCurrentOpenPanelAcceptsLoadedMetadata() {
        XCTAssertTrue(RebindPanel.acceptsMetadata(expected: 4, current: 4, panelOpen: true))
        XCTAssertFalse(RebindPanel.acceptsMetadata(expected: 3, current: 4, panelOpen: true))
        XCTAssertFalse(RebindPanel.acceptsMetadata(expected: 4, current: 4, panelOpen: false))
    }

    func testCurrentCodexBindingOverridesMissedBulkOwnerProbe() {
        let session = "01a13e80-e6c4-7fc1-8765-9e2f08f97527"
        XCTAssertEqual(RebindPanel.knownCodexTTY(
            session: session, live: ["codex:" + session: "Walkie Talkie integration test"]),
            "codex:" + session)
        XCTAssertNil(RebindPanel.knownCodexTTY(session: session, live: [:]))
    }

    func testAsyncRowsPreserveSelectedDestinationIdentity() {
        let first = destination("First", tty: "codex:first")
        let selected = destination("Selected", tty: "codex:selected")
        let inserted = destination("Inserted", tty: "codex:inserted")

        XCTAssertEqual(RebindPanel.restoredSelection(
            key: selected.selectionKey, rows: [inserted, first, selected], fallback: 1), 2)
        XCTAssertEqual(RebindPanel.restoredSelection(
            key: "tty:gone", rows: [inserted, first], fallback: 8), 1)
        XCTAssertEqual(RebindPanel.restoredSelection(
            key: nil, rows: [], fallback: 4), 0)
    }
}
