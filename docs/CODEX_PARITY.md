# Codex fork: implementation and evidence

This matrix describes the current source tree separately from runtime evidence.
“Implemented” means there is code or a route for the behavior; it does not mean
the behavior passed end to end. Record evidence here after following [the manual
test guide](CODEX_TEST_GUIDE.md).

Morgan chose **Keep Local; leave optional checks for later** on 15 October 2026.
The installed Local/English keyboard workflow is verified. Live cloud/Wispr,
mouse hardware, additional-device and remaining pointer/edge checks stay listed
for later; their implementations are retained, and they are not claimed as
passed end to end.

| Area | Implementation in this fork | Verification evidence |
|---|---|---|
| Build and identity | SwiftPM and packaging use `local.walkie-talkie`. Fresh-profile engine default is Local Whisper; microphone discovery is system-based with automatic selection. Packaged Python helpers suppress bytecode writes inside the signed bundle. | **Verified build/install/startup.** Release bundle installed and launched; local API responds; final signature verified after workers started. Full Swift suite: 330 executed, 2 opt-in integration checks skipped, 0 failures; 328 passed. The opt-in native PTY checks also passed in a separate disposable run. Cached official Swift 6.2.3 leaves system CLT unchanged. Ad-hoc signing means macOS may require permissions again after rebuilding. |
| Codex CLI discovery | `CodexBridge` resolves the helper and bundled native CLI executable; `CODEX_BIN` can override the binary. | **Verified.** Native CLI connected in PTY E2E; installed helper doctor resolves the native binary and version. |
| Chat picker | Compact borderless quick access: activity-ordered recent chats with folder labels, optional folder filter, last prompt/answer, Enter to bind and Command-Enter to open in the saved Desktop/Terminal destination. Pending requests remain keyboard reachable. | Swift suite: 362 executed, two opt-in skips, zero failures. Metadata-only first 100 fetch measured 0.10 s and latest pair 0.06 s on this machine. Installed keyboard/open checks are recorded in the latest evidence below; earlier large explorer evidence is historical. |
| CLI chat sending | Codex target is represented in `TerminalBinding`; bound and verified caret delivery call the bridge with text and actual screenshot/crop/film-sheet image inputs. Busy sends can steer the exact active turn. | **Verified in native CLI PTY E2E.** Initial prompt exactly once; follow-up send; synthetic red image read as red; busy follow-up steered the same turn. A separate production caret dispatch resolved the exact foreground CLI ID, displayed `[Image #1]`, and answered `CARET_RPC_RED`. Exited TUIs/shells fail caret ownership checks; attempted RPC failures never fall back to paste or retry. Physical Terminal/VS Code caret interaction remains manual. |
| Codex desktop delivery | Same-user native desktop IPC adapter preserves protocol version and verifies owner discovery for desktop threads. | **Verified in a disposable desktop chat.** Text delivered with the expected reply, a synthetic red image was interpreted as red, and a busy update steered the same active turn and reached the expected marker. Installed-app bind/hold/edit/send also reached that chat; cancel caused no delivery or new turn. Tested with Desktop 26.1007.30912 and native CLI 0.162.0-alpha.17.2. IPC remains internal and version-coupled. Desktop completion uses the receiving model's `set_thread_archived` tool; exact-window closing is unsupported. Completion cue archived only the disposable chat; it was subsequently restored. Archiving interrupts the active turn, so a result must be provided before the archive action. |
| New/resumed sessions | N inherits bound cwd; repeat N chooses saved default/folder picker. First reviewed send creates a background chat and submits its prompt once. Detached shared-daemon broker keeps turns/callbacks alive after the submitting UI exits. Optional Terminal attachment defaults off and reuses verified idle untouched hosts. D retains its current stable binding. | Native detached submission and follow-up completed; active remote CLI attachment preserved the same turn ID. Genuine native command approval remained pending until explicit response, then completed. Desktop history opens directly and delegates its read-only writer-conflict state to Desktop; sending/CLI ownership checks remain strict. Installed-app evidence follows below. |
| Default new-chat folder | **New chat folder → Choose folder…** saves an arbitrary folder; **Use ~/workspace** resets it and creates that directory if needed. Fresh profiles default to `~/workspace`; saved choices override the legacy `WT_PROJECT_ROOT` hint. Each take latches its default at recording start. One-take folder picks still override it. | Four preference regressions passed: fresh default, tilde expansion, saved choice/reset precedence with spaces, invalid relative values. Swift suite: 321 executed, 2 opt-in skips, no failures (319 passed). Installed 18:28 build reports `/Users/morganridel/workspace`; both local workers are ready and the signature verifies after worker start. The 18:28 menu interaction was not visually checked. Existing grants were subsequently refreshed for the 19:17 build after unlock; its running process verifies both permissions. |
| Search and history | Explorer searches prompts/answers only within the selected recorded cwd, across all local dates. Native and read-only offline catalogs paginate. Archived chats hidden by default with an include toggle; exact guardian metadata is excluded from catalogs, search and direct preview. | Catalog/helper and explorer regressions cover scope, old answers, archive/guardian filtering, sparse schemas, large history and older-page retention. Native and packaged evidence follows below. Local CLI/Desktop views share stored history only when using the same Codex home/account. |
| Quick answer | `QuickAsk` uses a persistent `quick-worker` for three stages: short answer, web/source check, and adversarial source review. It supports cancellation and source links. | **Installed-app API flow passed.** English: first words 2.30 s, all stages 13.16 s. French: first words 3.67 s, all stages 16.06 s, preserving French. Source hover/click handlers produced quoted URL fragments without opening a browser. Links survived resize; close cancelled a quick question and restored the queued reply, then a later question completed. Visual/pointer interaction remains manual. Timings are individual observations. |
| Local transcription | Helper discovery can reuse Quiet Journal's runtime and on-disk model cache; default model is multilingual with no language allowlist. The optional local language menu supplies the same per-request recognition hint to captions and final decode; Automatic remains the default. A separate worker owns the loaded model and its memory. | **Installed-app decode and spoken delivery passed.** User started/stopped with ⌃⌘D, dictated the requested phrase, and the exact selected desktop chat replied `banana`; delivery metadata reports `local-whisper`. Cached model warm-up 5.12 s. Public 11 s Whisper JFK sample: 2.56 s from the app cache without word timings; 5.31 s with 22 timed words. No chat delivery occurred. About 1.54 GB active model memory plus a 512 MB decode cache was observed; the in-memory model is not shared with Quiet Journal. |
| Cloud transcription/fallback | ElevenLabs cloud rows and local-now/automatic-local options remain. | **Offline transport and spoken missing-key fallback verified.** Ten in-memory URLProtocol cases exercise the actual multipart request, successful word/spacing parse, malformed/empty replies, non-retried 401/422 and timeout, bounded 429/server/transport retries, delayed fault and upload cancellation. The fixture uses an empty synthetic WAV and dummy key; every request is intercepted and no audio leaves the process. The user also dictated through keyless ElevenLabs; app metadata reports `local-fallback` to the exact test chat, and native readback shows one completed request/reply, `fallback ok`. Local/English was restored. Live provider transcription, cloud/local winner races and microphone switching remain unverified. |
| Wispr Flow | Wispr implementation and menu integration remain controlled by `WT_WISPR_ENGINE`; current source defaults its row on. The raw chord path is separate from a successful engine transcript/delivery. | **Pending.** Validate menu, transcript capture, and delivery independently; do not infer engine reliability from raw chords. |
| Captions and microphone | Local caption-band controls and microphone chooser are implemented; explicit language applies to captions and final decode. The chooser enumerates connected CoreAudio inputs, explicit choices use persistent device UIDs, and Automatic follows the macOS default input. Legacy named choices remain supported. | **Partial.** Synthetic band opened/closed with six words; real Mac microphone voice/send and English captions/transcript were confirmed by the user. USB selection/fallback regression and installed-app evidence are recorded below. Physical USB speech and unplug/reconnect remain manual. |
| Prompt/reply UI | Held prompt, edit/countdown/autosend/cancel/recover, authenticated text/image callbacks, links, and reply-back actions are present. | **Partial.** Installed hold/edit/send/cancel passed; cancel created no turn. Authentication, persistent image copies, resize/queue restoration and source handlers passed. Real spoken “What is two plus two?” automatically invoked `walkie-reply`, returned `shown`, and displayed the bubble confirmed by the user. Bubbles intentionally stay until ×; later replies queue. Pin, image opening and reply-back remain manual. |
| Kamikaze / finish | `kamikaze` adds a completion cue. CLI finish waits for the exact turn and checks sidecar/PID/TTY/root owner. Automatic close is restricted to a window containing exactly the one verified tab; a window with sibling tabs is refused before signaling. Desktop cue uses the receiving chat’s archive tool. | **Real finish audit found and corrected an API mismatch.** Terminal rejects `close tab` (-1708); the guarded sole-tab-window implementation uses its supported close operation. A real packaged disposable CLI then passed single-tab-window close; its exact native PID exited and tty match count became zero. Desktop archive passed on the disposable chat, which was restored; the answer must precede archive because archive interrupts the active turn. |
| Screen/context | Keyboard screenshot, wheel crop/move/cancel, accessibility selection, Chromium DOM picker, film/contact sheet, and media pause/resume are implemented. | **Partial, with real keyboard/browser/film delivery verified.** User confirmed English + ⌃⌘S; two real image inputs reached the exact desktop chat. In Microsoft Edge with the unpacked extension enabled, real ⌘⇧ hold/click outlined and picked `#pick-target`; app logged receipt and the synthetic prompt was cancelled without delivery. A fixture audio element paused on prompt open and resumed on cancel. User film delivery produced a genuine 14-frame contact sheet plus screenshot; Codex described the fixture. A second 42-frame film plus selected text correctly described the user selecting synthetic fixture sentences. Wheel crop/move, DOM drag, multi-tab media and iframe cases remain manual. |
| Keyboard aliases and recording reminder | Every legacy F3–F12 action has a Control-Command alias. Letter matching uses the current keyboard layout. The default recording hint is a compact action/shortcut list in either mouse mode; the original mouse legend remains selectable. Cancel-only Escape is separate from the legacy cancel/Quick Ask gesture. | Nine new tests pass, including actual in-process event-handler dispatch without posting events, repeat suppression, precise modifiers and rendered stage previews. Full Swift suite: 330 executed, 2 opt-in skips, no failures (328 passed). Installed 19:17 build reports Keyboard hints by default; a microphone-free synthetic recording showed the three plain-dictation shortcuts and cancel hid the reminder, with no new delivery. Local/English, workspace default, workers and deep strict signature verify. After unlock, existing grants were refreshed through System Settings: Accessibility/event tap and Screen Recording verify, the launch canary is alive (0.6 ms), and the saved test-chat binding was restored. Morgan physically confirmed Control-Command-I inserted spoken words into a disposable draft without submission and the keyboard recording reminder appeared. App metadata reports local-whisper delivery to the caret. Other letter aliases retain dispatch/unit coverage rather than a full physical pass. No mouse gesture recognizer was added. |
| Reply delivery without network approval | `walkie-reply` prefers an authenticated private temporary file inbox with atomic publication and receipts. The app claims each request once; unknown outcomes retain staging and never fall back or retry. Text, images and exact chat IDs share the existing reply handler, including foreground-CLI suppression. HTTP remains compatible with older app versions. | Swift inbox regressions pass authentication/rejection, exactly-once claiming, suppression receipts, incomplete/malformed/oversized requests and symlink refusal. Python regressions pass text/image delivery without network, private-directory validation and timeout retention. Full Swift: 334 executed, 2 opt-in skips, 0 failures (332 passed). Python: 80 passed. Installed/sandbox/visible evidence is recorded in the follow-up below. |
| Gestures and caret | ⌃⇧⌘B opens the picker globally; ⌃⌘B does too while desktop-bound and retains direct CLI binding otherwise. ⌃⌘D and ⌃⌘S work in either gesture mode. Logi/Wheel handlers, plain dictation, caret prompts, and clipboard/paste-last remain. Verified Codex caret prompts use stable-ID RPC; generic fields receive paste without Return. | **Partial.** Real keyboard voice/shutter/film and browser picker passed. The user also confirmed physical F5 inserted spoken words into an unsent desktop draft without submission; metadata reports caret/local-whisper and native readback shows no new chat turn. Native PTY production caret dispatch passed with a real image; 7 deterministic caret tests pass and 2 opt-in tests passed separately. Physical Logi/Wheel gestures, native Terminal/VS Code focus interaction, and clipboard restoration remain manual. No Options+ is required for keyboard controls. |
| Outbox/restart/login/settings | Outbox records delivered events; guarded restart and menu preferences remain. | **Partial.** Graceful idle replacement/relaunch passed; the 13:53 build’s renewed grants verify, its event-tap canary is alive (0.32 ms), English persisted and both workers are ready. Chat binding is cleared on relaunch and must be selected again; exact disposable binding was restored through the owner-checked route. Login registration reports enabled; actual login, other preferences and restart under varied conditions remain manual. |
| Voice corpus and report helper | Transcribed recordings retain WAV plus transcript whether or not delivered. Cancelled takes are staged for five minutes and can enter the corpus if recovered and transcribed; outbox records delivered prompts only. | **F5 recording/transcript retention verified; report helper not installed or scheduled.** The exact F5 capture has a nonempty transcript and a 227,946-byte WAV, timestamped 6 ms before its caret delivery. No audio was read. Default preview and explicit recipient/inbox requirements pass two tests. No report email was sent. No private Quiet Journal audio was used. |

