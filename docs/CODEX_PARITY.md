# Codex fork: implementation and evidence

This matrix describes the current source tree separately from runtime evidence.
“Implemented” means there is code or a route for the behavior; it does not mean
the behavior passed end to end. Record evidence here after following [the manual
test guide](CODEX_TEST_GUIDE.md).

| Area | Implementation in this fork | Verification evidence |
|---|---|---|
| Build and identity | SwiftPM and packaging use `local.walkie-talkie`. Fresh-profile engine default is Local Whisper; microphone discovery is system-based with automatic selection. Packaged Python helpers suppress bytecode writes inside the signed bundle. | **Verified build/install/startup.** Release bundle installed and launched; local API responds; final signature verified after workers started. Full Swift suite: 304 executed, 2 opt-in integration checks skipped, 0 failures; 302 passed. The opt-in native PTY checks also passed in a separate disposable run. Cached official Swift 6.2.3 leaves system CLT unchanged. Ad-hoc signing means macOS may require permissions again after rebuilding. |
| Codex CLI discovery | `CodexBridge` resolves the helper and bundled native CLI executable; `CODEX_BIN` can override the binary. | **Verified.** Native CLI connected in PTY E2E; installed helper doctor resolves the native binary and version. |
| Chat picker | Compact project-first floating panel. Project-folder search leads to that folder’s current and historical chats; keyboard search/arrows/Return/Escape and outside dismissal. Shared-daemon metadata pages are followed; exact stable-ID ownership is checked at activation. Live binds, conclusively closed resumes in Terminal, unknown/wrong ID refuses. | **Source verified; new visual pass pending installation.** Grouping and pagination/deduplication regressions pass. The earlier 14:30 picker’s native title search/project-filter selection was confirmed by the user and bound the exact desktop test. The new switcher retains owner and stale-callback safeguards. Groups are recorded cwd folders, not authoritative sidebar project membership; archived chats are excluded and the offline metadata fallback is bounded. |
| CLI chat sending | Codex target is represented in `TerminalBinding`; bound and verified caret delivery call the bridge with text and actual screenshot/crop/film-sheet image inputs. Busy sends can steer the exact active turn. | **Verified in native CLI PTY E2E.** Initial prompt exactly once; follow-up send; synthetic red image read as red; busy follow-up steered the same turn. A separate production caret dispatch resolved the exact foreground CLI ID, displayed `[Image #1]`, and answered `CARET_RPC_RED`. Exited TUIs/shells fail caret ownership checks; attempted RPC failures never fall back to paste or retry. Physical Terminal/VS Code caret interaction remains manual. |
| Codex desktop delivery | Same-user native desktop IPC adapter preserves protocol version and verifies owner discovery for desktop threads. | **Verified in a disposable desktop chat.** Text delivered with the expected reply, a synthetic red image was interpreted as red, and a busy update steered the same active turn and reached the expected marker. Installed-app bind/hold/edit/send also reached that chat; cancel caused no delivery or new turn. Tested with Desktop 26.1007.30912 and native CLI 0.162.0-alpha.17.2. IPC remains internal and version-coupled. Desktop completion uses the receiving model's `set_thread_archived` tool; exact-window closing is unsupported. Completion cue archived only the disposable chat; it was subsequently restored. Archiving interrupts the active turn, so a result must be provided before the archive action. |
| New/resumed sessions | `walkie-codex` starts the shared daemon idempotently, persists the initial prompt through RPC before attaching the CLI TUI, creates/resumes the exact conversation, and writes a tty sidecar. `SpawnTerminal` uses this launcher. | **Packaged new launch verified.** The installed app opened Terminal, delivered one initial prompt, received the exact requested marker, and bound the same CLI thread with a verified PID/TTY sidecar. Native PTY new/resume tests also passed. Packaging now validates capability descriptions, and exact open/tiling scripts compile offline. The user confirmed visible Rebind closed-history resume. Launch records retained the same stable CLI ID; readback still held only its original completed prompt/reply. It had exited by cleanup and was archived without signalling a process or touching Terminal windows. |
| Search and history | `Rebind to…` searches Codex metadata and message history read-only. Each selected history ID is freshly owner-checked: live binds, conclusively closed resumes, unknown fails visibly. Metadata loads after the panel appears, without project-directory icon/Git access. | **Body search and live activation verified in the installed app.** The disposable chat appeared exactly once for text absent from its title; Return bound that same live ID without a new turn. Regression tests cover filtered destinations, stale callbacks, selection preservation and unknown ownership. Codex idle label refresh created no Git children. User-confirmed closed-chat resume also passed on the 14:30 build, with the same ID and no repeated prompt. Other pointer combinations remain manual. |
| Quick answer | `QuickAsk` uses a persistent `quick-worker` for three stages: short answer, web/source check, and adversarial source review. It supports cancellation and source links. | **Installed-app API flow passed.** English: first words 2.30 s, all stages 13.16 s. French: first words 3.67 s, all stages 16.06 s, preserving French. Source hover/click handlers produced quoted URL fragments without opening a browser. Links survived resize; close cancelled a quick question and restored the queued reply, then a later question completed. Visual/pointer interaction remains manual. Timings are individual observations. |
| Local transcription | Helper discovery can reuse Quiet Journal's runtime and on-disk model cache; default model is multilingual with no language allowlist. The optional local language menu supplies the same per-request recognition hint to captions and final decode; Automatic remains the default. A separate worker owns the loaded model and its memory. | **Installed-app decode and spoken delivery passed.** User started/stopped with ⌃⌘D, dictated the requested phrase, and the exact selected desktop chat replied `banana`; delivery metadata reports `local-whisper`. Cached model warm-up 5.12 s. Public 11 s Whisper JFK sample: 2.56 s from the app cache without word timings; 5.31 s with 22 timed words. No chat delivery occurred. About 1.54 GB active model memory plus a 512 MB decode cache was observed; the in-memory model is not shared with Quiet Journal. |
| Cloud transcription/fallback | ElevenLabs cloud rows and local-now/automatic-local options remain. | **Pending.** Test cloud response, injected failure, local fallback race, and provider/mic switching. |
| Wispr Flow | Wispr implementation and menu integration remain controlled by `WT_WISPR_ENGINE`; current source defaults its row on. The raw chord path is separate from a successful engine transcript/delivery. | **Pending.** Validate menu, transcript capture, and delivery independently; do not infer engine reliability from raw chords. |
| Captions and microphone | Local caption-band controls and microphone chooser are implemented; explicit language applies to captions and final decode. | **Partial.** Synthetic band opened/closed with six words; real Mac microphone voice/send and English captions/transcript were confirmed by the user. Both workers ready. Other devices and unplug/reconnect remain manual. |
| Prompt/reply UI | Held prompt, edit/countdown/autosend/cancel/recover, authenticated text/image callbacks, links, and reply-back actions are present. | **Partial.** Installed hold/edit/send/cancel passed; cancel created no turn. Authentication, persistent image copies, resize/queue restoration and source handlers passed. Real spoken “What is two plus two?” automatically invoked `walkie-reply`, returned `shown`, and displayed the bubble confirmed by the user. Bubbles intentionally stay until ×; later replies queue. Pin, image opening and reply-back remain manual. |
| Kamikaze / finish | `kamikaze` adds a completion cue. CLI finish waits for the exact turn and checks sidecar/PID/TTY/root owner. Automatic close is restricted to a window containing exactly the one verified tab; a window with sibling tabs is refused before signaling. Desktop cue uses the receiving chat’s archive tool. | **Real finish audit found and corrected an API mismatch.** Terminal rejects `close tab` (-1708); the guarded sole-tab-window implementation uses its supported close operation. A real packaged disposable CLI then passed single-tab-window close; its exact native PID exited and tty match count became zero. Desktop archive passed on the disposable chat, which was restored; the answer must precede archive because archive interrupts the active turn. |
| Screen/context | Keyboard screenshot, wheel crop/move/cancel, accessibility selection, Chromium DOM picker, film/contact sheet, and media pause/resume are implemented. | **Partial, with real keyboard/browser/film delivery verified.** User confirmed English + ⌃⌘S; two real image inputs reached the exact desktop chat. In Microsoft Edge with the unpacked extension enabled, real ⌘⇧ hold/click outlined and picked `#pick-target`; app logged receipt and the synthetic prompt was cancelled without delivery. A fixture audio element paused on prompt open and resumed on cancel. User film delivery produced a genuine 14-frame contact sheet plus screenshot; Codex described the fixture. A second 42-frame film plus selected text correctly described the user selecting synthetic fixture sentences. Wheel crop/move, DOM drag, multi-tab media and iframe cases remain manual. |
| Gestures and caret | ⌃⇧⌘B opens the picker globally; ⌃⌘B does too while desktop-bound and retains direct CLI binding otherwise. ⌃⌘D and ⌃⌘S work in either gesture mode. Logi/Wheel handlers, plain dictation, caret prompts, and clipboard/paste-last remain. Verified Codex caret prompts use stable-ID RPC; generic fields receive paste without Return. | **Partial.** Real keyboard voice/shutter/film and browser picker passed. Native PTY production caret dispatch passed with a real image; 7 deterministic caret tests pass and 2 opt-in tests passed separately. Physical Logi/Wheel gestures, native Terminal/VS Code focus interaction, and clipboard restoration remain manual. No Options+ is required for keyboard controls. |
| Outbox/restart/login/settings | Outbox records delivered events; guarded restart and menu preferences remain. | **Partial.** Graceful idle replacement/relaunch passed; the 13:53 build’s renewed grants verify, its event-tap canary is alive (0.32 ms), English persisted and both workers are ready. Chat binding is cleared on relaunch and must be selected again; exact disposable binding was restored through the owner-checked route. Login registration reports enabled; actual login, other preferences and restart under varied conditions remain manual. |
| Voice corpus and report helper | Transcribed recordings retain WAV plus transcript whether or not delivered. Cancelled takes are staged for five minutes and can enter the corpus if recovered and transcribed; outbox records delivered prompts only. | **Retention documented; report helper not installed or scheduled.** Default preview and explicit recipient/inbox requirements pass two tests. No report email was sent. No private Quiet Journal audio was used. |

