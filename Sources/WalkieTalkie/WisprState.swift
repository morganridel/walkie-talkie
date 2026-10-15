import Foundation

/// **Where the recogniser is in its own round trip** — the one vocabulary the
/// relay has for *a machine in another process is busy with my sentence*.
///
/// Source-agnostic on purpose, and on `DictationSource` rather than on
/// `WisprFlowSource`, for the reason the whole protocol exists: the chip, the
/// settle and the ring must not be able to tell which recogniser they are
/// serving. A local model has the same five answers — it is idle, it is opening
/// a device, it is hearing him, it is chewing, it is done — and the fact that
/// only Wispr has a *status string* to put inside two of them is a detail of the
/// payload, not a second shape.
///
/// The five, and what each one is actually a claim about:
///
/// | phase | the claim |
/// |---|---|
/// | `idle` | nothing is in flight |
/// | `warming` | the chord went out and **nothing has confirmed a microphone** |
/// | `listening` | the recogniser's process has a running input |
/// | `transcribing(status)` | the microphone is shut and the words are in flight |
/// | `done(status)` | the recogniser has finished, one way or another |
enum DictationPhase: Equatable {

    case idle
    /// The start chord has been posted and no input is running yet. Measured
    /// 2026-09-12/13: 324–674 ms warm, **5.0–6.0 s** cold. This is the whole of
    /// that gap, named.
    case warming
    case listening
    /// The recogniser's own word for what it is doing, while it is doing it —
    /// for Wispr Flow the `History` row's `status`: `""`, `raw_transcript`,
    /// `processing`. Empty for a source that has nothing to say.
    case transcribing(String)
    /// The terminal status: `formatted`, `dismissed`, `empty`, `no_audio`,
    /// `error` — or `timeout` when nothing ever answered.
    case done(String)

    /// The word `GET /test/state` and `relay.log` use. The status rides beside
    /// it rather than inside it, so an assertion on the phase is not an
    /// assertion on Wispr's vocabulary.
    var name: String {
        switch self {
        case .idle: return "idle"
        case .warming: return "warming"
        case .listening: return "listening"
        case .transcribing: return "transcribing"
        case .done: return "done"
        }
    }

    /// The recogniser's own status, when it has one.
    var status: String {
        switch self {
        case .transcribing(let s), .done(let s): return s
        default: return ""
        }
    }

    /// Is a microphone open as far as this phase is concerned.
    var isListening: Bool { self == .listening }

    /// Is the recogniser still expected to answer. The settle rides this: a
    /// sentence whose row says `processing` has not been lost, it is late.
    var isWaitingForWords: Bool {
        if case .transcribing = self { return true }
        return false
    }
}

/// **A measured state machine for Wispr Flow**, driven by three inputs that
/// disagree with each other, and written because on 2026-09-13 the relay
/// believed all three.
///
/// ## Why a machine, and why now
///
/// Until today the relay's whole model of Wispr was one boolean read off
/// CoreAudio (`WisprWatch`) and one row read off SQLite (`WisprHistory`), and
/// nothing joined them. Both failures of 2026-09-13 are what that costs:
///
/// - `WisprWatch` is **0–6 s late and misses short dictations entirely**. It
///   publishes only when the value it re-reads *differs* from the last one, so a
///   sentence shorter than its own lag produces neither an opening nor a closing
///   edge. With Wispr's microphone pinned to the Loopback device `🎓 TO Wispr`
///   (whose physical source keeps the stream warm) it saw **no edge at all** in
///   five successful runs.
/// - Everything the wrap hangs off that closing edge — the swallow window, the
///   `History` poll, the settle — therefore never armed, and `speculativeGrace`
///   fired *Wispr ignored the chord* about a sentence that had already been
///   pasted into Word.
///
/// So the relay stops believing one signal and starts **joining three**, each
/// with its own latency, and says what it is joining:
///
/// | input | what it proves | measured latency |
/// |---|---|---|
/// | the chord this app posts | a dictation was *asked for* | 0 (it is the clock) |
/// | a 100 ms poll of `kAudioProcessPropertyIsRunningInput` | a microphone **is** open | the poll's own tick |
/// | `WisprWatch`'s CoreAudio notification | the same fact, pushed | 0–6 s, and sometimes never |
/// | the `History` row at 150 ms | Wispr **has the sentence** | row created at the gesture |
///
/// The poll and the notification are deliberately kept as two inputs rather than
/// collapsed into the faster one: the lag between them is a number the next
/// feature needs (the original author's replay buffer has to know when Wispr is *ready*), and
/// a number nobody measures is a number that drifts. `lags` is that measurement
/// and it is in `GET /test/state`.
///
/// ## It owns nothing
///
/// No timers, no CoreAudio, no SQLite, no AppKit. Inputs in, phase out, a
/// callback on every transition — which is what makes
/// `POST /test/wispr-state/simulate` able to run a scripted day through it in a
/// millisecond and assert on the transitions, with no microphone and no Wispr.
///
/// **Main thread only.** Every caller is already there (`WisprFlowSource` hops
/// everything to main at the boundary, which is `DictationSource`'s rule), and
/// the simulate route hops with them.
final class WisprState {