## Evidence log

Evidence below separates implementation from observed results. A helper
protocol test or read-only ownership probe does not establish desktop send or
full UI parity. Include app build/revision, date, method, and evidence location
for future runs. Redact private chat content, audio, tokens, paths, and credentials.

| Date/build | Area and method | Result/evidence |
|---|---|---|
| Current debug build | `./tools/swift-build.sh build` using cached official Swift 6.2.3 toolchain and compiler workaround; system CLT unchanged. | Debug application build succeeds; full XCTest suite: 330 executed, 2 skipped, 0 failures (328 passed). |
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

Initial switcher source suite: 304 executed, 2 opt-in skips, 0 failures (302 passed).
Python helper source is unchanged with 77 passing checks. The updated daily
workflow guide distinguishes editing a draft with F5, sending to a bound chat,
new CLI chats in the same/different folder, and native desktop projectless chats.
The **15 October 2026, 15:47** build is installed and pushed as `942faa4`.
With the user's authorization, both existing privacy entries were removed and
re-added through native System Settings UI. The running process reports
Accessibility/event tap and Screen Recording enabled; its shortcut canary is
alive (0.43 ms), English persists, both workers are ready, the reusable desktop
test is bound and the deep strict signature verifies. The read-only picker
inspector is available. Native automation keypresses did not open the picker;
the menu-bar automation then timed out. The user physically confirmed that ⌃⇧⌘B opens the switcher, but keyboard
navigation and clicking a project did not work. This contradicts a full UI
pass: single-click was not wired, and selection/focus refresh needed repair.
The subsequent navigation repair and physical confirmation are recorded below.