## Evidence log

Evidence below separates implementation from observed results. A helper
protocol test or read-only ownership probe does not establish desktop send or
full UI parity. Include app build/revision, date, method, and evidence location
for future runs. Redact private chat content, audio, tokens, paths, and credentials.

| Date/build | Area and method | Result/evidence |
|---|---|---|
| Current debug build | `./tools/swift-build.sh build` using cached official Swift 6.2.3 toolchain and compiler workaround; system CLT unchanged. | Debug application build succeeds; full XCTest suite: 304 executed, 2 skipped, 0 failures (302 passed). |
| 2026-10-15 release | Signed bundle build, install, launch, local API, and signature verification after model startup. | Passed. Both transcription workers ready using Quiet Journal runtime/cache; Quiet Journal health remains good. Microphone and Screen Recording are enabled. After removing/re-adding the current app in Accessibility and reopening, startup reports trusted=true/eventTap=true; the harmless canary is alive (about 0.14 ms). The earlier stale grant is resolved. Real spoken start/stop/send subsequently passed; other physical gestures remain separate checks. |
| 2026-10-15 CLI identity follow-up | Real native CLI and isolated cold-start tests. | Native daemon symlink accepted with ownership checks; shared read and TTY resolve retain the same verified CLI identity; initial prompt completed exactly once; exited CLI disappears from live rows; synthetic test archived. Isolated cold start installed daemon, initialized RPC and attached TUI successfully, then stopped/cleaned only its own daemon. |
| Current Python tests | Full Python test suite. | 77 tests pass. |
| CLI integration | Native Codex CLI PTY smoke on a disposable conversation. | Initial prompt exactly once; follow-up direct send; synthetic red image read as red; busy send steered the same turn ID and reached expected final marker. Test chat archived; TUI exited 0. |
| Finish helper | Native guarded product-helper close on a disposable packaged CLI session. | The original dry-run passed and its exact Codex TUI exited, but Terminal rejected tab close (-1708). The corrected implementation supports only a verified single-tab window; multi-tab refusal occurs before signaling. The corrected real-session close passed; exact PID exited and tty match count became zero. |
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

