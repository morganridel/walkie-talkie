# Codex fork: implementation and evidence

This matrix describes the current source tree separately from runtime evidence.
“Implemented” means there is code or a route for the behavior; it does not mean
the behavior passed end to end. Record evidence here after following [the manual
test guide](CODEX_TEST_GUIDE.md).

| Area | Implementation in this fork | Verification evidence |
|---|---|---|
| Build and identity | SwiftPM and packaging use `local.walkie-talkie`. Fresh-profile engine default is Local Whisper; microphone discovery is system-based with automatic selection. Packaged Python helpers suppress bytecode writes inside the signed bundle. | **Verified build/install/startup.** Release bundle installed and launched; local API responds; final signature verified after workers started. Full Swift suite: 279 executed, 2 opt-in integration checks skipped, 0 failures; 277 passed. The opt-in native PTY checks also passed in a separate disposable run. Cached official Swift 6.2.3 leaves system CLT unchanged. Ad-hoc signing means macOS may require permissions again after rebuilding. |
| Codex CLI discovery | `CodexBridge` resolves the helper and bundled native CLI executable; `CODEX_BIN` can override the binary. | **Verified.** Native CLI connected in PTY E2E; installed helper doctor resolves the native binary and version. |
| Chat picker | `Bind Codex chat…` lists chat metadata; picker supports title/project search, project filter, refresh, and explicit live-chat binding. Saved rows are labelled and cannot bind; verified CLI rows retain their Terminal TTY. | **Partial.** Regression tests verify CLI handle/TTY preservation and reject unproven/saved mappings. Installed-app API binding selected the exact disposable desktop chat in 0.45 s after removing window/branch lookups. Codex target labels use the recorded project folder. User opened the disposable chat, selected it through Bind Codex chat, and completed the spoken test; the app reported that exact target. Search/filter/refresh, project switching, and other pointer actions remain manual. |
| CLI chat sending | Codex target is represented in `TerminalBinding`; bound and verified caret delivery call the bridge with text and actual screenshot/crop/film-sheet image inputs. Busy sends can steer the exact active turn. | **Verified in native CLI PTY E2E.** Initial prompt exactly once; follow-up send; synthetic red image read as red; busy follow-up steered the same turn. A separate production caret dispatch resolved the exact foreground CLI ID, displayed `[Image #1]`, and answered `CARET_RPC_RED`. Exited TUIs/shells fail caret ownership checks; attempted RPC failures never fall back to paste or retry. Physical Terminal/VS Code caret interaction remains manual. |
| Codex desktop delivery | Same-user native desktop IPC adapter preserves protocol version and verifies owner discovery for desktop threads. | **Verified in a disposable desktop chat.** Text delivered with the expected reply, a synthetic red image was interpreted as red, and a busy update steered the same active turn and reached the expected marker. Installed-app bind/hold/edit/send also reached that chat; cancel caused no delivery or new turn. Tested with Desktop 26.1007.30912 and native CLI 0.162.0-alpha.17.2. IPC remains internal and version-coupled. Desktop completion uses the receiving model's `set_thread_archived` tool; exact-window closing is unsupported. Completion cue archived only the disposable chat; it was subsequently restored. Archiving interrupts the active turn, so a result must be provided before the archive action. |
| New/resumed sessions | `walkie-codex` starts the shared daemon idempotently, persists the initial prompt through RPC before attaching the CLI TUI, creates/resumes the exact conversation, and writes a tty sidecar. `SpawnTerminal` uses this launcher. | **Verified in native CLI PTY E2E.** Initial prompt delivered once. New launch without an initial prompt is deliberately rejected; `--resume` is supported. Packaged-app spawn UI still needs verification. |
| Search and history | `Rebind to…` searches Codex thread metadata and message history through read-only queries; live hits can bind and closed hits can resume. Prompt History/Full Log remain available. | **Partial.** Installed helper found both user and Codex marker hits in the disposable chat with correct project/title and latest Codex snippet. History contained the sent marker and excluded the cancelled one. Equal-timestamp matches use rollout order. Rebind UI, tty association, and closed-chat resume still need manual checks. |
| Quick answer | `QuickAsk` uses a persistent `quick-worker` for three stages: short answer, web/source check, and adversarial source review. It supports cancellation and source links. | **Installed-app API flow passed.** English: first words 2.30 s, all stages 13.16 s. French: first words 3.67 s, all stages 16.06 s, preserving French. Source hover/click handlers produced quoted URL fragments without opening a browser. Links survived resize; close cancelled a quick question and restored the queued reply, then a later question completed. Visual/pointer interaction remains manual. Timings are individual observations. |
| Local transcription | Helper discovery can reuse Quiet Journal's runtime and on-disk model cache; default model is multilingual with no language allowlist. The optional local language menu supplies the same per-request recognition hint to captions and final decode; Automatic remains the default. A separate worker owns the loaded model and its memory. | **Installed-app decode and spoken delivery passed.** User started/stopped with ⌃⌘D, dictated the requested phrase, and the exact selected desktop chat replied `banana`; delivery metadata reports `local-whisper`. Cached model warm-up 5.12 s. Public 11 s Whisper JFK sample: 2.56 s from the app cache without word timings; 5.31 s with 22 timed words. No chat delivery occurred. About 1.54 GB active model memory plus a 512 MB decode cache was observed; the in-memory model is not shared with Quiet Journal. |
| Cloud transcription/fallback | ElevenLabs cloud rows and local-now/automatic-local options remain. | **Pending.** Test cloud response, injected failure, local fallback race, and provider/mic switching. |
| Wispr Flow | Wispr implementation and menu integration remain controlled by `WT_WISPR_ENGINE`; current source defaults its row on. The raw chord path is separate from a successful engine transcript/delivery. | **Pending.** Validate menu, transcript capture, and delivery independently; do not infer engine reliability from raw chords. |
| Captions and microphone | Local caption-band controls and microphone chooser are implemented; explicit language applies to captions and final decode. | **Partial.** Synthetic band opened/closed with six words; real Mac microphone voice/send and English captions/transcript were confirmed by the user. Both workers ready. Other devices and unplug/reconnect remain manual. |
| Prompt/reply UI | Held prompt, edit/countdown/autosend/cancel/recover, authenticated text/image callbacks, links, and reply-back actions are present. | **Partial.** Installed hold/edit/send/cancel passed; cancel created no turn. Authentication, persistent image copies, resize/queue restoration and source handlers passed. Real spoken “What is two plus two?” automatically invoked `walkie-reply`, returned `shown`, and displayed the bubble confirmed by the user. Bubbles intentionally stay until ×; later replies queue. Pin, image opening and reply-back remain manual. |
| Kamikaze / finish | `kamikaze` adds a completion cue. CLI `walkie-finish` waits for the active exact turn, verifies sidecar/PID/TTY and root terminal owner identity, then signals only its Codex TUI and closes one tab. Desktop cue asks the receiving model to archive itself through `set_thread_archived`. | **Partial.** 12 mocked helper tests and a safe `--dry-run` pass; no real Terminal close has been tested. Desktop completion cue archived only the disposable chat, then the test restored it. Archiving interrupts the active turn; no final answer after archive was produced. |
| Screen/context | Keyboard screenshot, wheel crop/move/cancel, accessibility selection, Chromium DOM picker, film/contact sheet, and media pause/resume are implemented. | **Partial, with real keyboard/browser/film delivery verified.** User confirmed English + ⌃⌘S; two real image inputs reached the exact desktop chat. In Microsoft Edge with the unpacked extension enabled, real ⌘⇧ hold/click outlined and picked `#pick-target`; app logged receipt and the synthetic prompt was cancelled without delivery. A fixture audio element paused on prompt open and resumed on cancel. User film delivery produced a genuine 14-frame contact sheet plus screenshot; Codex described the fixture. A second 42-frame film plus selected text correctly described the user selecting synthetic fixture sentences. Wheel crop/move, DOM drag, multi-tab media and iframe cases remain manual. |
| Gestures and caret | ⌃⌘D and ⌃⌘S work in either gesture mode. Logi/Wheel handlers, plain dictation, caret prompts, and clipboard/paste-last remain. Verified Codex caret prompts use stable-ID RPC; generic fields receive paste without Return. | **Partial.** Real keyboard voice/shutter/film and browser picker passed. Native PTY production caret dispatch passed with a real image; 7 deterministic caret tests pass and 2 opt-in tests passed separately. Physical Logi/Wheel gestures, native Terminal/VS Code focus interaction, and clipboard restoration remain manual. No Options+ is required for keyboard controls. |
| Outbox/restart/login/settings | Outbox records delivered events; guarded restart and menu preferences remain. | **Partial.** Graceful idle replacement/relaunch passed; English persisted, workers started, current grants and event-tap canary verified. Chat binding is cleared on relaunch and must be selected again; exact disposable binding was restored through the owner-checked route. Login registration reports enabled; actual login, other preferences and restart under varied conditions remain manual. |
| Voice corpus and report helper | Transcribed recordings retain WAV plus transcript whether or not delivered. Cancelled takes are staged for five minutes and can enter the corpus if recovered and transcribed; outbox records delivered prompts only. | **Retention documented; report helper not installed or scheduled.** Default preview and explicit recipient/inbox requirements pass two tests. No report email was sent. No private Quiet Journal audio was used. |