## Picker navigation repair

The physical global shortcut opened the 15:47 switcher, but the user could not
navigate with keys or open a project with a single click. Rows had only a
double-click action, and full table reloads during chrome/selection updates
cleared selection. Keyboard commands handled only by the search field also
missed table focus.

The repair uses single-click activation, keeps focus in the editable search,
handles plain navigation keys at the key panel, and redraws row content without
clearing selection. Modified keys and marked-text composition remain editor
input. Exact stable-ID ownership checks and stale-callback gates are unchanged.
Full source suite: 306 executed, 2 opt-in skips, no failures (304 passed).
An AppKit fixture drives the real key panel's event dispatch with field-editor
and table focus; this is component evidence, not a physical end-to-end UI pass.
The **16:21** navigation-repair build is installed. Both existing permission
entries were refreshed through System Settings by the agent; Accessibility/event
tap and Screen Recording verify, the canary is alive (2.16 ms), English and both
local workers are ready, and the reusable desktop test is bound. Deep strict
signature verification passed. The user confirmed arrows, Return, Escape and single-click project activation.
Independent readback shows the exact selected stable desktop test ID bound.

A narrowly scoped native metadata query found both disposable test-project chats
in 0.31 seconds. All 37 file-backed Mach-O sections of the 15:47 installed
binary matched its release output; raw hashes differ because of signing data,
and the installed deep strict signature verifies. Automatic approval review
rejected a broader private-thread metadata audit; no workaround was used.

## Project order

Project folders retain their first occurrence in Codex's newest-first chat
metadata, so the folder with the most recent chat appears first. Conversations
within each folder and filtered project results retain that same recency order.
A regression case deliberately puts Zebra ahead of Alpha and checks grouping
and filtering preserve the order. Full suite: 307 executed, 2 opt-in skips,
no failures (305 passed). The order follows chat recency; Codex desktop's manual
sidebar order is not copied.

The **15 October 2026, 16:35** recency-order build is installed. Both existing
macOS permission entries were refreshed through System Settings. Accessibility
and Screen Recording verify, the shortcut canary responds (5.60 ms), both local
workers are ready, English remains selected and the disposable desktop test
is bound. The installed deep strict signature verifies. Sorting has regression
coverage; the earlier 16:21 keyboard/click flow was physically confirmed.


## Offline cloud transport verification

Ten `ElevenLabsTransportTests` pass against the production upload/parser/retry
function using an injected ephemeral URLSession. Every request is intercepted
in memory, including retries and delayed-fault requests. The shared session
remains the production default. The synthetic WAV contains only an empty PCM
header, so the fixture neither reads private audio or credentials nor updates
the audio cost ledger.

The full Swift suite now executes 317 cases: 315 pass, 2 opt-in skips, no failures.
Release packaging passed and the **16:56** signed bundle is installed. Both
existing permission entries were refreshed through System Settings. Accessibility
and Screen Recording verify, the shortcut canary responds (0.48 ms), English
and both local workers are ready, the test chat is bound and the deep strict
signature verifies. The only app-code change permits injecting the test session
and keeps the shared session as the default. This is transport coverage, not a full cloud recognizer
or AppDelegate fallback pass. `/test/local-fallback` independently verifies local decoding but bypasses
the source failure handoff. The app-level missing-key spoken fallback passed on the 16:35 build: the user
confirmed recovery and one reply; delivery metadata reports `local-fallback`
to the exact disposable desktop ID. Native readback shows one completed
request/reply with final answer `fallback ok`. The default Local engine and
English were restored. Configured live-provider transcription, cloud/local
winner races, Wispr, additional microphones and physical mouse gestures remain
unconfigured or unverified.


## Final core workflow check

On the installed 16:56 build, the user confirmed F5 start/stop inserted spoken
words into an existing unsent desktop draft without submitting it. App metadata
reports `via: local-whisper`, `to: caret`; the binding stays on the exact desktop
test ID. Native chat readback still ends at the previous completed fallback
turn, so the F5 check created no turn. The app is idle afterward, Local and
English remain selected, and both current workers are ready and run in Quiet
Journal's interpreter. The caption worker now has a replacement PID and is
ready. Its normal close path can kill an in-flight caption decode to release
the GPU, then warm a replacement.

