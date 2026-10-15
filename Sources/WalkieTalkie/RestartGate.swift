import CoreGraphics
import Foundation

/// **What a restart must never cut into, on any engine, and how long it waits
/// after his last move** (2026-09-28) — the pure half of `restartBlockers` and of
/// the `lastInputAt` / `lastInsertAt` stamps `GET /test/state` hands to
/// `tools/restart_gate.py`, apart so `swift test` can hold it to its rules.
///
/// the original author, 2026-09-28 18:39, after a restart landed while he was dictating:
/// *"someone just restarted the walkie while I was dictating. that should never
/// happen (while dictating or transcribing). restart is only possible after 5
/// secs of inactivity after the last insert of text."*
///
/// The relay's `busy` had nothing to say at 18:39:14: its last sentence had
/// landed at 18:37:51, no microphone of its own was open, and since Q9 step 2
/// (2026-09-28) a Wispr sentence he says on his own is not the relay's to track.
/// What was going on was him — at the keyboard since 18:37:38. So a restart now
/// waits on three things the relay did not look at: **Wispr's own microphone and
/// its History row** (here, into `busyWhy`), and **his hands** (`lastInputAt`,
/// gated by the script, `inactivity` seconds).
enum RestartGate {

    /// **Five seconds with nothing from him and nothing inserted** — the original author's
    /// number (quoted above). The script's ten quiet seconds after a delivery
    /// (2026-09-23, *"in case I routed the prompt to the wrong place"*) still
    /// stand; the effective wait is whichever is longer.
    static let inactivity: TimeInterval = 5

    /// A Wispr row still being worked on counts as a transcription in flight for
    /// this long after its gesture. Wispr's p99 round trip is 7.1 s and its max
    /// 13.7 s (`WisprHistory`); a row that never finishes (row 12814, left at
    /// `raw_transcript` for ever) must not make the app unrestartable.
    static let wisprRowFresh: TimeInterval = 60

    /// Statuses that mean Wispr is still working on the row — the same list as
    /// `helpers/wispr_loop.py`'s `BUSY_STATUSES`. `""` is NULL: the row is made
    /// at the gesture with no status.
    static let wisprBusyStatuses: Set<String> = ["", "processing", "recording", "transcribing"]

    /// Wispr Flow's side, read without asking Wispr anything.
    struct WisprReading: Equatable {
        /// Wispr's process has an input stream running (CoreAudio).
        var micOpen = false
        var rowId: Int64?
        var rowStatus: String?
        /// Unix time of the gesture that made the newest row.
        var rowStartedAt: TimeInterval?
    }

    /// **Why Wispr, on its own, makes a restart wait** — empty when it does not.
    static func wisprReasons(_ w: WisprReading, now: TimeInterval) -> [String] {
        var why: [String] = []
        if w.micOpen { why.append("Wispr Flow's microphone open") }
        if let status = w.rowStatus, wisprBusyStatuses.contains(status), let at = w.rowStartedAt {
            let age = now - at
            // A clock a second or two apart (the row is stamped by Wispr) is
            // still a fresh row; anything further in the future is not believed.
            if age < wisprRowFresh, age > -30 {
                why.append(String(format: "Wispr Flow transcribing (row %lld%@, %.0f s old)",
                                  w.rowId ?? 0, status.isEmpty ? "" : " " + status, max(0, age)))
            }
        }
        return why
    }

    /// **How long ago his hands last did something** — keys, modifiers, mouse
    /// buttons, drags, the wheel; a mouse that only moves is not counted. Read
    /// from the HID system state, i.e. hardware events only: this app's own
    /// synthetic paste is an insert (`lastInsertAt`), not him. Works with the tap
    /// dead, and needs no permission.
    static func secondsSinceHumanInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged,
                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp,
                                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min()
            ?? .infinity
    }

    /// The latest of several optional moments.
    static func latest(_ marks: Date?...) -> Date? {
        marks.compactMap { $0 }.max()
    }

    /// **Seconds the gate still has to wait for his inactivity**, 0 when it may
    /// go: `inactivity` after his last input, after the last insert and after the
    /// last dictation start or stop.
    static func inactivityLeft(now: Date, lastInput: Date?, lastInsert: Date?, lastDictationEdge: Date?) -> TimeInterval {
        guard let last = latest(lastInput, lastInsert, lastDictationEdge) else { return 0 }
        return max(0, inactivity - now.timeIntervalSince(last))
    }
}