    // MARK: - Wispr's vocabulary

    /// **The statuses that are not an answer** — Wispr is still working.
    ///
    /// `""` is the row as created at the gesture (NULL: the stop path has not
    /// run), `processing` the row after the stop, with its audio and `duration`.
    ///
    /// **`raw_transcript` is not here since 2026-09-28 (batch 3).** It was
    /// listed as progress from 2026-09-13; Wispr's own code
    /// (`evals/plan/wispr/integration-surfaces.md`, item 3) writes it only in
    /// the *final* update — the formatter did not finish, or the OpenAI
    /// fallback answered — and lists it in its own *pasteable* and *ok* sets.
    /// Read as progress it cost a 0.8 s grace with words in it
    /// (`rawTextSettled`, deleted) and 8 s without (`silenceCeiling`).
    static let intermediateStatuses: Set<String> = ["", "recording", "processing"]

    /// **The statuses that end a dictation**, and what each means.
    ///
    /// `formatted` is the ordinary one and carries `pastedText`;
    /// `extension_paste` / `extension_other` are the same thing from Wispr's
    /// browser extension. `dismissed` is his ⌃Escape, `empty` / `no_audio` a
    /// sentence with nothing in it, `error` Wispr's own failure. Batch 3
    /// (2026-09-28), from Wispr's own code: `raw_transcript`, `fallback`,
    /// `verification_failed`, `timeout`.
    static let terminalStatuses: Set<String> =
        ["formatted", "extension_paste", "extension_other", "dismissed", "empty", "no_audio", "error",
         "raw_transcript", "fallback", "verification_failed", "timeout"]

    /// **The terminal statuses whose text is the sentence** — Wispr's own
    /// *pasteable* set `[Formatted, RawTranscript, VerificationFailed,
    /// ExtensionPaste, Fallback]`, plus `extension_other`, which the relay has
    /// always delivered. One of these **with no text** is a sentence Wispr
    /// heard nothing in: it ends as a failure at once (Q14: the relay's own
    /// recording stands in), never as a wait.
    static let pasteableStatuses: Set<String> =
        ["formatted", "raw_transcript", "verification_failed", "extension_paste", "fallback", "extension_other"]

    /// **What the relay knows about a row it is waiting on** — the inputs of
    /// `deadRow`, all read by the caller (no SQLite, no clock here).
    struct RowFacts {
        var rowid: Int64
        var status: String
        /// `History.duration`: written by Wispr's stop path, nil while NULL.
        var duration: Double?
        /// The newest rowid in `History` now.
        var newestRowid: Int64
        /// Wispr's main pid now (0 = not seen) and when the row was adopted.
        var pidNow: Int32 = 0
        var pidAtAdoption: Int32 = 0
        /// When the relay posted its own dismiss (⌃Escape) for this row; 0 = never.
        var dismissedAt: Double = 0
        /// When the relay's microphone closed for this sentence; 0 = still open.
        var closedAt: Double = 0
        /// Wispr's microphone open now (the CoreAudio sample).
        var wisprMicOpen = false
        var now: Double
    }