The subsequent runtime audit fixed body-only Rebind deduplication and a bulk
ownership-probe miss that incorrectly labelled the known live chat closed.
History activation now rechecks the exact stable ID; unavailable ownership
cannot silently open a second copy. The installed panel’s body search and live
activation passed. Project icons and Codex label refresh no longer access
project paths or run Git merely to draw/refresh a row.

Packaged Start New initially failed with AppleScript syntax error -2741 before
creating a chat. Parenthesized `(do script …)` and bundle-ID addressing fixed
it. The 13:35 installed build then launched a real native Codex CLI, delivered
its initial prompt exactly once, received the exact marker, and bound that ID.

The same real-session finish check found Terminal’s -1708 rejection of closing
a tab object. The helper now uses the supported window operation only when
that window contains exactly the one verified tab, refusing sibling-tab cases
before terminating Codex. The corrected real-session close passed; its native PID exited and the tty had
zero Terminal matches afterward. Installed permissions are recorded separately. Ad-hoc signing can invalidate grants
on every code rebuild; binding clears on relaunch. Physical mouse controls and
configured cloud providers remain unverified, with procedures in the guide.

## Earlier installed release — 15 October 2026, 13:53

The final release includes the Rebind/ownership, Terminal launch and guarded
single-tab finish fixes. Its packaged helpers match the tested source byte for
byte; both local workers are ready, English persisted, and its installed deep
strict signature verifies after startup. Swift: 299 executed, 2 opt-in skips,
0 failures (297 passed); both opt-in native checks passed separately. Python:
77 passed. The user refreshed both grants and reopened the app. Accessibility
and Screen Recording now verify; the event-tap canary is alive (0.32 ms), and
the exact disposable desktop chat is bound again. No additional rebuild is planned.

