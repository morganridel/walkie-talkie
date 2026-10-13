# Walkie Talkie — CoreAudio / AVAudioEngine lifecycle review (2026-10-13)

Read-only review. Nothing was edited, built or restarted. All paths are under
`/Users/victorrentea/workspace/walkie-talkie/Sources/WalkieTalkie/` unless stated.

Sources consulted: `CLAUDE.md`, `.claude/rules/whisper-and-corpus.md`, `.claude/rules/dictation-source.md`,
`docs/journal.md` (2026-09-07 recursive lock, 2026-09-19 main-thread bind freeze, 2026-09-24 removeTap/lock
inversion, 2026-09-28 restartTap/ZeroPeakWatch, 2026-09-30 bridge NSException + ObjCTry), the crash report
`~/Library/Logs/DiagnosticReports/Walkie Talkie-2026-10-13-182955.ips`, the retired report
`…/Retired/Walkie Talkie-2026-10-09-142455.ips`, `~/.walkie-talkie/relay.log` lines 357870–357930 and the
stall markers of 21:54–22:27, and all 24 `~/.walkie-talkie/hangs/hang-2026-10-13-*.txt`.

---

## 1. Root cause of the 18:29 crash

### 1.1 What the report actually says

- **Capture time is 18:29:44.92**, not 18:29:55 (`captureTime` in the JSON; the file name is when
  ReportCrash wrote it). The crash is therefore simultaneous with the last log line of the old instance
  (`18:29:44 … Wispr is dismissed (⌃Escape)` → `endOwnFeed`), not 11 s after it.