    /// **A row Wispr will never finish** (batch 3, 2026-09-28), or nil while it
    /// still may. From Wispr's own code (`integration-surfaces.md`, item 3):
    ///
    /// - one live dictation at a time: a NULL / `processing` row with a newer
    ///   row above it was superseded (*"Skipping finalization — dictation was
    ///   superseded while transcribing"*) and stays as it is for ever;
    /// - a different Wispr process never heard of it;
    /// - a dismiss during processing abandons the result — still open 1 s after
    ///   the relay's own ⌃Escape, it is dead (and a dismiss under 0.5 s of audio
    ///   writes nothing at all, so NULL stays NULL);
    /// - NULL means the stop path never ran: 3 s after the close, with no
    ///   `duration` and Wispr's microphone shut, it is not going to.
    ///
    /// Replaces Q24's blind *wait while `processing`, up to 300 s*: what is
    /// left waiting is a row that can still finish, and `workingCeiling` (40 s,
    /// Wispr's max e2e is 36 s) bounds even that.
    static func deadRow(_ f: RowFacts) -> String? {
        guard !isTerminal(f.status) else { return nil }
        let open = f.status.isEmpty || f.status == "processing"
        let shown = f.status.isEmpty ? "NULL" : f.status
        if f.pidAtAdoption != 0, f.pidNow != 0, f.pidNow != f.pidAtAdoption {
            return "Wispr Flow is pid \(f.pidNow) now; row \(f.rowid) belongs to pid \(f.pidAtAdoption)"
        }
        if open, f.closedAt > 0, f.newestRowid > f.rowid {
            return "row \(f.rowid) is still \(shown) and row \(f.newestRowid) is newer — Wispr never finishes a superseded dictation"
        }
        if open, f.dismissedAt > 0, f.now - f.dismissedAt >= dismissGrace {
            return String(format: "row %lld is still %@ %.1f s after the relay's dismiss — Wispr abandons a dismissed dictation",
                          f.rowid, shown, f.now - f.dismissedAt)
        }
        if f.status.isEmpty, f.duration == nil, f.closedAt > 0, f.now - f.closedAt > nullStopCeiling, !f.wisprMicOpen {
            return String(format: "row %lld is still NULL with no duration %.1f s after the close — Wispr's stop path never ran",
                          f.rowid, f.now - f.closedAt)
        }
        return nil
    }
    /// Still open this long after the relay's own dismiss → dead.
    static let dismissGrace: Double = 1

    /// **The relay's stop chord did not take** (2026-10-01) — the row still
    /// NULL, no `duration`, and Wispr's microphone still open, `stopTakesWithin`
    /// after the chord: Wispr is still listening. The one NULL row `deadRow`
    /// keeps waiting on (its microphone is open), and nothing else would ever
    /// end it. Measured on 17:31:00 that day: a clean chord (*"the wire was
    /// bare"*), row 18156 listening on for 435 s until the original author dismissed it by
    /// hand, every dictate gesture refused meanwhile (*"Wispr Flow's microphone
    /// is already open"*) and the restart gate shut. 9 of 536 relay stops in the
    /// log are like it; the other 527 left NULL in ≤ 453 ms (p50 172, p90 221).
    static func stopWasLost(status: String, duration: Double?, wisprMicOpen: Bool) -> Bool {
        status.isEmpty && duration == nil && wisprMicOpen
    }
    /// How long a taken stop needs to show on the row: 2.6 × the slowest of 527.
    static let stopTakesWithin: Double = 1.2
    /// Still NULL this long after the close → the stop path never ran.
    static let nullStopCeiling: Double = 3

    /// A status nobody has seen before ends the dictation rather than hanging
    /// it, which is what the code did before there was a machine — but it says
    /// so in the log, because the alternative (treat the unknown as progress)
    /// turns one new Wispr status into every dictation waiting out 30 s.
    static func isTerminal(_ status: String) -> Bool { !intermediateStatuses.contains(status) }

