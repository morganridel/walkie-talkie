import XCTest
@testable import WalkieTalkie

/// `ShotMarker.resolveStrict` (2026-09-30): markers spliced into Wispr's stream,
/// read from `asrText`, placed into the formatted words — every one or none.
/// The sentences are real Wispr rows from `evals/wispr-markers/results.jsonl`.
final class ShotMarkerStrictTests: XCTestCase {

    private func shot(_ n: Int) -> ShotMarker.Said { ShotMarker.Said(kind: .shot, index: n) }
    private let tokens = [1: "[📸1]", 3: "[📸3]", 5: "[📸5]", 6: "[📸6]", 8: "[📸8]", 10: "[📸10]"]

    /// The formatter kept one marker as `(screenshot 6)` and deleted the other;
    /// `asrText` has both, so both land — where the recogniser heard them.
    func testBothPlacedFromAsrWhenTheFormatterDroppedOne() {
        let asr = "Make sure that the bug about the bug number forty is not yet fixed. There could be some leaking fixes from the previous group into this. Screenshot six. So bug number forty, this one, should not screenshot one have been fixed yet on the main branch, neither on the MM branch I just created today."
        let text = "Make sure that bug number 40 is not yet fixed. There could be some leaking fixes from the previous group into this (screenshot 6). Bug number 40 (this one) should not have been fixed yet on the main branch nor on the MM branch I just created today."
        let r = ShotMarker.resolveStrict(text: text, asr: asr, said: [shot(6), shot(1)], shots: tokens)
        XCTAssertTrue(r.clean, r.why)
        XCTAssertEqual(r.shots, [6, 1])
        XCTAssertFalse(r.text.lowercased().contains("screenshot"), r.text)
        XCTAssertTrue(r.text.contains("into this. [📸6] Bug number 40") || r.text.contains("into this [📸6] Bug number 40"), r.text)
        XCTAssertTrue(r.text.contains("should not [📸1] have been fixed"), r.text)
    }

    /// A mis-cut clip says the next number too: heard 3, 4, 8 for said 3, 8.
    /// Nothing is placed, and every shot phrase — the phantom too — is removed.
    func testAPhantomFallsBackAndStripsEveryShotPhrase() {
        let asr = "Să presupunem că folosesc Opus pe High. Screenshot three. Screenshot four. La ce câștig mă pot aștepta dacă sesiunile mele sunt de vreo trei- Screenshot eight. Sute de mii de tokeni."
        let text = "Să presupunem că folosesc Opus pe High. Screenshot three. Screenshot four. La ce câștig mă pot aștepta dacă sesiunile mele sunt de vreo trei—Screenshot eight. Sute de mii de tokeni."
        let r = ShotMarker.resolveStrict(text: text, asr: asr, said: [shot(3), shot(8)], shots: tokens)
        XCTAssertFalse(r.clean)
        XCTAssertEqual(r.shots, [])
        XCTAssertFalse(r.text.lowercased().contains("screenshot"), r.text)
        XCTAssertTrue(r.text.hasPrefix("Să presupunem că folosesc Opus pe High. La ce câștig"), r.text)
    }

    /// One of two lost in `asrText`: the whole sentence falls back.
    func testALostMarkerFallsBack() {
        let asr = "Deci și cu Escape și cu click din nou. Screenshot five. Că e un pic, mă distrage."
        let text = "Deci, și cu Escape, și cu click din nou. Screenshot five. Că e un pic, mă distrage."
        let r = ShotMarker.resolveStrict(text: text, asr: asr, said: [shot(10), shot(5)], shots: tokens)
        XCTAssertFalse(r.clean)
        XCTAssertEqual(r.text, "Deci, și cu Escape, și cu click din nou. Că e un pic, mă distrage.")
    }

    /// Swapped order is not the order said.
    func testOrderMatters() {
        let r = ShotMarker.resolveStrict(text: "a Screenshot five. b Screenshot ten. c",
                                         asr: "a Screenshot five. b Screenshot ten. c",
                                         said: [shot(10), shot(5)], shots: tokens)
        XCTAssertFalse(r.clean)
    }

