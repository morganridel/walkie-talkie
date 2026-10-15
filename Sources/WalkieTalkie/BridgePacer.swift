import Foundation

/// **How the bridge gets Wispr back to live after starting late** (2026-09-29).
///
/// the original author: *"the voice is captured the moment I start dictating and then is fed
/// with a bit of an offset … to Wispr Flow … We could also try a speed up of the
/// voice to 1.1x for a few seconds to recover … after a few seconds there should
/// be no lag between my voice and what Wispr hears."*
///
/// Wispr opens its input 0.3–0.7 s after the gesture when warm, 5–6 s cold
/// (`WisprState`'s witness table). The relay records from the gesture, so it
/// holds that head and hands it over the moment Wispr is listening — a lag, not
/// a loss. Three things take the lag back out, cheapest first:
///
/// 1. **The silence before his first word is cut at the hand-over**
///    (`trimStart`): the gap between the click and the first syllable is most
///    of a warm Wispr's lag, and it carries nothing. `leadPad` of it is kept so
///    the first consonant is not clipped.
/// 2. **While lagging, a pause is shortened to `keptGap`** (`admit`) — a
///    recogniser needs to hear a pause, not its length.
/// 3. **While lagging, the player runs faster** (`rate`) through a time-pitch
///    unit, so his voice is faster but not higher: `catchUpRate` (1.1×) near
///    live, rising with the lag to `maxRate` at `rampLag` behind.
///
/// **The ceiling is Wispr's, and past it he waits** (2026-09-30). Measured in
/// `evals/wispr-catchup/`: at a flat 1.1× a start 5 s late took a median 7.9 s
/// to reach live, so a short sentence was heard sped up from end to end — and a
/// stop one second after Wispr started listening leaves ~6 s of him queued.
/// the original author: *"accelerarea asta trebuie să aibă un anumit plafon, peste care
/// probabil Wispr să nu mai poată înțelege … îmi asum această procesare
/// întârziată"*. So the speed is capped at the fastest Wispr still transcribes
/// (`maxRate`, `WT_BRIDGE_MAX_RATE`), and whatever that cannot absorb is drained
/// after his stop, however long it takes (`WisprFlowSource.bridgeDrainSeconds`).
///
/// **"Live" is `synced` of queue, not zero** — the recorder hands over ~85 ms
/// buffers, so a queue running faster than it is filled starves between them,
/// and a starved player puts silence into the middle of a word. At `synced`
/// the rate is back to 1.0 and the queue refills to about one buffer.
///
/// Pure: no audio, no clock — `BridgePacerTests` drives it.
struct BridgePacer {
    struct Tuning {
        var catchUpRate: Float = 1.1
        /// The fastest Wispr is fed — **1.25, measured** (2026-09-30,
        /// `evals/wispr-catchup/` *Wispr's ceiling*): 12 of his clips played whole
        /// at 1.25× stayed within Wispr's own noise, his fastest Romanian (7–9
        /// words per voiced second) included; at 1.35× one of those went from
        /// 0.06 to 0.51 WER, and 1.5× cost the tail on two of eight.
        var maxRate: Float = 1.25
        /// How far behind the ramp reaches `maxRate`.
        var rampLag: TimeInterval = 3
        var synced: TimeInterval = 0.2
        var leadPad: TimeInterval = 0.3
        var keptGap: TimeInterval = 0.25
    }

    let tuning: Tuning
    /// The silence played (or dropped) since the last voiced chunk.
    private(set) var silentRun: TimeInterval = 0
    /// Everything `admit` refused, for the log line.
    private(set) var dropped: TimeInterval = 0

    init(tuning: Tuning = Tuning()) { self.tuning = tuning }

    /// **Where the held backlog starts playing** — the index of the first chunk
    /// kept. `leadPad` before the first voiced chunk; with no voiced chunk at
    /// all, the last `leadPad` (he has not started yet — keep only the tail).
    static func trimStart(_ chunks: [(seconds: TimeInterval, voiced: Bool)], pad: TimeInterval) -> Int {
        guard !chunks.isEmpty else { return 0 }
        let anchor = chunks.firstIndex { $0.voiced } ?? chunks.count
        var start = anchor, kept: TimeInterval = 0
        while start > 0, kept < pad {
            start -= 1
            kept += chunks[start].seconds
        }
        return start
    }

    /// One chunk, backlog or live, arriving with `lag` seconds already queued.
    /// False = drop it: a silent chunk past `keptGap` of a pause, while lagging.
    mutating func admit(seconds: TimeInterval, voiced: Bool, lag: TimeInterval) -> Bool {
        if voiced { silentRun = 0; return true }
        silentRun += seconds
        guard lag > tuning.synced, silentRun > tuning.keptGap else { return true }
        dropped += seconds
        return false
    }

    /// The player's speed for this much queued: 1 at live, `catchUpRate` just
    /// behind it, then linear in the lag up to `maxRate` at `rampLag`.
    func rate(lag: TimeInterval) -> Float {
        guard lag > tuning.synced else { return 1 }
        let top = max(tuning.maxRate, tuning.catchUpRate)
        let span = tuning.rampLag - tuning.synced
        guard span > 0, top > tuning.catchUpRate else { return tuning.catchUpRate }
        let f = Float(min(1, (lag - tuning.synced) / span))
        return tuning.catchUpRate + (top - tuning.catchUpRate) * f
    }
}