    // MARK: - What it is

    private(set) var phase: DictationPhase = .idle
    /// When the current phase began.
    private(set) var since: CFAbsoluteTime
    /// When the start chord went out — the zero every lag is measured from.
    private(set) var chordAt: CFAbsoluteTime = 0
    /// **Whether a chord has been seen at all**, and not `chordAt > 0`.
    ///
    /// Found by the simulator the hour it was written: `POST
    /// /test/wispr-state/simulate` starts its fake clock at zero, so *the chord
    /// went out at t=0* and *no chord has gone out* were the same test, and the
    /// route answered with null lags and no offsets on a script that had both.
    /// Wall-clock time is never zero, so the real path had hidden it — which is
    /// exactly the class of bug a machine with an injectable clock exists to
    /// find.
    private(set) var hasChord = false
    /// Wispr's row for this dictation, once one has been found.
    private(set) var row: Int64?
    /// The row's last-read status, whatever the phase.
    private(set) var status = ""

    /// **How long each of the two microphone signals took to say the same
    /// thing**, measured from the start chord. Nil until that signal has spoken;
    /// `notifyMs` stays nil for a dictation the notification never saw at all,
    /// which is the 2026-09-13 finding in one field.
    private(set) var pollMs: Double?
    private(set) var notifyMs: Double?

    /// Every phase this dictation has been in, oldest first, with the moment it
    /// entered. Kept for the whole dictation and replaced at the next chord —
    /// it is a few tuples, and it is the only thing that can answer *in what
    /// order did the three signals arrive* after the fact.
    private(set) var transitions: [(phase: DictationPhase, at: CFAbsoluteTime, why: String)] = []

    /// Called on every change, with the phase left, the phase entered and why.
    var onTransition: ((DictationPhase, DictationPhase, String) -> Void)?

    /// Whether the 100 ms input poll should be running. There is no case for
    /// polling CoreAudio all day: the answer only matters between the chord and
    /// the words.
    var wantsPoll: Bool {
        switch phase {
        case .warming, .listening, .transcribing: return true
        case .idle, .done: return false
        }
    }

    /// The clock, injectable so `POST /test/wispr-state/simulate` can run a
    /// scripted sequence with a clock of its own rather than sleeping through
    /// the real one.
    private let now: () -> CFAbsoluteTime

    init(now: @escaping () -> CFAbsoluteTime = { CFAbsoluteTimeGetCurrent() }) {
        self.now = now
        self.since = now()
    }

    // MARK: - Inputs

    /// **The start chord went out** — this app posted `fn ⌃ Space`, or the tap
    /// saw the original author post it. The clock starts here and everything else is measured
    /// against it.
    func startChord(_ why: String) {
        chordAt = now()
        hasChord = true
        row = nil
        status = ""
        pollMs = nil
        notifyMs = nil
        transitions = []
        wisprCloseAt = nil
        wisprCloseBy = ""
        wisprExitAt = nil
        wisprAliveAt = nil
        enter(.warming, why)
    }

    /// **The relay's own stop** — the 🔼 click, ⌘⌃D, the second 🔼→, the end of
    /// a `/test` run. Since 2026-09-13 this and not the CoreAudio edge is what
    /// closes the listening phase: the edge is 0–6 s late and sometimes never
    /// comes, and a ring that waits for it is a ring that stands over a sentence
    /// that has already been delivered.
    func stopChord(_ why: String) {
        switch phase {
        case .warming, .listening: enter(.transcribing(status), why)
        default: return
        }
    }

    /// The 100 ms poll of Wispr's process objects.
    func poll(_ on: Bool) { microphone(on, from: "poll") }

    /// `WisprWatch`'s CoreAudio notification. Kept as a second source for one
    /// reason: it is the only one that can be *earlier* than a tick, and the lag
    /// between the two is what the next feature needs.
    func notify(_ on: Bool) { microphone(on, from: "notification") }