    /// The formatter moved the marker to the end; the recogniser had it mid-sentence.
    func testPositionComesFromAsrNotFromWhereTheFormatterPutIt() {
        let asr = "Te rog frumos să modifici skill-urile Open Spec. Screenshot three. Ca de acum înainte, ori de câte ori îmi- Screenshot eight ...propui un spec, să respecți această regulă."
        let text = "Te rog frumos să modifici skill-urile Open Spec. Ca de acum înainte, ori de câte ori îmi propui un spec, să respecți această regulă. Screenshot eight."
        let r = ShotMarker.resolveStrict(text: text, asr: asr, said: [shot(3), shot(8)], shots: tokens)
        XCTAssertTrue(r.clean, r.why)
        XCTAssertTrue(r.text.contains("Open Spec. [📸3] Ca de acum"), r.text)
        XCTAssertTrue(r.text.contains("îmi [📸8] propui un spec"), r.text)
        XCTAssertTrue(r.text.hasSuffix("această regulă."), r.text)
    }

    /// No `asrText`: the delivered words are both the check and the position.
    func testWithoutAsrTheDeliveredWordsAreRead() {
        let text = "Run deeper research to prove that indeed. Screenshot eight. I have to pay for this account."
        let r = ShotMarker.resolveStrict(text: text, asr: nil, said: [shot(8)], shots: tokens)
        XCTAssertTrue(r.clean, r.why)
        XCTAssertEqual(r.text, "Run deeper research to prove that indeed. [📸8] I have to pay for this account.")
    }

    /// A number with no picture behind it (a capture that failed) is removed, not rendered.
    func testASaidNumberWithNothingBehindItIsOnlyRemoved() {
        let text = "one Screenshot eight. two"
        let r = ShotMarker.resolveStrict(text: text, asr: text, said: [shot(8)], shots: [:])
        XCTAssertTrue(r.clean, r.why)
        XCTAssertEqual(r.shots, [])
        XCTAssertEqual(r.text, "one two")
    }

    /// What the formatter wrapped round the marker goes with it; his own `foo()` stays.
    func testWrappersGoOnlyRoundTheMarker() {
        let text = "call foo() then *Screenshot one.* done"
        let r = ShotMarker.resolveStrict(text: text, asr: "call foo then screenshot one done", said: [shot(1)], shots: tokens)
        XCTAssertTrue(r.clean, r.why)
        XCTAssertEqual(r.text, "call foo() then [📸1] done")
    }

    /// **The local model standing in for Wispr (Q14) reads the markers off its
    /// own words** (2026-10-12, 12:10:56): Wispr ignored both stop chords, the
    /// relay's WAV — markers spliced in — went to Whisper, and `Screenshot for.`
    /// is its *four*. No `asrText`, so the delivered words are what was heard.
    func testLocalFallbackWordsPlaceEveryMarker() {
        let text = "Să pot apăsa acest buton. Screenshot one. Dacă apăsăm pe mai multe mailuri să se acumuleze într-un stivă asta unul peste altul. Screenshot two. Și să am buton de cancel aici undeva. Screenshot three. Anulez această dezabonare automatizată.Și după ce se dezabonează, scoate și mail-ul de aicea, marchează, adică arhivează practic. Screenshot for."
        let toks = [1: "[📸1]", 2: "[📸2✂️]", 3: "[📸3]", 4: "[📸4]"]
        let r = ShotMarker.resolveStrict(text: text, asr: nil, said: [shot(1), shot(2), shot(3), shot(4)], shots: toks)
        XCTAssertTrue(r.clean, r.why)
        XCTAssertEqual(r.shots, [1, 2, 3, 4])
        XCTAssertFalse(r.text.lowercased().contains("screenshot"), r.text)
        XCTAssertTrue(r.text.contains("acest buton. [📸1] Dacă"), r.text)
        XCTAssertTrue(r.text.hasSuffix("practic. [📸4]") || r.text.hasSuffix("practic.[📸4]") || r.text.hasSuffix("practic [📸4]"), r.text)
    }
}