The saved F5 take has a nonempty transcript and a WAV larger than its header,
with a capture timestamp 6 ms before the independent caret delivery record.
Only that test pair's text/metadata was inspected; no recording audio was read.


## Configurable new-chat folder — 15 October, 18:28 build

The default is restored to `~/workspace`, and **New chat folder → Choose
folder…** saves another folder without restarting. **Use ~/workspace** resets
it. A recording keeps the default it started with; the temporary folder menu can
still replace it for that take. The standard workspace is created if absent;
missing custom folders retain the launcher's existing failure behavior.

The installed app reports the saved workspace default, Local/English, two ready
workers and a valid deep strict signature. The full Swift suite passed with
319 passes and 2 opt-in skips. The Mac is locked, so the visible menu check and
renewal of existing Accessibility/Screen Recording grants await an unlock.
This build currently reports those grants unavailable. No microphone or chat
prompt was sent for this settings change.


## Keyboard shortcuts and recording reminder — 15 October, 19:17 build

The letter aliases work in either mouse mode, without Fn or Options+. The old
F-key/mouse routes remain. Keyboard recording reminders are the default;
Gestures offers the original mouse legend as an alternative. Dark/light prompt,
filming, plain and Quick Ask layouts were rendered and visually inspected.

The full Swift suite passed: 330 executed, 2 opt-in skips, no failures (328
passed). A synthetic installed-app plain recording displayed Stop/insert ⌃⌘I,
Stop + Return ⌃⌘E and Cancel ⌃⌘Esc; cancellation hid it and restored idle. This
used no microphone, screenshots or chat delivery. Both local workers are ready,
English and `/Users/morganridel/workspace` are preserved, and the deep strict
signature verifies after worker startup. Python helpers did not change.

After Morgan unlocked the Mac, the existing Accessibility and Screen Recording
entries were removed and re-added through System Settings while the idle app
was gracefully quit. Morgan approved the macOS authentication dialog locally.
The relaunched 19:17 build reports Accessibility trusted, event tap enabled and
Screen Recording allowed. Its launch canary passed in 0.6 ms, both Local workers
are ready, English/workspace/keyboard-hint settings are preserved, the saved
test-chat binding was owner-checked and restored, and the deep strict signature
verifies. Morgan then physically confirmed that Control-Command-I started/stopped dictation, inserted the words without submitting, and displayed the new Control-Command recording reminder. Read-only app metadata reports a local-whisper caret delivery at 17:58:53Z. Other aliases were not separately exercised physically.

## Recording crash and reply approvals — 15 October, 20:37 build

Both user crash reports (20:19 and 20:26) contain the same uncaught
`NSInvalidArgumentException`: CoreText attempts a nil dictionary insertion while
applying a font in `GestureHintBar.Board.keyboardColumnWidth`, called from a
pointer event. Pointer placement now uses cached layout dimensions. Shortcut
labels use the regular system font family, and keyboard measurement/drawing
run through the existing Objective-C exception guard. A regression injects the reported
exception and verifies usable fallback dimensions; another exercises 4,000
pointer placements across recording stages. Updated reminder previews render
and were visually inspected. Physical new-chat recording remains to be retried.

Recent logs also show three successful reply callbacks deliberately suppressed
because their CLI terminal was foreground. Morgan confirmed this suppression
should stay; the actual concern was repeated localhost approval prompts. The
helper now prefers private temporary file IPC and the question footer tells
Codex to run it normally. HTTP stays available for older app versions. No Codex
network/sandbox settings were broadened. The installed helper displayed a
synthetic text reply and then a real synthetic PNG from normal sandboxed
commands with no escalation or network access. An invalid-token request
returned 403. Tests cover text/images, authentication, suppression receipts,
atomic publication, exactly-once claiming and unknown-outcome retention.

Swift: 334 executed, 2 opt-in skips, no failures (332 passed). Python: 80 passed.
Release build/install/startup passed; both local workers became ready, English
and the workspace default persisted, and the installed deep strict signature
verified after startup. Ad-hoc signing invalidated the existing Accessibility
and Screen Recording grants. Morgan approved System Settings authentication;
both existing entries were removed and re-added through the native UI while
the app was idle and gracefully stopped. The 20:55 relaunch verifies
Accessibility trusted, event tap enabled and Screen Recording allowed. Both
workers are ready; the shortcut canary passed in 0.15 ms and the deep strict
signature verifies after worker startup. A further normal sandboxed helper
call succeeded after this relaunch. Physical new-chat recording remains a
user retry, rather than a claimed end-to-end pass. A
microphone-free installed-app start/cancel check displayed all three plain
recording hints, then restored idle and hid the reminder; it sent no prompt.


## Menu keyboard shortcuts — 16 October 2026

The status menu now uses native keyboard equivalents for binding, the project/chat
switcher, prompt destinations, plain dictation, stop/cancel, film and screenshots.
Letter aliases share the existing `WalkieKeyboardShortcut` definitions. Mouse
mode changes retain the keyboard column and update the mouse tooltips/About
legend. Mouse-only area selection and browser picking leave the keyboard column
empty. Disconnect shows its contextual ⌃⌘T shortcut only outside a recording.
The film row retains its current start/stop title when shortcuts refresh.

Debug build and full Swift suite passed: 334 executed, 2 opt-in integration
skips, no failures (332 passed). These checks do not exercise physical keys or
microphone input. Installed menu visual verification is pending.

## USB microphone discovery repair — 2026-10-17

macOS reports `USBAudio1.0` (Jieli Technology, USB, mono 48 kHz) as its
default input. The previous installed app reported `chosen=mac` and offered
only the upstream microphone roster, so this USB input was absent from its
picker. Its automatic ladder also preferred the built-in mic over unfamiliar
system inputs.

The picker now enumerates connected inputs by actual CoreAudio name and saves
explicit selections by UID. Automatic follows the macOS default input; a
missing explicit UID falls back without forgetting the preference. Device-list
and default-input changes are observed. Existing explicit roster selections
remain valid. Unit tests cover an unfamiliar default USB mic, duplicate names,
changed numeric device IDs, unplug fallback/reconnect restoration, legacy Mac
selection, picker inclusion and preference validation.

