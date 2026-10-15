import Foundation

/// **Whose is a Wispr ⌘V after the relay's own sentence went idle** — the pure
/// half of the firewall's tail (B, lab wave 2, 2026-09-28; `HotkeyTap` holds the
/// state, `WisprFlowSource` feeds it the rows).
///
/// The tail used to be a clock: every Wispr ⌘V within 10 s of the relay's
/// sentence going idle was dropped as *the relay's late paste*. In the lab that
/// ate **8 of his 8** own right ⌥⇧ sentences that landed in those 10 s, all of
/// them `formatted` by Wispr, all dropped with a log line only. Q19 (the original author's
/// Q7 = A) already said what his sentence is: his, pasted at the caret.
///
/// A ⌘V does not say which row it pastes. The rows do: Wispr creates a row at
/// the gesture, so his sentence has a row **newer than the relay's** seconds
/// before its ⌘V arrives. So the tail is keyed on rows, not the clock.
enum WisprOwnership {

    /// A ⌘V from Wispr: the relay's (drop — the row delivers) or not (pass).
    enum Verdict: Equatable {
        /// The relay's sentence, its late row, or the tail with no newer row seen.
        case relays(String)
        /// Not the relay's: Q9 (no relay sentence near) or his newer row in the tail.
        case passes(String)
    }

    /// - Parameters:
    ///   - since: the relay's gesture (0 = never owned).
    ///   - releasedAt: when its machine went idle (0 = still in flight).
    ///   - rowsHeld: rows the relay gave up on and still watches (Q2/Q14).
    ///   - foreignRow: a newer row the tail watch judged not the relay's (0 = none).
    static func verdict(now: Double, since: Double, releasedAt: Double, rowsHeld: Int,
                        foreignRow: Int64, tail: Double, ceiling: Double) -> Verdict {
        // **B2 (lab wave 3, 2026-09-28): his noted row outranks the rows the
        // relay still holds.** TX10 5/5: three NULL rows held for 5 min each
        // made every ⌘V of his "the relay's", in the tail and past it. Wispr
        // finalizes only its newest dictation, a held row is always older than
        // his noted one (a relay gesture resets the note), so it can no longer
        // paste — the ⌘V is his.
        if rowsHeld > 0 {
            if foreignRow > 0 { return .passes("row \(foreignRow) is newer than the relay's — his own sentence (the rows the relay still holds are older, and Wispr finishes only its newest)") }
            return .relays("a row the relay gave up on is still being watched")
        }
        guard since > 0, now - since < ceiling else { return .passes("no relay sentence near (Q9)") }
        if releasedAt == 0 { return .relays("the relay's sentence is in flight") }
        guard now - releasedAt < tail else { return .passes("past the relay's tail (Q9)") }
        if foreignRow > 0 { return .passes("row \(foreignRow) is newer than the relay's — his own sentence") }
        return .relays(String(format: "the relay's tail (%.1f s after idle), no newer row of his seen", now - releasedAt))
    }

    /// **Is this row his, not the relay's?** Asked by the tail watch of the
    /// newest `History` row.
    ///
    /// - Parameters:
    ///   - floor: the newest rowid the relay knows as its own or as older than
    ///     its gesture — max(its adopted row, the row on top at its chord).
    ///   - relayHadRow: whether the relay adopted a row for that sentence. When
    ///     it did not (a cold Wispr, no answer to the chord), a row that shows up
    ///     later may still be the relay's own, created late — so it also has to
    ///     have started at or after the relay's close.
    ///   - relayClosedAt: unix time the relay's sentence closed (its stop chord).
    ///   - relayCmdVSeen / sinceRelease: the relay's own ⌘V for its row is not
    ///     mistaken for his while it may still be coming — the row is his only
    ///     once the relay's ⌘V was seen or `pasteWait` has passed since idle.
    ///   - relayChords: unix times of the relay's own recent fn ⌃ Space posts
    ///     (`relayChordTimes`) — a row Wispr made in answer to one is the relay's.
    static func rowIsHis(rowid: Int64, startedAt: Double, floor: Int64, relayHadRow: Bool,
                         relayClosedAt: Double, relayCmdVSeen: Bool, sinceRelease: Double,
                         pasteWait: Double = 1.5, relayChords: [Double] = []) -> Bool {
        guard rowid > floor else { return false }
        if madeByRelayChord(startedAt: startedAt, chords: relayChords) { return false }
        // `startedAt` is whole seconds (strftime %s truncates): compare floors.
        if !relayHadRow, startedAt < relayClosedAt.rounded(.down) { return false }
        return relayCmdVSeen || sinceRelease >= pasteWait
    }