    private func microphone(_ on: Bool, from source: String) {
        if on {
            let lag = hasChord ? (now() - chordAt) * 1000 : nil
            if source == "poll", pollMs == nil { pollMs = lag }
            if source == "notification", notifyMs == nil { notifyMs = lag }
            switch phase {
            case .warming, .idle: enter(.listening, "\(source) saw the microphone")
            default: return
            }
        } else {
            // **A microphone that closes while we still thought it was warming
            // never opened.** Nothing to report; the row is the only thing that
            // can still say whether Wispr heard anything.
            guard phase == .listening else { return }
            enter(.transcribing(status), "\(source) saw the microphone close")
        }
    }

    /// **Wispr's own row for this dictation.** Pass nil for *there is no row
    /// yet*; the row is created at the gesture, so its appearance is itself a
    /// confirmation that Wispr took the chord — the one the microphone signals
    /// failed to give five times out of five on 2026-09-13.
    func sawRow(_ rowid: Int64, status newStatus: String) {
        let adopted = row != rowid
        row = rowid
        status = newStatus
        if adopted, phase == .warming {
            // Wispr has a row for a chord no microphone confirmed. That is not
            // an ignored chord — it is a dictation this process cannot hear.
            enter(.listening, "Wispr created a row")
        }
        if Self.isTerminal(newStatus) {
            guard phase != .done(newStatus) else { return }
            enter(.done(newStatus), "the row is \(newStatus)")
            return
        }
        // Progress, not an answer: keep waiting, but say which kind of waiting.
        if case .transcribing(let had) = phase, had != newStatus {
            enter(.transcribing(newStatus), "the row is \(newStatus)")
        }
    }

    /// **The words arrived, by whatever route.** Measured on the first real run
    /// (2026-09-13, 23:02): the ⌘V landed 790 ms after the stop while the row
    /// still said `processing`, so the machine went straight from `transcribing`
    /// to `idle` and the transition log never said *this one finished*. It says
    /// so now, and it says **how** — `done(wispr-cmdv)` when Wispr's own row has
    /// not caught up, `done(formatted)` when it has, which is exactly the
    /// distinction worth keeping.
    func delivered(via: String) {
        switch phase {
        case .idle, .done: return
        default: enter(.done(Self.isTerminal(status) && !status.isEmpty ? status : via),
                       "delivered via \(via)")
        }
    }

    /// Nothing came back inside `captureTimeout`.
    func timedOut(_ why: String) {
        switch phase {
        case .idle, .done: return
        default: enter(.done("timeout"), why)
        }
    }

    /// The dictation is over and its record has been read — back to rest.
    func reset(_ why: String) {
        guard phase != .idle else { return }
        enter(.idle, why)
    }

    // MARK: - Batch 5: Wispr's microphone closing under a relay sentence

    /// **What a Wispr-side close of a relay sentence turns out to be** (batch 5,
    /// 2026-09-29). Lab wave 5, TW20 / TQ2 on a real SIGKILL: the 100 ms poll saw
    /// Wispr's microphone close and the kernel's exit event came **0.35–0.39 s
    /// later** — the dying process tears down its audio before it is a zombie,
    /// and batch 4's 0.3 s grace had already run out and closed the relay's own
    /// take (0.5 s voiced, Recover only). The order is the whole question, so it
    /// is decided here, on this machine's injectable clock, and not in timers.
    enum WisprCloseVerdict: Equatable {
        /// Not known yet: the exit may still come — ask again at `until`.
        case pending(until: CFAbsoluteTime)
        /// Wispr's process is gone or going: not his stop — the relay's own
        /// recording carries the sentence on to his stop (Q14).
        case quit
        /// Wispr outlived the grace (or its row moved): it ended the dictation itself.
        case wisprEnded
    }
    /// How long a Wispr-side close waits for the exit before it is taken as
    /// Wispr ending the dictation. Measured exit-after-close on the VM: 0.35 and
    /// 0.39 s; batch 4's 0.3 s lost both. `P_WEXIT` normally answers at the
    /// close itself (`ProcessClock.isDyingOrGone`) — this is the belt.
    static let quitCloseGrace: Double = 1.0