Debug build passed. Full Swift suite: 339 executed, 2 opt-in integration
skips, 0 failures (337 passed), including five microphone regressions.
Release bundle installed with the guarded restart. The installed `/engine`
reports Automatic selected, `device=USBAudio1.0`, no test override, and enabled
rows for the USB, iPhone and built-in inputs. Both local workers are ready.
Deep strict codesign verification passed after worker startup. The stale
Accessibility and Screen Recording entries required removal/re-addition through
System Settings (Morgan authenticated); final startup reports trusted=true,
eventTap=true, a live launch canary and screenCaptureAllowed=true. The Microphone
switch was already enabled. These checks verify discovery, menu contents,
selection and permissions. At 14:26:44 the running app also logged an actual
recording through USBAudio1.0 at 48 kHz mono. Speech quality and physical
unplug/reconnect remain separate manual checks.


## Desktop-first new chat — historical attempt, superseded below

Only the new-chat command changes. First ⌃⌘N records for a new Desktop chat in
its bound Codex chat’s full cwd, or the saved default when unbound. A repeated N
while recording switches to the saved default and opens the folder/client picker.
The picker offers Desktop, CLI, the default, the bound folder and existing project
rows. Client and cwd are carried with the sentence through transcription, review,
queue parking and a failed existing-terminal pick. Normal ⌃⌘D still addresses the
bound chat. Chat creation happens only after the reviewed prompt commits.

Desktop creation starts only a fresh ID in the shared daemon, names it from the
reviewed text, and flushes/releases its writer using archive/unarchive on that
new, message-free ID alone. Unsubscribe alone retains the writer through a grace
period and is insufficient. The restored ID must be notLoaded; its exact rollout
must contain matching session metadata before opening its Desktop deep link.
Owner discovery verifies that exact ID before binding and first-prompt delivery
through Desktop IPC. No private server resumes a Desktop thread, and unknown
creation/send outcomes do not retry or silently switch to CLI.

Initial disposable empty-chat probes exposed missing-rollout and active-writer
errors in Desktop. Those probes were archived. After the persistence/release fix,
the production helper created and opened a fresh Desktop chat, verified ownership,
and sent one synthetic first prompt over desktop-ipc. Exact-ID readback showed
one completed turn with the expected `WALKIE_DESKTOP_NEW_OK` answer; that test chat
was archived and this working chat restored in the UI. No microphone was used.
Final validation: Swift 342 executed, 2 opt-in integration skips, 0 failures
(340 passed); Python 87 passed. Guarded release build/install/restart completed.
The installed app’s synthetic spawn route created a Desktop chat in the saved
workspace, bound its exact ID, and delivered one first prompt. Exact-ID native
readback showed one completed turn with `WALKIE_PACKAGED_NEW_OK`. That chat was
archived; the prior unbound state and run-only autosend setting were restored.
Both local workers were ready, English and the workspace default persisted, and
deep strict codesign verification passed after worker startup. No microphone or
physical gesture was used. Ad-hoc signing invalidated Accessibility and Screen
Recording. Morgan authenticated in System Settings; both existing entries were
removed and re-added for the installed bundle while the app was idle and stopped.
The final relaunch reports trusted=true, eventTap=true, screenCaptureAllowed=true,
a live shortcut canary (29.8 ms), two ready local workers, Desktop/workspace/English
settings, the original unbound state and autosend setting, and a valid deep strict
signature after worker startup. Physical N / repeated N / D and picker clicks
remain manual verification.


## Background Desktop opening — historical attempt, superseded below

New Desktop chats now use `open -g -b com.openai.codex` for their exact-ID deep
link. This requests opening in the background rather than activating Codex. The
new-chat path itself never calls bringToFront. The helper regression asserts the
background flag, and all 87 helper tests pass. A disposable production-helper
creation with the new flag still passed exact-ID Desktop owner verification.
The foreground-app observer saw only Codex during that run, so preserving another
app’s focus remains a physical verification gap; no external-focus pass is claimed.


Live external-focus check: Morgan placed Edge in front. The observer recorded
Edge at 0.028 s and Codex at 0.370 s after the background deep link. Therefore
`open -g` alone does **not** satisfy focus preservation in Desktop 26.1013.31256;
its URL handler explicitly shows/focuses its primary window. No successful
background behavior is claimed. The disposable test was re-archived. The guarded
helper-only install passed, both existing macOS permission entries were renewed,
and the final relaunch has trusted=true, eventTap=true, a 2.6 ms canary, ready local
workers, a valid deep strict signature, and the exact prior binding restored.
A native interface that creates/loads the chat without navigating the primary
window is still needed for strict focus preservation. A restore-focus workaround
would have a transient activation and has not been implemented.

## Reusable CLI new chats — 17 October 2026

Supersedes the Desktop-first attempts above. New-chat commands now always use
CLI, inherit the bound cwd, and create/send only after review commits. Repeating
N still selects the saved default and opens the folder picker. D continues to
send to the existing bound chat. No Desktop deep link is used for creation.

A Walkie-managed terminal hosts the native remote Codex TUI. The next new chat
can replace that view only while its exact thread is idle and no human keyboard
input has occurred. Busy and manually edited terminals are preserved, including
unsent drafts. Existing unmanaged terminals are left alone. A new terminal is
opened only when no eligible host is available; a cold Terminal launch requests
background/hidden startup. There is no activate/restore-focus workaround.

The mapping verifies host PID/real Terminal TTY, exact launcher argv, child PID,
parent relationship, private child PTY and exact Codex resume ID. Human keyboard
input removes that mapping to avoid misidentifying a manually entered /new.
Finish revalidates the same ownership chain. Old chats remain in local history;
no archive or private Desktop resume is used when switching the terminal view.
An unknown creation/send/transport outcome is never retried or converted into a
second new chat.

Validation so far: 342 Swift tests executed, 2 opt-in skips, zero failures;
96 Python helper tests pass. A native disposable PTY test delivered one prompt
and the expected answer to each of two distinct IDs on the same TTY, verified
that only the new ID had the live mapping, and preserved an unsent human draft
by refusing subsequent reuse. Shutdown originally stalled on undrained PTY
output; closing the owned PTY before waiting fixed it, and the native test then
passed. Codex Desktop's native listing contained both IDs; exact-ID readback
contained the expected single completed turn. All four native probe chats
(including the earlier failed-switch probes) were archived after their hosts
exited. This is protocol/PTY evidence, not a microphone or physical shortcut
check. Installed-app/focus evidence follows below.