A closed-history audit found a concrete timeout mismatch: the native Codex
router permits ten seconds for peer discovery before returning `no-client-found`,
but the bridge’s default socket deadline was five seconds. Strict read-only
history activation now allows twelve seconds; ordinary metadata, bulk scans,
sends and no-retry behavior retain their existing deadlines. A real exact read
of the disposable closed CLI chat returned conclusive `ownerState: closed` in
10.13 seconds. The overlay shows “checking Codex chat…” while this runs.
Swift: 297 passed with 2 opt-in skips; Python: 77 passed. Packaged closed-history
resume still needs a post-install check while the Mac is unlocked. A timeout
still means unknown, never closed.

Picker follow-up: quick-scan misses no longer disable binding or claim the chat
is saved. Bind checks the selected exact ID asynchronously and only a fresh
live owner can be accepted. Closed/unknown/wrong-ID results cannot bind or
resume. Selection/filter/reload/close/reopen invalidate pending callbacks;
duplicate clicks are refused. Focused binding tests: 16 passed. Full Swift:
299 executed, 2 opt-in skips, 0 failures (297 passed). Native picker interaction
and packaged closed-chat resume remain post-install checks while unlocked.

## Earlier installed release — 15 October 2026, 14:30

The combined deadline/picker build is installed. Both local workers are ready,
English persisted, packaged helpers match source, and the deep strict signature
verifies after startup. The 14:19 package’s exact owner check already returned
conclusive closure in 10.46 seconds; its helper is unchanged in this build.
Swift: 299 executed, 2 opt-in skips, 0 failures (297 passed). Python: 77 passed.
After the user renewed the installed-app grants and reopened it, Accessibility
and Screen Recording both verify. The shortcut canary responds (0.91 ms),
English is retained and the disposable desktop chat is bound again. The native
inspector does not expose the floating controls; picker/project-filter and
closed-history resume clicks were subsequently confirmed by the user. The launch
records retained the original stable CLI ID and history still contained one
original completed turn. The CLI had exited by cleanup; only that disposable
chat was archived and the desktop test binding restored.

## Project-first switcher update

The new panel matches the floating Rebind style and begins with project folders,
then shows current and past chats within the chosen folder. ⌃⇧⌘B opens it from
any app/binding state; ⌃⌘B does too while bound to desktop. The mouse's direct
terminal-binding gesture remains. Search is focused; arrows/Return navigate and
activate; Escape returns to projects or dismisses. Saved chats explicitly reopen
in Terminal after a conclusive fresh owner check. This does not automatically
create native desktop chats or assign sidebar project membership.

Current source suite: 304 executed, 2 opt-in skips, 0 failures (302 passed).
Python helper source is unchanged with 77 passing checks. The updated daily
workflow guide distinguishes editing a draft with F5, sending to a bound chat,
new CLI chats in the same/different folder, and native desktop projectless chats.
Installation and visible switcher evidence are recorded after the new build.