- Faulting thread 22, `com.apple.audio.IOThread.client`: `pc = 0x0`, `far = 0x0`, ESR *Instruction Abort,
  translation fault* — a **call through a NULL pointer**. Frame 1 is `HALC_ProxyIOContext::IOWorkLoop()
  + 11636` with **no intermediate frame**: the work loop itself made the call. Registers: `x0 = 0`
  (the callee's first argument — the object/`this` of the entry being invoked — is also NULL), `x1 == sp`,
  `x3 = 1`, `x4 = 512` (512 = an IO buffer frame count). This is the signature of the HAL IO thread
  invoking an **IOProc entry whose object/function pointer has been torn down** (an `AudioDeviceIOProcID`
  destroyed, or an AUHAL's IO context being re-created, while the loop was mid-cycle). It is *not* a Swift
  closure gone nil: Swift optional closures are never called through 0 by CoreAudio; AVFAudio's tap
  mechanism would appear as `AVAudioNodeTap`/`RealtimeMessenger` frames, and none are present.
- Thread 21 is a **second** `IOThread.client`, parked in `caulk::mach::semaphore::wait_signal_or_error`
  inside `IOWorkLoop()` — a healthy IO thread between cycles. Two IO threads = two HAL IO contexts =
  two devices with IO running in this process at that instant.
- Thread 15, queue `ro.victorrentea.wispr-relay.wispr-meter`:
  `WisprFlowSource.endOwnFeed` (WisprFlowSource.swift:2582) → `MicRecorder.stopMetering` (:631) →
  `stop()` (:1052) → `close()` (:1081) → `-[AVAudioEngine stop]` → `AVAudioEngineImpl::Stop → Pause →
  Graph::_Stop → AUInterfaceIOV3::StopIO → AudioOutputUnitStop → … → usleep`. That `usleep` is AUHAL's
  stop handshake: it spins waiting for **its own IO thread to leave the IOProc**. The thread it is waiting
  on is the one that just jumped to 0.
- Nothing else in the process was inside CoreAudio/AVFAudio. Thread 19 (`deliver`) and 16/20 are the
  terminal `osascript` delivery of the 107-char reply; thread 0 (main) is idle in the run loop; no
  `mic.restart` queue thread, no `audio-bridge` queue thread, no `shot-marker` thread exists in the dump.

### 1.2 Which IO context thread 22 belonged to

The two IO contexts alive at 18:29:44.9 were (from the log and the code):

| context | device | owner | started | state at the crash |
|---|---|---|---|---|
| A | input **Wireless Mic Rx** (DJI) | `WisprFlowSource.meter` (`MicRecorder.engine`, the **same `AVAudioEngine` object reused since launch**) | 18:29:42 `mic: metering through Wireless Mic Rx` (`feedOwnSentence` → `startMetering`) | being stopped by thread 15 |
| B | output **From Walkie Mirror** | `WisprFlowSource.bridge` (`AudioBridge.engine`, a fresh engine per `start`) | 18:29:42 `🔀 audio bridge up` | running; `bridge.stop()` is the *next* line of `endOwnFeed` (:2583), not reached |

**Thread 22 is context A (the meter's input engine).** Evidence: `AudioOutputUnitStop`'s `usleep` is the
stop side of the stop/IO-thread handshake for exactly that unit, and the crash fired during that wait; the
other IO thread (21) is idle between cycles, which is what the bridge's output context looks like while
nobody schedules buffers into it (the meter had just had its `onBuffer` cut at :2581). Confidence that the
crashing thread is the meter engine's: **high (~85 %)**. The alternative — the Mirror's context being torn
by the driver as Wispr closed From Walkie's input at the same instant (⌃Escape) — cannot be excluded from
the dump alone, but it would leave the stop handshake on thread 15 unexplained (it was waiting on *its*
thread, and its thread is the one that died).

### 1.3 The interleaving that produced it (from relay.log)

```
18:29:37  startMeter   → bridge.start (engine B1 → Mirror) ; meter.start(to: wav)  [engine A, run 1]
18:29:41  🔽 stop      → stopMeter: meter.stop() → close(): removeTap, engine.stop()  ← A stopped+uninitialized
          bridge drained, bridge.stop() → B1 stopped, released ("audio bridge down")
18:29:42  feedWatchTick (feedQueue, 200 ms sampling, Wispr's input still open because the stop chord did not take)
          → main → feedOwnSentence → meterQueue:
             bridge.start (engine B2 → Mirror)              "audio bridge up"
             meter.startMetering() → start(to: nil):
                 InputDevice.select(on: engine.inputNode)  → AudioUnitSetProperty(CurrentDevice) on the SAME AUHAL
                 installTap, prepare(), start()            "mic: metering through Wireless Mic Rx"   [engine A, run 2]
          ⚠️ "the stop chord did not take … posting the stop once more"
18:29:44  ⌃Escape → Wispr closes its input; feedWatchTick sees it closed ≥ 0.3 s → endOwnFeed → meterQueue:
             meter.onBuffer = nil
             meter.stopMetering() → close(): removeTap, engine.stop()  ← thread 15 in usleep
          ★ IO thread of A calls a NULL IOProc entry → SIGSEGV
```

So the crash is the **second stop in three seconds of a reused `AVAudioEngine`/AUHAL** whose current device
was re-set (`kAudioOutputUnitProperty_CurrentDevice`, InputDevice.swift:349) between the two runs, with the
first run's uninitialize ~1 s before the second run's initialize on the same device. Everything this app
did was correctly serialised on `meterQueue` + `MicRecorder.lifecycle` (no `🔁 mic:` restart line, so
`restartTap` never ran; no `mic.restart` thread in the dump), which means the NULL entry is **inside
CoreAudio's client-side IO context**, i.e. the torn state is Apple's, provoked by this app's
stop → re-aim → start → stop churn on one long-lived AUHAL. Confidence in the mechanism (reused unit +
rapid re-cycle): **medium (~60 %)**; it is the only lifecycle pattern in the window that differs from the
thousands of clean single-run sessions in the log, and it is the pattern `AudioBridge` deliberately avoids
(a fresh engine per `start`, AudioBridge.swift:238) and that `MicRecorder.restartTap(.rebuild)` already
treats as the stronger medicine (MicRecorder.swift:872–877).

Why it reached this state at all: the stop chord posted at :41 did not take, Wispr's microphone stayed
open, and the 200 ms "feed == .none" sampler (WisprFlowSource.swift:2535–2541) read that as *his own Wispr
sentence* and re-opened a meter+bridge on the sentence the relay had just closed. The second stop and the
⌃Escape followed within 2 s. The feed logic is correct on its own terms; it simply has no notion of
*"the microphone I just closed is still warming down — reuse or wait"*.

### 1.4 Other reports checked

- `Retired/Walkie Talkie-2026-10-09-142455.ips` — **unrelated**: `objc_retain` under
  `-[NSPasteboard changeCount]` from `PasteboardTimeline.tick()` (WisprTestHooks.swift:130) on main.
  Pasteboard owner collection, not audio.
- The 24 hang samples of today are all taken **after** the stall ended (`HotkeyTap.sampleSelf()`,
  HotkeyTap.swift:2447, is called at *"main thread back after N s"*), so the main thread is idle in every one
  of them — they cannot name the stall. What they do show, in every single file, is the
  `ro.victorrentea.wispr-relay.feed-watch` queue spending **30–80 % of the 3 s window inside
  `WisprWatch.sampleIsRunningInput()` → `HALC_ProxyObject::GetPropertyData/HasProperty` → coreaudiod**
  (e.g. 1210/2218 samples at 10:59:16, 827 at 15:30:59, 698 at 12:55:25). coreaudiod was answering
  property reads in hundreds of milliseconds all day. See finding F2 for what that does to main.
- The 2026-10-02 08:47:43 bridge crash (`EXC_BAD_ACCESS` at 0 in `VoicedMeter.feed`, a buffer with NULL
  `mData`, now guarded by `AudioBridge.readable`, AudioBridge.swift:410) is the same family — a buffer
  reaching the bridge after the object behind it was torn down — and shares the fix direction of F1/F9.

---

## 2. Findings, ranked

Severity: **S1** = can crash the process; **S2** = can freeze the app or lose a sentence; **S3** = latent /
hygiene. Each has file:line, the interleaving, and a fix sketch.

### F1 · S1 · `MicRecorder` reuses one `AVAudioEngine`/AUHAL for the life of the app and re-aims it between runs

`MicRecorder.swift:302` (`private var engine = AVAudioEngine()`), `:683–687` (`engine.inputNode`,
`InputDevice.select(on:)` → `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` on the existing
unit, InputDevice.swift:349), `:762–767` (removeTap/installTap/prepare/start), `:1080–1081` (close:
removeTap/stop). Four instances exist (ElevenLabs, Local, Wispr sources, `CaretHalo.previewMic`,
AppDelegate.swift:3202).

Interleaving: stop (uninitialize → `AudioDeviceDestroyIOProcID`) → within ~1 s set CurrentDevice on the
same AUHAL → initialize/start (new IOProc on the same HAL context, possibly before the old IO thread has
fully exited) → stop again 2 s later. This is the 18:29:44 crash (section 1). It is reachable on every
engine, not only Wispr: `start(to:)`'s pre-emption (`:674–681`) does `close()` then re-opens the same engine
in the same call; `startMeter` taking over `.own` (WisprFlowSource.swift:2606–2623) does
`stopMetering(); bridge.stop(); … bridge.start(); meter.start(to:)` back to back.

Fix:
```swift
// MicRecorder
private var engine: AVAudioEngine?            // nil between sessions
private static let graveyard = DispatchQueue(label: "mic.retire", qos: .utility)

func start(to destination: URL?) -> String? {
    lifecycle.lock(); defer { lifecycle.unlock() }
    …
    let fresh = AVAudioEngine()                // never re-aim a unit that has run
    let input = fresh.inputNode
    guard let device = InputDevice.select(on: input) else { … }
    … installTap / prepare / start (through WTTry, see F4) …
    engine = fresh
}

private func close() -> (url: URL?, elapsed: TimeInterval) {
    lock.lock(); isRecording = false; lock.unlock()
    let retired = engine; engine = nil
    retired?.inputNode.removeTap(onBus: 0)
    retired?.stop()
    // Let the HAL IO thread finish exiting before the unit is disposed.
    Self.graveyard.asyncAfter(deadline: .now() + 0.3) { withExtendedLifetime(retired) {} }
    …
}
```
And a **minimum re-open spacing**: if `start` is asked for the same device within 300 ms of the last
`close`, wait the remainder on the caller's queue (it is already off main). `restartTap(.rebuild)` and
`AudioBridge.start` already follow the fresh-engine pattern; this makes the recorder match them.

### F2 · S2 · Synchronous coreaudiod round trips on the main thread and the tap thread

`WisprWatch.sampleIsRunningInput()` (WisprWatch.swift:188–193) is one `AudioObjectGetPropertyData` IPC per
watched Wispr process. It is called on **main** from `pollInput` every 100 ms while a sentence is in flight
(WisprFlowSource.swift:2253), `start()` :991, `stop()` :1356, `lateOpenEdge`-adjacent paths :1415/:1458/
:1574/:1674/:2067/:2094/:3098/:3122/:3373/:3456/:3468, `wisprMicOpenNow` :1736, `/test/state` :1748;
AppDelegate.swift:5671 (`startDictation`), :7178, :7187 (`tickBackStop` timer); and on the **event-tap
thread** through `hotkeys.wisprMicIsOpen` (AppDelegate.swift:3231, HotkeyTap.swift:1213). Today's hang
samples show the same IPC taking hundreds of ms per call on the feed-watch queue; the rule written on
2026-10-09 for `InputDevice.inputs()` ("never list the inputs on the main thread") applies to this call
word for word. A 10 Hz poll of a 0.5 s IPC is a frozen app; on the tap thread it is a frozen *tap* (the
`MainStallGate` fail-open does not help there).

Fix: one sampler, one cache.
```swift
final class WisprWatch {
    private let cached = Atomic<(open: Bool, at: CFAbsoluteTime)>((false, 0))
    /// Non-blocking: the last value the sampler saw. Safe on main and on the tap thread.
    var isRunningInputCached: Bool { cached.load().open }
    /// Blocking IPC — `dispatchPrecondition(condition: .notOnQueue(.main))`.
    func sampleIsRunningInput() -> Bool { … store into `cached` … }
}
```
`feedWatchTick` (already 25 ms on `feedQueue`) becomes the only caller of the blocking sample; every main/tap
reader switches to `isRunningInputCached`. Also merge the two `WisprWatch` instances (AppDelegate.swift:145
`wisprMic`, WisprFlowSource.swift:574 `watch`) — they double every listener and every IPC.

### F3 · S1 · `ShotMarker` wires and plays an `AVAudioEngine` with no `WTTry`

ShotMarker.swift:392 (`engine?.stop()` on a stale engine), :405–423 (`attach`, `connect(_:to:format:)`,
`engine.start()`), :376–377 (`scheduleBuffer`, `player.play()`). `player.play()` on an engine that a device
change stopped raises `NSException` — the exact crash `AudioBridge` was armoured against on 2026-09-30
(AudioBridge.swift:264–270, :468, :506, :571, :594–614). The played path is live whenever
`WisprFlowSource.mark` runs with the bridge down (WisprFlowSource.swift:382) and from AppDelegate.swift:1851.

Interleaving: From Walkie toggled or re-plugged → `AVAudioEngineConfigurationChange` stops the marker
engine → next shutter press: `startedPlayer` sees `engine?.isRunning == false`, builds a new engine (fine),
but a press that lands *between* the change and the `isRunning` read calls `play()` on the dead engine →
abort.

Fix: wrap every engine mutation in `WTTry` as `AudioBridge.guarded` does, and watch the configuration
notification to drop the engine proactively:
```swift
guard WTTry({ engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format) }) == nil,
      (try? engine.start()) != nil,
      WTTry({ player.play() }) == nil else { Log.error(…); return nil }
```

### F4 · S1 · `MicRecorder.start` / `restartTap` wire the tap without `WTTry`

MicRecorder.swift:762–767 and :892–903. `installTap(onBus:bufferSize:format:)` raises `Input HW format and
tap format not matching` when the hardware format differs from the format passed — the 2026-09-01 SIGABRT.
The code reads `inputFormat(forBus: 0)` first (:710) and passes it, which closes the window *almost*: a
device that changes (receiver unplugged, Bluetooth hand-off, Wispr opening the same device and changing its
nominal rate) between :710 and :763 still aborts the process. `engine.start()` is a Swift `throws` and is
caught, but `prepare()` and `installTap` are not catchable from Swift.

Fix: `guard WTTry({ input.removeTap(onBus: 0); input.installTap(…); engine.prepare() }) == nil else { return
"the microphone changed while it was being opened" }`, same in `restartTap`.

### F5 · S2 · `restartQueue` touches `engine` outside `lifecycle`

- `deviceReadout()` (MicRecorder.swift:915–946) is called from `handle(_:)` (:836) **before** `restartTap`
  takes `lifecycle`; it reads `engine.inputNode.audioUnit` and `engine.inputNode.inputFormat` while
  `close()` on `meterQueue` may be inside `engine.stop()`. `AVAudioEngine` is not thread-safe; `inputNode`
  is a `dispatch_sync` into the engine's own queue (journal 2026-09-19: that is where main hung).
- The stall timer handler (:821) reads `self.engine.isRunning` with no lock, same race.
- `stallTimer` itself is written on `meterQueue` in `start` (:805, :823) and on `restartQueue` in the
  handler (:817) — two queues, one unsynchronised `var`.

Interleaving: `stop()` on meterQueue has set `isRecording = false` and is in `engine.stop()`; the stall
timer fires on `restartQueue`, reads `recording == false`, cancels — fine — but the `handle(.restart)`
branch of a tick that read `recording == true` a few ms earlier calls `deviceReadout()` against the engine
being stopped.

Fix: move `deviceReadout()` inside `restartTap` under `lifecycle` (pass the strings out), make `stallTimer`
owned by `restartQueue` only (`start` schedules it with `restartQueue.async`), and read `engine` only under
`lifecycle` or on `restartQueue` inside `restartTap`.

### F6 · S2 · Stop → start churn by design in the Wispr feed hand-over

WisprFlowSource.swift:2606–2623 (`startMeter` over an `.own` feed) and :2535–2541 → :2561–2576
(`feedOwnSentence` immediately after `stopMeter`). Both tear the meter engine and the bridge engine down
and rebuild them within milliseconds (or within the 1 s `now - ended > 1` guard). Together with F1 this is
the crash's path; even with F1 fixed it is needless HAL churn (two `AudioDeviceDestroyIOProcID` + two
creates per hand-over).

Fix: let a running meter be **retargeted** instead of restarted:
```swift
/// Attach a WAV to a running metering session from the next buffer on; nil = detach.
func retarget(to destination: URL?) -> String?   // under `lock`: file = AVAudioFile(...), url = destination, writtenFrames = 0 …
```
`startMeter` then does `if meter.isRecording && feedNow == .own { meter.retarget(to: wav); setFeed(.relay); return }`
and keeps the bridge (`bridge.isRunning` → only `release`/`closeInput` state changes). `feedOwnSentence`
after a relay stop: if the meter closed < 300 ms ago, wait the remainder (F1's spacing) rather than
re-open at once.

### F7 · S2 · `AudioBridge.stop()` / `start()` are `queue.sync` from `meterQueue`, and `stopMeter` sleeps on `meterQueue`

AudioBridge.swift:231, :561; WisprFlowSource.swift:2665–2675 (`Thread.sleep` loop up to `drainStall`).
`meterQueue` is the single owner of the meter and the bridge, so a drain that sleeps there holds every
later `startMeter`/`endOwnFeed`/`feedOwnSentence` — correct for ordering, but it is why a stuck player
delays the *next* microphone open by `drainStall`. Not a crash; noted because the F1 fix must not move any of
this off `meterQueue` (the serial owner is the thing that is right here).

Fix: none required; add `dispatchPrecondition(condition: .onQueue(meterQueue))` at the top of
`startMeter`'s and `stopMeter`'s bodies so the ownership is asserted, not assumed.

### F8 · S3 · `AudioBridge` buffer path: NSLock + allocation on the CoreAudio input thread

MicRecorder.swift:1128–1188 (`append`: three `lock` takes, an `AVAudioPCMBuffer` allocation, the converter,
file write, then `sink(out)`), AudioBridge.swift:343–364 (`schedule`: `lock`, `queue.async`),
ElevenLabsLive.swift:262–265 (`Data` copy, `queue.async`). All on the HAL IO thread. This is a glitch /
priority-inversion risk, not a crash, and the meter has been doing it for a month; the 2026-09-24 inversion
was exactly a lock taken on this thread. Keep it in view: anything added to `append` must be allocation-free
and lock-free.

### F9 · S3 · `AVAudioPCMBuffer` lifetime across queues in the bridge

AudioBridge.swift:353/362 (`queue.async { take(buffer) }`), :425 (`backlog.append`), :469
(`scheduleBuffer(ready…)`). The buffers are app-allocated (`out` in `append`, marker clips), so they are
owned by the closures — fine. The 2026-10-02 NULL `mData` crash shows a buffer *did* arrive dead once;
`readable()` now drops it. Recommendation: keep `readable()`, and log the buffer's class/owner when it
fires so the next one is attributable.

### F10 · S3 · Quit order: From Walkie removed under a possibly running bridge

AppDelegate.swift:11367 `FromWalkieDevice.set(false, reason: "app terminate")` while `AudioBridge.engine`
may still be running on the Mirror (nothing stops the sources' meters/bridge in `applicationWillTerminate`;
only `music.stop()` at :11351). Device removal under a live IOProc is a teardown the HAL does on its own
thread; at quit a crash is cosmetic but it writes a `.ips` and may trip the Addons watchdog. Fix: stop the
wired source and `wisprSource` (`cancel()` or a new `shutdownAudio()` that runs `meter.stop()` and
`bridge.stop()` on their queues, `sync`) before the device toggle.

### F11 · S3 · Benign unlocked reads of `isRecording`

`MicRecorder.isRecording` is `private(set) var`, written under `lock`, read unlocked on main
(AppDelegate.swift:223–224 `liveMeter`, CaretHalo.swift:1181–1186) and on `meterQueue` (WisprFlowSource.swift
:2564, :2612). Bool tear-free on arm64; flagged only so nobody "fixes" it by taking `lock` on main (the
2026-09-19 freeze).

### F12 · S3 · Property listeners

`WisprWatch.resubscribe` (WisprWatch.swift:152–173) adds/removes `IsRunningInput` listeners with the same
block on the same `queue` — correct. `MicAnnouncer.start` (MicAnnouncer.swift:86) and the two
`WisprWatch` process-list listeners are never removed — acceptable for app-lifetime singletons. The only
issue is the duplication from F2 (two `WisprWatch`es).

### What is already right (do not re-derive)

- `MicRecorder.lock` is never held across an engine call; `lifecycle` serialises `start`/`stop`/`restartTap`
  (2026-09-24 rule) — verified at :643, :866, :1049, :1077.
- Every microphone open/close is off main: `meterQueue`, `eleven-mic`, `local-mic`, `preview-mic`.
- `AudioBridge` builds a fresh engine per start, guards every engine mutation with `WTTry`, and handles
  `AVAudioEngineConfigurationChange` with a bounded recovery and `die()`.
- `restartTap(.rebuild)` re-registers the configuration observer on the new engine and releases the old
  engine outside `lock`.

---

## 3. Guard rails

### 3.1 One serial owner per audio object, asserted

Every `AVAudioEngine`-holding type gets an `owner: DispatchQueue` and asserts it:

```swift
final class MicRecorder {
    let owner: DispatchQueue                          // injected: meterQueue / audioQueue / preview-mic
    private func assertOwner() { dispatchPrecondition(condition: .onQueue(owner)) }
    func start(to: URL?) -> String? { assertOwner(); … }
    func stop() -> … { assertOwner(); … }
}
```
`AudioBridge` already has `queue`; add the precondition inside `start`/`stop`/`die`/`recover`. `ShotMarker`
has `queue`; same. `restartTap` keeps `lifecycle` for the one cross-queue path (the watchdogs), and the
watchdogs never touch `engine` outside it (F5).

### 3.2 A session state machine with a generation

```swift
enum MicSession { case idle, opening(gen: Int), running(gen: Int, engine: AVAudioEngine), closing(gen: Int) }
```
- `start` is legal only from `.idle` (or `.running` with the same destination → no-op). A `start` while
  `.closing` **waits** for the close (same queue, so it naturally does) and then honours the re-open spacing.
- Watchdog callbacks and `AVAudioEngineConfigurationChange` carry the `gen` they were armed for and are
  dropped when it has moved on.
- `engine` exists only inside `.running`; nothing holds a strong reference to a retired engine except the
  graveyard (`3.3`).

### 3.3 Retain-until-stopped, release-after-exit

An engine is released only after (a) `removeTap`, (b) `stop()` returned, and (c) ≥ 300 ms have passed on a
utility queue (`graveyard.asyncAfter`). Never set a retired engine's device, never call `inputNode` on it.
Fresh engine per session everywhere (`MicRecorder` joins `AudioBridge` and `restartTap(.rebuild)`).

### 3.4 Everything that can raise goes through `WTTry`

`installTap`, `prepare`, `attach`, `connect`, `play`, `scheduleBuffer`, `pitch.rate`, `stop` — in
`MicRecorder`, `ShotMarker` and (already) `AudioBridge`. A failed wiring returns a reason string; it never
aborts. `ObjCTryTests` already pins the mechanism; add one test per new call site that feeds a deliberately
mismatched tap format and expects a reason, not a crash.

### 3.5 Never block main or the tap thread on coreaudiod

A debug guard in the three IPC helpers:
```swift
@inline(__always) func assertOffMain(_ what: StaticString) {
    #if DEBUG
    dispatchPrecondition(condition: .notOnQueue(.main))
    #endif
}
```
in `WisprWatch.sampleIsRunningInput`, `InputDevice.inputs()`, `AudioDevices.all()`, `MicRecorder.start/stop`,
`AudioBridge.start/stop`. Main reads caches (F2). The release build logs instead of trapping
(`Log.error("audio IPC on main: \(what)")`) so a slip shows up in `relay.log` the first time, not in a hang.

### 3.6 Photograph the stall while it stands

`HotkeyTap.sampleSelf()` runs at *"main thread back"*; run it also at *"main thread silent for 3 s"* (the
gate's `.opened`) with `sample <pid> 2`. Today's 24 dumps are all post-thaw and name nothing.

### 3.7 A churn eval under `evals/`

`evals/test_audio_churn.py` — uses the existing routes (`/test/mic`, `/test/bridge`, `/test/dictation`,
`/test/cancel`, `/test/wispr`, `GET /test/state`, `GET /engine`) against a desk instance (never the live one
without the restart gate's blessing):
1. 200 × open/close of the meter with gaps drawn from {0, 20, 100, 300, 1000} ms, alternating engines
   (`POST /engine`), asserting after each: pid unchanged, `GET /test/state` answers < 1 s,
   `relay.log` has one `mic: recording through` per open and no `🧊`.
2. The same with `POST /test/bridge {"on": true/false}` toggled mid-session and From Walkie turned
   off/on through a new `POST /test/from-walkie {"on": …}` (a 10-line route around `FromWalkieDevice.set`),
   to exercise `AVAudioEngineConfigurationChange` → `restartTap`/`recover`/`die`.
3. The Wispr hand-over: `/test/wispr-handsfree` start, `/test/cancel`, then `/test/wispr-proc` reporting the
   input open so `feedOwnSentence` fires within 1 s of the close — the 18:29 sequence, 50 times.
Pass = the app is the same pid at the end and `~/Library/Logs/DiagnosticReports` gained no `Walkie
Talkie-*.ips`. Plus a Swift test `MicRecorderChurnTests` (skipped when no input device) doing 100 ×
`start(to: nil)`/`stop()` on one recorder with 0–50 ms gaps.

### 3.8 Rule text for `.claude/rules/whisper-and-corpus.md` (section *Do not*)

```
- **An `AVAudioEngine` runs once** (2026-10-13). Build a fresh engine per session and never set
  `kAudioOutputUnitProperty_CurrentDevice` on a unit that has already run: `MicRecorder` reused one
  engine for the life of the app, re-aimed it between runs, and a stop → start → stop within 3 s on the
  same device (Wispr's own feed re-opened the meter 1 s after the relay's stop) crashed the HAL IO thread
  at 0x0 under `-[AVAudioEngine stop]` (`Walkie Talkie-2026-10-13-182955.ips`). Retire a stopped engine
  on a utility queue ≥ 300 ms after `stop()` returns; never touch it again. `AudioBridge` and
  `restartTap(.rebuild)` already do this.
- **Every audio object has one owner queue, asserted** — `dispatchPrecondition(.onQueue(owner))` at the
  top of `start`/`stop`; watchdogs and configuration-change handlers reach the engine only through
  `restartTap` under `lifecycle`. `deviceReadout` and the stall timer read nothing of the engine outside it.
- **Every call that can raise an NSException goes through `WTTry`** — `installTap`, `prepare`,
  `connect`, `play`, `scheduleBuffer` — in `MicRecorder` and `ShotMarker` as in `AudioBridge`
  (2026-09-30). A failed wiring is a reason string, never an abort.
- **No coreaudiod round trip on main or on the tap thread.** `WisprWatch.sampleIsRunningInput` is an IPC
  per Wispr process (hundreds of ms when coreaudiod is busy — every `hangs/` sample of 2026-10-13 shows
  `feed-watch` inside it). Main and `HotkeyTap` read `isRunningInputCached`; only `feedQueue` samples.
  Same rule as *Never list the inputs on the main thread* (2026-10-09).
```

---

## 4. Recommended fix order

1. **F1 + F6** (fresh engine per session, graveyard release, re-open spacing, `retarget` instead of
   restart on the Wispr hand-over) — removes the crash's mechanism and its trigger.
2. **F4 + F3** (`WTTry` around `installTap`/`prepare` in `MicRecorder`, around all of `ShotMarker`) —
   the other abort class, cheap, no behaviour change.
3. **F2** (cached `WisprWatch` sample; one instance) — the hang class; also lowers coreaudiod load.
4. **F5** (watchdog reads under `lifecycle`; `stallTimer` owned by `restartQueue`).
5. **3.6** (sample at stall open) and **3.7** (the churn eval) — so the next one is attributable and so the
   fixes can be proven on a desk instance before `./relay-restart.sh --build`.
6. **F10** (quit order), then the rule text.