Packaged verification: the initial fresh-window send exposed a name collision:
`/Applications/Terminal.app` is Ghostty (`com.mitchellh.ghostty`). The remaining
TerminalBinding scripts now address `com.apple.Terminal` explicitly. Native
binding then returned the exact new chat and its window frame. A second packaged
issue was ps flattening the installed helper path containing `Walkie Talkie.app`;
the verifier now matches the complete known launcher path and immediately
following `--managed` flag. A regression covers that path and rejects misleading
flags in later arguments. Final helper suite: **97 passed**; final full Swift
suite: **342 executed, 2 opt-in skips, zero failures**.

The installed app delivered the expected single-turn replies for fresh-window
and reused-window probes. The reuse replaced the native view on the same
`/dev/ttys004`; the previous ID lost its live mapping and the new ID owned it.
Morgan placed Edge in front. A 42-second foreground observer, including both
synthetic reviewed sends, recorded only `com.microsoft.edgemac` (first sample
0.022 s); neither Terminal nor Codex took focus. All four packaged probe IDs
appeared in Desktop's native chat listing without a deep link or UI navigation.
No microphone or physical shortcut was used in these checks.

The exact original binding was restored. Three packaged probe chats were
archived; the final idle managed terminal is retained as “Walkie Talkie terminal
ready” so the next real new-chat command can reuse it. Managed finish successfully
closed the older, process-verified disposable window. It conservatively refused
the remaining window with `terminal_window_unknown` because Terminal's descriptor
returned “Can't get missing value”; that window was retained rather than forced
closed. This limits automatic finish for that window, not normal new-chat reuse.
The final rebuild's existing Accessibility and Screen Recording entries were
refreshed through System Settings while Walkie was idle/stopped; no TCC database
was modified. Final runtime/signature evidence is recorded below.

Final relaunch: original exact chat binding restored; CLI new-chat default and
saved workspace folder confirmed; idle state; local and live Whisper workers
ready; screenCaptureAllowed=true; accessibility trusted=true/eventTap=true;
launch shortcut canary 29.2 ms. The retained managed terminal still has a verified
live PID/TTY mapping. `codesign --verify --deep --strict` passed after both Python
workers started. No generated bytecode was retained in the bundle.

## Idle terminal reuse follow-up — 17 October 2026

Morgan reported three chats leaving three Terminal windows, despite completed
answers, and had closed the windows before inspection. The launch log showed
that the first reused the retained host and the next two opened new windows.
Those hosts/manifests were gone, so the original rejection reasons cannot be
recovered; no specific rejection is claimed as proven for those three chats.

A reproducible defect was found in input classification: the host treated each
read() packet as a complete terminal response. A fragmented automatic response,
or unrecognized pixel/cell-size report, permanently retired an otherwise idle
host as if it contained human typing. The pre-reuse check also rejected any
queued input, including automatic focus/size reports. Input now parses as a byte
stream across reads, recognizes automatic focus/color/geometry/keyboard-mode
reports, and drains/classifies queued responses before deciding. Actual keyboard
input, drafts, incomplete/unknown controls and active work remain protected.

The controller now saves private last-attempt candidate reason codes in
`~/.walkie-talkie/codex-tty/last-reuse.json`. A host records its retirement reason
in its manifest. Neither contains prompts nor input bytes, and a diagnostic write
failure cannot change delivery. Stable PID/TTY/parent/exact-ID checks and the
unknown-send/no-retry boundary are unchanged.

102 helper regressions passed, including all split positions, byte-at-a-time
responses, queued automatic responses, genuine draft protection, and diagnostic
redaction. A disposable native PTY reproduced fragmented pixel/focus responses,
then completed three distinct single-turn chats on one TTY. A real draft still
prevented reuse. This is protocol/native PTY evidence; installed-app evidence and
permission verification follow below. No microphone was used.

The first installed follow-up test reproduced a remaining failure: two completed
chats reused host 46822 on ttys002, but a third after 75 seconds opened ttys004.
The new diagnostic identified `unrecognized_control_input`, not active work.
Mouse navigation was still being treated as editing. The classifier now accepts
standard SGR/X10 mouse reports without clearing an already-dirty draft, and
records only control-event categories for unknown controls. It also drains an
already-queued reply before expiring its partial prefix after a delayed event
loop. Final helper regressions: **104 passed**. The updated helper was installed;
the final real-window mouse/idle-gap retest is outstanding because Morgan changed
the requested design to windowless asynchronous submission and invoked the
`grilling` interview before implementation. No pass is claimed for that final
installed retest.

The installed app's existing Accessibility and Screen Recording permissions were
refreshed while idle/stopped. An accidental Weather Accessibility entry from the
file chooser was immediately removed; exact-path selection then restored only
Walkie Talkie. The current user-selected chat binding was saved for restoration.
The requested headless sending/explorer design remains at fact finding and
interview stage; the new behavior is not implemented yet.

## Background chat workflow — 17 October 2026

Morgan confirmed the grilling design before implementation. Background submission
is now the default; it does not navigate Desktop or open Terminal. N creates only
when the reviewed first prompt is sent, in the bound chat's full working folder.
Repeat N picks the saved workspace/default folder. D continues to send to the
bound stable ID. The persisted “Open Chats in Terminal” menu option defaults
off; one-take folder-menu choices can also request CLI attachment.

A detached, same-user private socket broker holds the shared app-server RPC
subscription. It survives the Walkie UI exiting, retains native approval and
question callbacks, validates offered responses, and never fabricates approvals.
An unknown send/response is not retried. Crashed-worker state is an error rather
than authority to replay connection-scoped requests. Desktop-owned sends still
use owner-verified native IPC; historical resumption requires conclusive ownership
verification and uses the same shared daemon, never a private Desktop copy.

Quick access shows recent chats by activity, each with its recorded folder, and
previews only the last prompt and answer. Enter binds and closes; Command-Enter
opens and closes after success, using Desktop unless “Open Chats in Terminal”
is enabled. Errors remain inline. Opening leaves D's binding unchanged.
Message-body search is limited to the selected folder; global recent filtering
matches chat titles and folder labels. Guardian review
records are excluded by exact native metadata, including the older structured
subagent guardian source. Archived conversations stay hidden unless requested.
The cursor shows bound activity and total in-flight count, approval/question/error
states, and a brief successful-completion checkmark. It adds no unread markers
or notification popups; existing reply behavior is retained.

Native protocol evidence: a first background prompt completed once after its
submitting process exited. A second turn completed with the same exact turn ID
while a native remote CLI attached to that chat in a PTY. A real native command
approval (synthetic test-only untrusted/user/read-only policy) remained pending
for three seconds, with its temporary marker absent, then explicit approve-once
resumed and completed the exact turn. The native available-decisions list omitted
Decline; the broker honored that restriction. Test-only policies did not change
production defaults. Synthetic native probe chats were archived after verified
completion; their temporary marker and isolated broker were removed.