    // MARK: - B-risk (lab wave 3, TX6b): a row the relay's own chord made is not his

    /// **A row that opens within ~1 s after one of the relay's own chords is
    /// the relay's**, whatever the rowids say. TX6b: a chord storm desynced the
    /// relay and Wispr, Wispr's row 217 held the speech the relay meant to take,
    /// and the tail watch armed it as *his* — Wispr would have pasted it at the
    /// caret with the relay's approval. `startedAt` is whole seconds (strftime
    /// `%s` truncates), so the window opens at the chord's own second.
    static func madeByRelayChord(startedAt: Double, chords: [Double], window: Double = 1.0) -> Bool {
        guard startedAt > 0 else { return false }
        return chords.contains { startedAt >= $0.rounded(.down) && startedAt <= $0 + window }
    }

    private static let chordLock = NSLock()
    private static var chords: [Double] = []
    /// Called at the relay's own **start** chord, and at a stop chord for a
    /// sentence Wispr never answered (a toggle Wispr may read as a start) —
    /// never at an in-sync stop: his sentence 0.3 s after the relay's stop
    /// (TW8a, TX8b) must stay his.
    static func noteRelayChord(at t: Double = Date().timeIntervalSince1970) {
        chordLock.lock(); chords.append(t); if chords.count > 16 { chords.removeFirst(chords.count - 16) }; chordLock.unlock()
    }
    /// The relay's own chords of the last two minutes, oldest first.
    static var relayChordTimes: [Double] {
        let floor = Date().timeIntervalSince1970 - 120
        chordLock.lock(); defer { chordLock.unlock() }
        return chords.filter { $0 >= floor }
    }

    // MARK: - E (lab wave 3): the ghost microphone

    /// **Wispr opened its microphone with no sentence of anyone's behind it** —
    /// nil when it may be his. Lab wave 3 saw it three times, each after a relay
    /// chord a cold Wispr never answered: Wispr opens its microphone by itself
    /// 11–20 s later and holds it (once > 14 min), which blocks every start and
    /// the restart gate. It is the relay's own start, arriving late.
    ///
    /// - Parameters:
    ///   - unansweredAt: unix time of the relay's last chord Wispr did not answer
    ///     (no microphone for that sentence); 0 = none.
    ///   - hisKeysHeld: right ⌥ and right ⇧ (`61+60`, his push-to-talk) held now.
    ///   - hisChordAt: his own last Wispr chord the tap saw (hands-free); 0 = none.
    ///   - relayChordAt: the relay's own last start chord (unix time); 0 = none.
    ///     **A relay chord after the unanswered one disarms the watch** (E-FP,
    ///     lab wave 4): a microphone opening after it is that sentence's.
    ///   - relayCaptureInFlight: a relay sentence's capture is still waiting for
    ///     Wispr's row — its microphone may stay open past the relay's stop while
    ///     Wispr finishes (TW8a: dismissed 1 s after the stop, its row then dead).
    static func ghostMic(now: Double, micOpen: Bool, relayRecording: Bool, unansweredAt: Double,
                         hisKeysHeld: Bool, hisChordAt: Double, window: Double = 25,
                         relayChordAt: Double = 0, relayCaptureInFlight: Bool = false) -> String? {
        guard micOpen, !relayRecording, unansweredAt > 0, now - unansweredAt < window else { return nil }
        guard relayChordAt <= unansweredAt, !relayCaptureInFlight else { return nil }
        guard !hisKeysHeld else { return nil }
        guard hisChordAt < unansweredAt else { return nil }
        return String(format: "Wispr Flow opened its microphone %.0f s after a relay chord it never answered, with no chord or push-to-talk of his — the relay's own start, late", now - unansweredAt)
    }
}
