import XCTest
@testable import WalkieTalkie

/// **Which deliveries doom their session** (2026-10-13): the reply pop-up's ☠️
/// shows a session told `kamikaze` dead — the word alone, the word ending the
/// words, the held sentence's `\n\nkamikaze` — and never a word inside the
/// envelope or in the middle of a sentence.
final class KamikazeWordTests: XCTestCase {
    private let says = TerminalBinding.saysKamikaze

    func testTheWordAlone() { XCTAssertTrue(says("kamikaze")) }
    func testTheWordEndingTheWords() {
        XCTAssertTrue(says("Fix the skull, then commit. Kamikaze.\n\n[Transcribed in RO or EN by ☁️ Wispr Flow]\n[📁=/tmp/x]"))
    }
    func testTheWordOnItsOwnLine() { XCTAssertTrue(says("fix it\n\nkamikaze")) }
    func testTheWordMidSentenceIsNot() { XCTAssertFalse(says("the kamikaze session should show a red skull")) }
    func testTheWordInTheEnvelopeIsNot() { XCTAssertFalse(says("fix it\n\n[context: kamikaze]")) }
}