    /// When the first Wispr-side close of this sentence was seen, and by whom.
    private(set) var wisprCloseAt: CFAbsoluteTime?
    private(set) var wisprCloseBy = ""
    /// When Wispr's process was told exited (the kernel's event, or `fakeExit`).
    private(set) var wisprExitAt: CFAbsoluteTime?
    /// When Wispr showed it was alive after the close (its row moved: its stop path ran).
    private(set) var wisprAliveAt: CFAbsoluteTime?

    /// **A Wispr-side close (the poll, the CoreAudio edge) of a relay sentence.**
    /// `processGone`: the kernel already says the process is exiting or gone.
    /// An exit already seen wins at once, whichever came first.
    func wisprSideClose(by source: String, processGone: Bool) -> WisprCloseVerdict {
        if wisprCloseAt == nil {
            wisprCloseAt = now()
            wisprCloseBy = source
        }
        return wisprCloseDue(processGone: processGone)
    }

    /// **Wispr's process exited.** Always a quit for a sentence still recording;
    /// recorded so a close that arrives after it (or is still waiting) is one too.
    @discardableResult
    func wisprProcessExited() -> WisprCloseVerdict {
        if wisprExitAt == nil { wisprExitAt = now() }
        return .quit
    }

    /// **Wispr's input came back before the close was decided** (2026-09-29):
    /// a blip, not an end — the next close of this sentence starts its own grace.
    func wisprInputReopened() {
        guard wisprExitAt == nil else { return }
        wisprCloseAt = nil
        wisprCloseBy = ""
        wisprAliveAt = nil
    }

    /// Wispr's row moved after the close — its own stop path ran, so it is alive.
    func wisprAliveAfterClose() {
        if wisprAliveAt == nil { wisprAliveAt = now() }
    }

    /// **The verdict now** — at the grace's deadline, or earlier when something
    /// new is known. The exit (or a dying process) beats everything; a row that
    /// moved says Wispr lived through it; otherwise the grace decides.
    func wisprCloseDue(processGone: Bool) -> WisprCloseVerdict {
        if processGone || wisprExitAt != nil { return .quit }
        guard let at = wisprCloseAt else { return .wisprEnded }
        if wisprAliveAt != nil { return .wisprEnded }
        let until = at + Self.quitCloseGrace
        return now() >= until ? .wisprEnded : .pending(until: until)
    }

    // MARK: - Transitions

    private func enter(_ next: DictationPhase, _ why: String) {
        guard next != phase else { return }
        let previous = phase
        phase = next
        since = now()
        transitions.append((next, since, why))
        Log.info(line(from: previous, to: next, why: why))
        onTransition?(previous, next, why)
    }

    /// **One line per transition, and the `listening` one carries both lags** —
    /// which is the measurement this whole file was written to take.
    private func line(from previous: DictationPhase, to next: DictationPhase, why: String) -> String {
        var out = "wispr state: \(previous.name) → \(next.name)"
        if !next.status.isEmpty { out += "(\(next.status))" }
        out += " — \(why)"
        if next == .listening {
            out += String(format: ", poll saw it %@ after the chord, notification %@",
                          Self.ms(pollMs), Self.ms(notifyMs))
        } else if hasChord {
            out += String(format: " (%.0f ms after the chord)", (since - chordAt) * 1000)
        }
        return out
    }

    private static func ms(_ value: Double?) -> String {
        guard let value else { return "never" }
        return String(format: "%.0f ms", value)
    }

    // MARK: - The read