Desktop's current shared-writer retention remains a material limitation. A
completed thread stayed loaded for over 30 seconds after unsubscribe and remote
CLI exit. Open in Desktop therefore reports “still releasing” until safe unload
is verified. Active/awaiting-request background chats cannot open in Desktop.
No archive/unarchive, interruption or private duplicate is used to force release.
Active CLI attachment is allowed only when the shared background writer is verified.

Approval ownership is another native boundary. Walkie's request forms service
its background broker's live connection. Existing Desktop-owned chats retain
their approvals/questions in Desktop: the inspected IPC exposes owner discovery
and turn start/steer, but no supported pending-request subscription/response relay.
Walkie does not resume a private second copy to intercept those callbacks.

Swift regression evidence: 354 executed, 2 opt-in integration skips, zero failures.
The initial default-sandbox helper run could not bind Unix fixture sockets or
compile its Terminal dictionary fixture; the authoritative helper suite is run
with those local capabilities enabled. Packaged UI, UI-quit lifecycle and final
signature evidence are recorded separately below. No microphone or physical
shortcut check is implied by these protocol and unit results.

Final helper regression evidence: **140 tests passed**, zero failures/skips,
with local Unix fixture sockets and offline AppleScript compilation enabled.
A capability-enabled read-only native metadata scan paged 710 distinct active
records over eight pages, including 43 CLI records and 273 exact guardian records
that the helper excludes. The archive stream held 29 records and the synthetic
archived probe absent from the active stream. Folder-scoped search found two
synthetic prompt/answer hits for only that selected-folder probe. The archive
cursor carries only a phase and native opaque cursor, never titles/previews.

The release bundle was installed via the guarded idle-only restart, preserving
the current exact binding. Its existing Accessibility and Screen Recording
entries were refreshed in System Settings (same installed app, no additional
permissions and no TCC database edits). Relaunch reports trusted Accessibility,
a live event tap and screenCaptureAllowed=true; the local model warmed. The
signature verified after the Python worker started. Defaults report background
mode and automaticTerminal=false.

Installed native UI verification: the explorer showed 92 recorded-folder groups.
Selecting the disposable previous CLI folder and its third chat displayed the
exact synthetic user prompt and WT_REUSE_THIRD_OK answer, with distinct Bind,
Open in Desktop and Open in CLI controls. Native screenshot checked the complete
rendered layout; selecting and closing did not change D's binding or open another
app/chat. No physical shortcut, microphone or approval-form interaction is claimed.

A final offline edge case was corrected: SQLite `offset:` catalog cursors remain
SQLite-backed on subsequent pages, including Include Archived, even if the daemon
comes online between requests. A 106-record bridge regression covers this path;
the final capability-enabled helper suite passed 140 tests.

Installed end-to-end background evidence: three distinct synthetic chats each
contained exactly one user turn and its expected completed answer. No new remote
CLI processes appeared and none of the three IDs acquired a terminal sidecar.
The first completed immediately; the second executed a harmless timed Python
command. For the third, native turn 01a14aff-aced-71e2-85c9-a1cc0488496c remained
in progress while the old Walkie UI PID 63141 exited and replacement PID 65271
launched. Broker PID 64395 and that exact turn stayed unchanged; it then completed.
The third history had reasoning/final output and no command item, so this proves
model-turn lifetime across UI restart, not a separately observed shell-process
lifetime. The original user binding was restored. No approval was fabricated or
automatically answered during installed tests. Physical speech/shortcut and native
approval-form clicking remain separate manual checks.

The final offline-pagination helper patch was packaged with a second guarded
idle-only install. That invalidated the ad-hoc package's prior grants again;
only Walkie's existing Accessibility and Screen Recording entries were refreshed
while the UI was stopped. The final launch reports background mode,
automaticTerminal=false, screenCaptureAllowed=true and the original exact bound
chat. No user chat was interrupted by these restarts.

Final cleanup archived only the three exact installed synthetic test chats after
fresh idle/no-request verification. The production broker stayed alive and the
original binding was unchanged. Final relaunch logged Accessibility trusted=true,
eventTap=true and local model ready. `codesign --verify --deep --strict` passed
after the final Python model worker started; the installed helper matches source.


### 17 October 2026 — compact chat quick access correction

The large explorer is replaced by a 660 × 520 borderless menu-material palette.
It immediately displays cached recent chats, refreshes the newest activity page
without per-row ownership probes, and shows each chat’s recorded folder. The
preview contains only the last user prompt and its final answer in that turn.
Enter binds synchronously and closes. Command-Enter or the small Open accessory
uses Desktop unless “Open Chats in Terminal” is enabled; opening preserves D’s
binding. A successful open closes the palette, and a failed action stays inline.
Explicit Tab/Shift-Tab focus avoids macOS Full Keyboard Access filtering out
controls; focused actions support keyboard activation.

Unit/protocol validation: 360 Swift tests executed, two opt-in skips, zero
failures; 157 Python helper tests passed. Metadata-only production reads measured
0.101 s for the first 100 recent records and 0.064 s for the latest exchange.
Installed first-load/cached-list checks use the local API only to show/navigate
the palette; native accessibility inspection and keyboard events exercise its
actual controls. These checks do not establish physical shortcut or microphone
parity.

Installed native evidence from the 20:27 build: Return bound an exact disposable
chat and dismissed the palette. Command-Return dismissed it after opening that
chat in Desktop, whose owner IPC then confirmed the exact ID idle and owned.
With the Terminal preference enabled, the same action opened an earlier
disposable CLI chat; the installed bridge verified its exact child PID, parent
host, TTY, and resume ID, and the palette closed. Desktop was restored as the
default, and opening did not change the saved binding. The guarded finish helper
closed only the later verified single-tab test view. A separate test view whose
sidecar retired after keyboard input was preserved, not guessed from its argv.

Native release evidence: unsubscribe retains an idle shared writer for about
60.14 s. Successful background turns now queue a separate release worker, which
rechecks the exact turn, native idle state, and pending requests before releasing
its own subscription. The worker advertises idle-release-v1. A real synthetic
installed prompt completed with subscribed=false and releaseState=waiting. Open
displayed progress during the grace period; Escape closed the palette. After
native unloading, owner discovery confirmed the cancelled target still had no
Desktop owner. Both new disposable chats were archived through the legitimate
app tool. No archive/unarchive cycle or private writer was used for handoff.