## Evidence log

Evidence below separates implementation from observed results. A helper
protocol test or read-only ownership probe does not establish desktop send or
full UI parity. Include app build/revision, date, method, and evidence location
for future runs. Redact private chat content, audio, tokens, paths, and credentials.

| Date/build | Area and method | Result/evidence |
|---|---|---|
| Current debug build | `./tools/swift-build.sh build` using cached official Swift 6.2.3 toolchain and compiler workaround; system CLT unchanged. | Debug application build succeeds; full XCTest suite: 279 executed, 2 skipped, 0 failures (277 passed). |
| 2026-10-15 release | Signed bundle build, install, launch, local API, and signature verification after model startup. | Passed. Both transcription workers ready using Quiet Journal runtime/cache; Quiet Journal health remains good. Microphone and Screen Recording are enabled. After removing/re-adding the current app in Accessibility and reopening, startup reports trusted=true/eventTap=true; the harmless canary is alive (about 0.14 ms). The earlier stale grant is resolved. Real spoken start/stop/send subsequently passed; other physical gestures remain separate checks. |
| 2026-10-15 CLI identity follow-up | Real native CLI and isolated cold-start tests. | Native daemon symlink accepted with ownership checks; shared read and TTY resolve retain the same verified CLI identity; initial prompt completed exactly once; exited CLI disappears from live rows; synthetic test archived. Isolated cold start installed daemon, initialized RPC and attached TUI successfully, then stopped/cleaned only its own daemon. |
| Current Python tests | Full Python test suite. | 67 tests pass. |
| CLI integration | Native Codex CLI PTY smoke on a disposable conversation. | Initial prompt exactly once; follow-up direct send; synthetic red image read as red; busy send steered the same turn ID and reached expected final marker. Test chat archived; TUI exited 0. |
| Finish helper | `walkie-finish` unit tests and `--dry-run`. | 12 mocked tests pass; safe dry-run passed. No real terminal tab close has been attempted. |
| 2026-10-15 desktop integration | Owner-verified native Desktop IPC on a user-authorized disposable chat. | Text and synthetic red image passed. A missing native steer composer record/text-element array was found and fixed; same-turn steering then passed. Owner rejection errors retain their reason. |
| 2026-10-15 desktop completion | Installed-app prompt ending in `kamikaze`; native receiving-chat archive. | Only the disposable chat appeared in the archive list; its turn was interrupted by archive before the requested final marker. Chat restored afterward. |
| 2026-10-15 installed-app delivery | Synthetic transcript through the installed Swift app, bound only to the disposable desktop chat. | Hold/edit/send reached the expected marker. Cancel dismissed the prompt without delivery or a new chat turn; run-only autosend restored. No microphone or physical shortcut was used for this check. |
| 2026-10-15 real voice | User opened/bound the disposable desktop chat and pressed ⌃⌘D to start/stop a spoken prompt. | User confirmed `banana`; Codex readback independently shows completed final answer `banana`; installed app delivery record is `via:local-whisper` to the exact test chat. Idle afterward; signature valid. No recording was read. |
| 2026-10-15 search/history | Installed helper on the disposable chat. | Two marker hits, correct project/title/latest Codex role, eight history turns; cancelled marker absent. |
| 2026-10-15 quick/replies/captions | Installed-app API tests with harmless English/French questions and synthetic images/text. | All quick stages completed, citations retained across resize, cancel/queue restoration passed, token rejection and text/image replies passed, image copy survived source deletion, caption band opened/closed. No external browser was opened. Native image reads from protected Documents initially stalled; helper cache staging fixed that path. |
| 2026-10-15 local app decode | Public [OpenAI Whisper test audio](https://github.com/openai/whisper/blob/main/tests/jfk.flac), 11 s, SHA-256 `63a4b1e4c1dc655ac70961ffbf518acd249df237e5a0152faae9a4a836949715`. | App-cache input: 2.56 s without word timings; forced word timings: 5.31 s and 22 words. No delivery; no private audio. Protected Documents input produced an unrelated native file-access delay, so normal cache storage was used for the final timing. |
| Current performance samples | Cached MLX model and quick-worker measurements on development Mac. | MLX warm-up 5.12 s; 28 s public WAV decode 2.85 s. Quick worker ready 0.20 s, first delta 2.61 s, total 2.71 s; web mode first delta 5.24 s, total 5.36 s. Single-run measurements only. |

For detailed procedures, including loopback test hooks and safety boundaries,
see [CODEX_TEST_GUIDE.md](CODEX_TEST_GUIDE.md).

## Latest real-device evidence — 15 October 2026

- After the 11:44 callback-guidance build, the user refreshed Accessibility and
  Screen Recording. Both verified true; the event-tap canary was alive (0.21 ms).
- English speech and ⌃⌘S supplied opening and explicit screenshots as genuine
  desktop image inputs. Codex identified the heading; the user confirmed both.
- Automatic voice → Codex → `walkie-reply` passed: the 2+2 turn ran the helper,
  exited 0 with `shown` in 88 ms, and the user confirmed the bubble. The initial
  sandbox denial was resolved by localhost-permission guidance. Unknown delivery
  outcomes still stop without automatic retry.
- Microsoft Edge: the user enabled the unpacked extension. A local synthetic
  audio fixture paused on prompt start and resumed on cancellation. The user
  held ⌘⇧ and clicked the outlined blue box; the app received `#pick-target`.
  That synthetic DOM take was cancelled, so DOM delivery itself is not claimed.
- Real film delivery passed twice: a 2.7-second/14-frame sheet and screenshot
  reached the test chat; then an 8.3-second/42-frame sheet plus captured synthetic
  text selections. Codex correctly described the page and selections.
- One earlier automated film captured the wrong foreground window. It was
  cancelled without sending, and only those test images were deleted. It is not
  counted as fixture evidence.
- Final source caret check: the production target resolver and default bridge
  dispatch passed in a disposable native PTY, including a generated red PNG.
  The TUI displayed `[Image #1]` and answered `CARET_RPC_RED`. Synthetic threads
  were archived and isolated test artifacts removed. Deterministic tests also
  reject stale/saved/wrong-ID/background/shell targets and attempted-send fallback.
- Generic vocabulary samples and the focus-frame queue no longer carry the
  upstream author's identity. Upstream attribution and historical fixtures remain.

Final release built at **12:32** was staged, swapped only while idle, launched,
and verified signed after both local workers started. English persisted. About
now reports 12 gesture rows at 482×799, confirmed in native Accessibility text.
Its new ad-hoc signature again requires renewed Accessibility and Screen
Recording grants; the new process reports both unavailable. The real-device
results above belong to the preceding 11:44 build. Binding clears on relaunch.

These results do not establish untested physical mouse controls or configured
cloud-provider behavior. The manual guide covers those checks explicitly.