    /// `GET /test/state` → `wispr`. Everything an assertion needs about the
    /// recogniser's own round trip, from state the machine is already keeping.
    func snapshot() -> [String: Any] {
        var out: [String: Any] = [
            "state": phase.name,
            "since": Outbox.iso(Date(timeIntervalSinceReferenceDate: since)),
            "status": phase.status.isEmpty ? status : phase.status,
            "lags": ["pollMs": pollMs.map { NSNumber(value: $0.rounded()) } ?? NSNull(),
                     "notifyMs": notifyMs.map { NSNumber(value: $0.rounded()) } ?? NSNull()],
            // Milliseconds into the dictation, which is the reading a fake clock
            // can also give — `since` is a wall-clock stamp and reads as 2001
            // under the simulator.
            "sinceMs": hasChord ? NSNumber(value: Int(((since - chordAt) * 1000).rounded())) : NSNull(),
        ]
        out["row"] = row.map { NSNumber(value: $0) } ?? NSNull()
        out["transitions"] = transitions.map { t -> [String: Any] in
            var obj: [String: Any] = ["state": t.phase.name, "why": t.why]
            if !t.phase.status.isEmpty { obj["status"] = t.phase.status }
            if hasChord { obj["atMs"] = Int(((t.at - chordAt) * 1000).rounded()) }
            return obj
        }
        return out
    }
}

/// **The state machine's unit test, run over HTTP** — `POST
/// /test/wispr-state/simulate`.
///
/// The package is a single `executableTarget` with a `main.swift` in it, which
/// is the one shape an XCTest bundle cannot `@testable import` without a fight,
/// and adding a library target to split it would move every file in the app for
/// one test. So the test harness is a route, and it is a route with the two
/// properties a unit test needs and an integration test cannot have: it runs on
/// a **fresh** machine with a **fake clock**, so a sequence spanning six seconds
/// of Wispr's worst warm-up is asserted in under a millisecond and touches
/// nothing in the running relay.
///
/// ```
/// curl -s localhost:8917/test/wispr-state/simulate -d '{"steps":[
///   {"input":"chord","atMs":0},
///   {"input":"poll","on":true,"atMs":412},
///   {"input":"notify","on":true,"atMs":5200},
///   {"input":"stop","atMs":9000},
///   {"input":"row","status":"raw_transcript","atMs":9100},
///   {"input":"row","status":"processing","atMs":9400},
///   {"input":"row","status":"formatted","atMs":11200}]}'
/// ```
///
/// …answers `{"final":"done","status":"formatted","lags":{"pollMs":412,
/// "notifyMs":5200},"transitions":[…]}` — which is the whole of the 2026-09-13
/// finding as an assertion: **one** `listening` transition, at 412 ms, with the
/// notification 4.8 s behind it and unable to change anything.
enum WisprStateSimulation {

    /// - Parameter steps: `{"input": "chord" | "stop" | "poll" | "notify" |
    ///   "row" | "timeout" | "reset", "on": Bool, "status": String,
    ///   "rowid": Int, "atMs": Int}`. `atMs` is milliseconds on the fake clock
    ///   from the start of the script; steps are applied in the order given and
    ///   a missing `atMs` keeps the previous instant.
    static func run(_ steps: [[String: Any]]) -> [String: Any] {
        var clock: CFAbsoluteTime = 0
        let machine = WisprState(now: { clock })
        var refused: [String] = []

        for step in steps {
            if let at = step["atMs"] as? Int { clock = Double(at) / 1000 }
            else if let at = step["atMs"] as? Double { clock = at / 1000 }
            let input = (step["input"] as? String ?? "").lowercased()
            let on = step["on"] as? Bool ?? true
            let status = step["status"] as? String ?? ""
            let rowid = Int64(step["rowid"] as? Int ?? 1)
            switch input {
            case "chord", "start": machine.startChord(step["why"] as? String ?? "simulated chord")
            case "stop": machine.stopChord(step["why"] as? String ?? "simulated stop")
            case "poll": machine.poll(on)
            case "notify", "notification": machine.notify(on)
            case "row": machine.sawRow(rowid, status: status)
            case "timeout": machine.timedOut(step["why"] as? String ?? "simulated timeout")
            case "reset": machine.reset(step["why"] as? String ?? "simulated reset")
            default: refused.append(input.isEmpty ? "(none)" : input)
            }
        }

        var out = machine.snapshot()
        out["final"] = machine.phase.name
        if !refused.isEmpty { out["unknownInputs"] = refused }
        return out
    }
}