Release-progress polling reads loaded/list outside the broker mutation lock;
only thread_release_pending retries, and cancellation is checked before launching
an app. Busy work still fails safely without interruption. The old background
worker was refreshed only with the UI stopped, no pending callbacks, and every
tracked native chat conclusively idle/notLoaded.

Final installed 20:43 build, renewed-grant launch 20:50: native Tab moved from
search to the folder filter, Archived, list/preview, and compact Open action;
Shift-Tab returned to the preview. Command-F and Down selected the second
disposable row and updated its last prompt/answer. Return bound that exact
second ID and dismissed the palette. The previously saved binding was restored
and verified. Startup reports Accessibility trusted=true/eventTap=true, Screen
Recording allowed, and the local model ready; deep strict signature verification
passed after the Python workers started. Desktop/background remains the default.
These are native accessibility and synthetic-key checks, not a claim that the
physical global shortcut or microphone gesture was tested in this correction.


### 17 October 2026 — old-chat open latency and release verification

Desktop open first reads the exact native thread ID/status and checks its
pending requests and in-progress turn. A conclusively notLoaded, inactive chat
with no subscribed/unknown background writer opens without waiting for a negative
Desktop-owner discovery result. A remembered idle/unsubscribed row’s stale
ownerState=unknown does not override fresh native notLoaded proof. Existing
Desktop ownership routing and all send/CLI ownership boundaries remain strict.
Exact active background chats and pending callbacks are refused before any URL
open or unsubscribe; unrelated background activity does not block an old chat.

The same disposable unloaded ID measured 10.118 s on the prior installed helper
and 0.072 s on the corrected source. Installed 21:11 release: native
Command-Return dismissed the palette within the 0.534 s key/AX tool call. Exact
Desktop owner IPC then confirmed that ID idle/owned; the saved binding remained
unchanged. Swift suite: 360 executed, two opt-in skips, zero failures. Python
helper suite: 162 passed. New regressions cover the no-owner-probe path, native ID
validation/guardian exclusion, active/pending/subscribed/unknown vetoes, and the
remembered-but-already-unloaded background case.

The footer starts with ordinary Opening progress. Only the backend’s exact
thread_release_pending result enables the release notice. Dismissal/selection
cancellation gates both progress and the eventual app launch. In the installed
active-chat check, Command-Return returned the working/interruption-protection
message in the 0.482 s key/AX call with no release notice.

Native verification did not justify bypassing real writer retention. A direct
URL on an idle but still-loaded test returned in 58.8 ms, but Desktop logged
thread_resume_failed: already has an active writer, and no owner appeared. The
active direct-open test similarly failed to load Desktop while the exact original
25-second command/model turn completed once, unmodified. Once unloaded, reopening
the same idle ID succeeded; owner IPC and targeted
thread-follower-load-complete-history v1 succeeded after 2.08 s. Evidence is
under /private/tmp/walkie-direct-open-probe-20261017.

Separate isolated native tests found thread_unload_delay_secs=0 removes this
retention when supplied at server startup. Per-thread start/resume overrides and
a runtime config write did not change it. The managed daemon drops CLI -c
overrides, but an isolated CODEX_HOME config.toml zero setting unloaded within
0.106 s. An isolated active model turn remained active after unsubscribe and
completed before unloading; tool/approval/full-disconnect cases were not tested
under zero delay. This is a Codex-wide startup setting, not a Walkie-only option.
Morgan requested an explanation before approving that wider change: production
config and shared daemon were left unchanged. No running work was restarted.

Installed 21:11 build, renewed-grant launch 21:13: an exact synthetic background
turn was confirmed active before Command-Return. The picker refused opening
quickly without a release notice; the same turn continued its 25-second command
and completed once with the expected final marker. Retrying only after completion
showed Waiting for Codex to release this chat, based on actual loaded-writer
retention; Escape dismissed it. The source helper matches the installed bundle,
the saved binding is unchanged, Accessibility/event tap and Screen Recording
verify, and deep strict signature verification passed after model-worker startup.
The shared broker remained alive; no shared daemon/config restart occurred.


### 17 October 2026 — immediate Desktop history viewing

The prior Desktop preflight conflated acquiring a second writer with displaying
stored history. Installed Desktop 26.1013.31256 / 20586 has an explicit
active-writer-conflict path: paginated history is hydrated after resume refusal,
the transcript remains rendered, and the composer is hidden behind “This is open
in another app / Close it there to continue here.” Passive source excerpts are
in /private/tmp/walkie-passive-desktop-source/evidence-excerpts.txt. Older-history
pagination and live updates while in this snapshot state remain separate gaps.

Native seeded test: first answer READONLY_HISTORY_SEED_VISIBLE completed. While
its second exact turn ran a 60-second harmless command elsewhere, the ordinary
Desktop URL was opened once. Logs showed writer-resume refusal followed by
successful thread/turns/list and thread/items/list. Morgan explicitly confirmed
the seed answer was visible in the actual Desktop conversation. The original
second turn completed once, its command ran 59.882 seconds with exit 0, and it
returned READONLY_RUN_COMPLETED. Evidence is under
/private/tmp/walkie-seeded-readonly-history-20261017. Computer Use explicitly
blocks inspecting com.openai.codex, so visual proof here is Morgan’s observation,
not a synthetic screenshot, private DOM access, or a backend-owner inference.

Normal Desktop Open now bypasses the writer preflight entirely and sends only
the chat URL. The 90-second poll, release callback, and release footer were
removed from the Swift opening flow. Opening does not unsubscribe, interrupt,
steer, resume through Walkie, change bindings, or alter Codex configuration.
Desktop handles its own writer conflict and read-only rendering. CLI attachment
still runs exact-owner preflight and rejects mismatched identities/refusals.

Installed release verification: Command-Return on the seeded chat dismissed the
picker in the 0.419-second native key/AX call; its API state then confirmed
open=false and checking=false, with the existing binding unchanged. Desktop
logged a successful exact-ID resume and history reads (three completed turns).
This installed shortcut check occurred after natural writer unload; the separate
running-turn/read-only evidence above verifies concurrent viewing. The final
synthetic 20-second command also completed once with exit 0 before that opening.
Swift suite: 362 executed, two opt-in skips, zero failures. Launch at 21:34 had
Accessibility trusted/event tap enabled, Screen Recording available, and model
ready; deep strict signature verification passed after worker startup. Existing
permission entries were refreshed, the background broker stayed alive, and
Codex's global configuration and shared daemon were unchanged.
