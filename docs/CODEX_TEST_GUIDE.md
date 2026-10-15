# Codex fork manual test guide

This is a hands-on checklist for the current fork. A listed step is a procedure,
not evidence that it has passed. Record the app build, macOS version, model, and
result next to each run. Use a disposable Codex chat/project for anything that
could deliver a prompt. The routes below can open UI or send data; do not aim
them at a real work chat without checking the selected target first.

For everyday keyboard and mouse controls, see [GESTURES.md](GESTURES.md).

## Before a run

1. For a debug build, run `./tools/swift-build.sh build`. This succeeds with the
   official Swift 6.2.3 toolchain cached under the user Library cache and a
   compiler workaround; it does not change system Command Line Tools. Release
   packaging and the Swift suite passes (279 executed, 2 opt-in skips, 0 failures). Launch an already
   installed app with `open "/Applications/Walkie Talkie.app"` only when that
   is the build under test. Complete Accessibility, Microphone, and Screen
   Recording permission prompts.
2. Confirm that the intended Codex CLI is installed and signed in. For local
   transcription, confirm the selected Python can import `mlx_whisper` and the
   selected model is cached. Do not stop or reconfigure a separate MLX service
   such as Quiet Journal to run these checks.
3. Find the app's loopback port and set `BASE` to the first responding port:

   ```sh
   for p in 8917 8918 8919; do
     if curl -fsS "http://127.0.0.1:$p/up"; then
       export BASE="http://127.0.0.1:$p"
       break
     fi
   done
   test -n "$BASE" || echo "Walkie Talkie loopback listener not found"
   curl -fsS "$BASE/target"
   curl -fsS "$BASE/engine"
   curl -fsS "$BASE/test/state"
   ```

   `/up`, `/target`, `/engine`, and `/test/state` are useful checks. Other
   `/test/*` routes can change UI or state. Consult their descriptions in
   `Sources/WalkieTalkie/ElementPicker.swift` before invoking unfamiliar routes.

Current evidence: all **67 Python tests** and **277 Swift tests** pass (279 executed, 2 opt-in skips, 0 failures). The release
app builds, installs, launches, and loads both local transcription workers; its
local API and installed Codex helper discovery respond. Its signature remains
valid after model startup. Native CLI tests passed first-prompt exactly-once
delivery, follow-up text, synthetic red-image input, and same-turn steering.
A user-authorized disposable desktop chat also passed text, red-image input,
and steering the same active turn. The installed Swift app passed bind, hold,
edit, send, and cancel checks using synthetic transcripts; cancellation created
no delivery or new chat turn. Desktop IPC is internal and version-coupled;
tested Desktop version: 26.1007.30912, native CLI: 0.162.0-alpha.17.2.
The CLI finish helper has 12 mocked tests and a safe dry-run; no real tab close
has been tested. Desktop completion archived only the disposable chat and the
test restored it afterward. Archiving interrupts the active turn, so provide
the result before the archive action; a final answer after archive is lost.
A real user-spoken prompt also passed ⌃⌘D start/stop and desktop delivery with
the expected `banana` reply. Installed-app English/French quick-answer stages, source handlers, reply
authentication/images, resize, cancel/queue restoration, and synthetic captions
also passed. Visual/pointer interaction remains a separate manual check.

### macOS permissions and stopping a recording

- **System Settings → Privacy & Security → Microphone → Walkie Talkie: on**
  permits audio capture. Local MLX transcription does not require enabling
  Apple's keyboard Dictation.
- **Accessibility → Walkie Talkie: on** permits global shortcuts, mouse
  gestures, and caret/context access. Start and stop a prompt with the same
  shortcut: **Control + Command + D (⌃⌘D)**. The menu's Start/Stop Dictation
  action is an alternative. A missing event tap prevents the global shortcut
  even when recording from the menu works.
- **Screen & System Audio Recording → Walkie Talkie: on** permits screen,
  crop, and film capture. Restart the app when macOS requests it.
- **Automation → Walkie Talkie → Terminal: on**, if macOS requests it, permits
  launching and managing a Terminal tab. Browser automation is needed only for
  the relevant browser actions. Allow individual prompts when using those
  features; these rows may not exist before the first request.

If Accessibility looks enabled but shortcuts remain dead, compare the running
process's startup `accessibility trusted` log and the harmless event-tap canary:
`POST /test/firewall {}` should report `alive:true`. A Settings checkbox alone
does not establish that the process is trusted. Ad-hoc builds can invalidate a
previous grant. After the final app has been installed, quit it, remove the old
Walkie Talkie entry with the minus button, add **/Applications/Walkie Talkie.app**
with the plus button, enable it, and reopen it. Use the actual installed bundle;
do not add a build-directory executable. If it still reports untrusted, record
that result and leave physical tests pending. Never edit the macOS TCC database.

On the preceding keyboard/language build, the fresh Accessibility entry
resolved its stale grant: startup reported `trusted=true eventTap=true`, and
the harmless canary reports `alive:true`. This verifies event-tap access; the
real spoken start/stop/send test also passed: the user bound the disposable
chat, pressed ⌃⌘D to start and stop, and Codex replied `banana`. App delivery
metadata independently matched `local-whisper` and the exact selected chat.

## Codex binding and chat selection

- Open the menu and choose **Bind Codex chat…**. Verify chat titles and project
  paths load, search matches both title and project, the project filter narrows
  the list, Refresh reloads it, and selecting/double-clicking a live row binds the
  intended chat. Confirm saved rows are labelled and cannot be bound until
  opened in Codex. Select a live CLI row and confirm its Terminal identity is
  retained when using the reply bubble’s bring-forward action. Confirm the selected target with `GET /target`.
- Switch among projects and bind a second disposable chat. Confirm that the
  picker does not confuse a chat with another open chat or rely on frontmost
  window focus. Use **Disconnect** and confirm `/target` reports no target.
- Re-open **Rebind to…** after sending a test prompt and verify recent targets
  can be selected. Search for a phrase from a disposable Codex session; verify
  matching user and Codex turns, project/title context, live-session binding,
  and closed-session resume. The helper reads the Codex local metadata/history
  SQLite stores read-only. Verify app restart/relaunch behavior separately; do
  not infer persistence from a single in-process rebind.
- Test the Codex CLI binding and picker independently from Codex desktop. The
  desktop bridge has a same-user native IPC adapter with owner discovery, but
  text, images, and active-turn steering have passed in a disposable desktop
  chat. Repeat with a harmless marker and confirm it reaches the intended chat
  exactly once. Treat this internal, version-coupled IPC as a compatibility risk;
  ownership discovery alone does not establish delivery after an app update.
- Run **Prompt to new** against a disposable folder and verify the expected
  Codex CLI process opens with the initial prompt. The `walkie-codex` launcher
  starts the shared daemon idempotently, creates or resumes the exact
  conversation, persists the initial prompt once over RPC, and records its tty
  sidecar before attaching the CLI TUI. A new launch without an initial prompt is
  deliberately rejected; `--resume` attaches to an existing exact conversation.
  Test resume only with a disposable Codex session. In **Rebind to…**, verify
  closed sessions reopen in their recorded project folder and a live session
  binds to its tty.
- Open a saved desktop chat in Codex before binding it, then refresh the picker.
  A saved metadata row is not proof the desktop owns it live; sending to a chat
  with no live owner should fail clearly rather than open a second private copy.
- For CLI bridge evidence, a native PTY smoke has already confirmed first-prompt
  exactly-once delivery, a direct follow-up, reading a synthetic red image, and
  steering an active turn without changing its turn ID. These protocol results
  do not verify app-picker/UI behavior. Desktop bridge delivery was tested
  separately as described above. Repeat UI steps
  only with a disposable Codex CLI conversation.
- `POST /test/spawn` enters the new-session prompt flow with supplied text;
  `POST /test/spawn-folders` opens the folder chooser; `POST /test/spawn-pick`
  selects an explicit tty. These are UI test hooks, not proof of successful
  Codex CLI launch. Use `/test/rebind-panel` only to inspect the legacy panel.

## Prompt delivery, quick answers, and reply UI

- On a disposable Codex destination, use `POST /test/dictation` with a harmless
  sentence to exercise prompt assembly and the hold/review flow without a
  microphone. Verify the displayed text and attachments, then explicitly send
  and check the destination. Cancel in a second run and check it was not
  delivered. Never use this route with an actual work target for a smoke test.
- Check the quick-answer panel from the app and with
  `POST /test/quick {"text":"What is 2 + 2?","wait":"all"}`. Use
  `"wait":true` to measure just the first answer. Exercise the question,
  web-check, and adversarial-review stages; check that web citations
  become source links and a changed answer is visibly distinguished. Test
  question-language output with at least two languages. During each stage test
  the panel close button and the cancel gesture; confirm the active work stops
  and the warm worker is available for a later question.
  Installed-app runs passed all three stages: English first words at 2.30 s
  and all stages at 13.16 s; French first words at 3.67 s and all stages at
  16.06 s. Closing an in-flight question restored a queued reply, and a later
  question completed. These observations do not prove pointer/gesture behavior.
- Use `POST /test/quick` UI options only after reading the handler: it can
  resize/close the panel, mark it capturable, and simulate a source-link click.
  For a link test use `{"link":{"index":0,"click":true,"open":false}}` to
  avoid opening a browser. Verify the link label, hover URL, quote fragment, and
  that no raw citation markers leak into the answer.
- `walkie-reply "Short answer"` posts a response to the running app. In Codex,
  allow the helper to connect to its localhost listener (request sandbox
  escalation if needed). A denied connection may be tried once after permission;
  an unknown delivery or timeout must not be automatically retried. The bubble
  stays until its top-right **×** is clicked; later replies queue. `--image`
  can be repeated to attach image files, and `CODEX_THREAD_ID` associates it with
  the originating Codex chat. A reply test can be posted to `/reply` only with
  the app's valid reply token; don’t invent one. Test text and image replies,
  thumbnails, opening/keeping/copying an image, pinning, and reply-back to the
  originating context. Confirm the panel does not steal focus unexpectedly and
  temporary files remain available when kept. The installed helper passed
  token rejection, text/image delivery, persistent image copy, source links
  through resize, and queued reply restoration. It stages images under
  `~/Library/Caches/local.walkie-talkie/reply-staging` because direct native
  reads from protected project folders can block. Confirmed delivery removes
  staging; an unknown outcome retains it and stops without retrying. Check
  the bubble before retrying or clearing retained staging. Prefer the helper
  for image callbacks. Reply-back, pin, image opening, and visual layout still
  need real UI checks.

### Kamikaze and finish behavior

- On a disposable CLI prompt, test the `kamikaze` ending cue and inspect the
  assembled prompt for the completion instructions. In a Walkie-launched CLI,
  `walkie-finish --dry-run` verifies the current thread's sidecar, native Codex
  PID/TTY command, unique Terminal tab, and controlling root/login PID plus start
  time without waiting, signaling, or closing anything.
- If a turn is active, a bare `walkie-finish` should return after scheduling a
  detached watcher for the database's active exact turn; only after it becomes
  idle may the watcher signal that verified CLI TUI and close its one verified
  Terminal tab. If the tab owner changes or cannot be established, it must leave
  the tab open. A real close has not been tested; use only an explicitly approved
  disposable CLI session for any manual close test. Never use this helper on a
  Codex Desktop chat or to close an app/window.
- In a desktop-chat prompt, the completion cue uses the receiving model's own
  `set_thread_archived` tool after the task. The helper cannot close an exact
  desktop-owned window. The desktop send path passed disposable-chat tests.
  Completion archive passed on the disposable chat. Archiving interrupts the
  active turn, so the result must be given before the archive tool action.
  Restore the test chat afterward if you want to reuse it.

## Local MLX, cloud fallback, captions, and microphone

- In **Engine**, select each available local model and verify the checked model
  matches the chip/menu label. The default model is multilingual; test an
  English sample and a non-English sample without setting a language override.
- Record a short sentence, stop it, and time cold startup, warm readiness, and
  warm decode separately. Repeat with the same bundled/public WAV using
  `POST /test/local-fallback {"wav":"/absolute/path/to/public.wav"}`; it
  transcribes without delivering a prompt. Keep the sample path, model, warm or
  cold state, and elapsed time with the result. Compare the first transcription
  after app launch with a later warmed decode; avoid treating one machine's
  timing as a universal threshold.
  Cached-model warm-up measured 5.12 s. The installed app decoded the public
  11 s OpenAI Whisper JFK sample in 2.56 s from its cache without word timings;
  forced word timings took 5.31 s and returned 22 words. Copy public test WAVs
  into the app cache before this route; protected Documents-folder metadata
  access caused an unrelated delay. These are observations, not thresholds.
- The Python interpreter is discovered by checking for `mlx_whisper`. Test
  `RELAY_WHISPER_PYTHON` only with an interpreter already set up for MLX;
  `RELAY_WHISPER_MODEL` chooses model id/path; `RELAY_WHISPER_CACHE` points at
  an existing cache if needed. Verify `ffmpeg` is found by the child process.
  `POST /test/whisper` offers controlled kill/stop/continue/restart/model test
  hooks; do not signal a separate journal process.
  Quiet Journal's runtime and on-disk cache can be discovered dynamically. Cache
  files are shared, not the in-memory model: Walkie Talkie uses a separate worker
  and can duplicate model memory (about 1.54 GB active state plus a 512 MB decode
  cache observed on the development Mac). The default has no language allowlist;
  its vocabulary includes Codex and `AGENTS.md` terms. Test different languages
  without assuming one language is preferred.
- Enable **Live captions (local)** in Engine, select local Whisper, and speak a
  short phrase. Verify interim caption updates and that final transcription can
  finish even if a caption decode is still in flight. `POST /test/live-caption`
  tests the caption band presentation with synthetic text; it does not test
  actual MLX live decoding. Disable captions and confirm the band closes.
- Select ElevenLabs (or the other cloud row available in Engine), dictate a
  short sample, then exercise **Transcribe Locally Now** (⌘⌃X) and the automatic
  local-fallback setting. Verify which transcript wins if cloud and local
  results race. `POST /test/eleven` can inject cloud failures; keep credentials
  out of logs and test notes.
- Switch microphones from the **Mic** menu and confirm the selected input in the
  menu and through a real recording. Compare against `POST /test/mic` and
  `/test/input` state changes, which select devices but do not prove the
  microphone's recorded sound. Test unplug/reconnect behavior with an available
  device.
- Wispr is shown in Engine according to the current menu switch and may also be
  picked through the engine route. Validate its own transcription and delivery
  separately before relying on it. A raw Wispr chord gesture is not evidence
  that every engine menu / history / delivery path works.

## Screenshots, crop, selection, browser, and music

- If opening context capture is enabled, start a prompt and verify its screenshot
  and pointer marker. Test the explicit shutter independently below.
  Use **⌃⌘S** for another shot without opening the menu. The optional
  **Take Screenshot** row is clickable during prompt recording. Confirm original and
  resized files, labels, prompt references, and shot times.
- During a dictation, hold the wheel and drag a region. Check the crop image and
  selection outline. Hold ⌘ while moving to reposition; hold ⌥ to draw from the
  center; Esc should cancel. `POST /test/area` exercises file/crop assembly with
  `{x,y,w,h}` and optionally a `to` rectangle; it does not prove event-tap drag
  handling.
- Select text in a supported app while dictating. Verify it is read through
  Accessibility and appears at the appropriate transcript offset. Use
  `POST /test/selection {"text":"sample selection"}` to exercise attachment
  formatting. Check that the user's clipboard value is unchanged.
- Load the unpacked extension in Chrome or Microsoft Edge (Developer mode →
  Load unpacked → `chrome-extension/`). During a prompt hold ⌘⇧ over an element
  for about half a second; verify the highlight, click-to-add text/URL/selector,
  and drag-to-describe a move. Confirm a quick ⌘⇧ click still behaves like a
  normal browser click. Try a normal link and a text selection.
- Play audio in more than one browser tab. Start and stop dictation; verify only
  tabs that were playing are paused and then restored. Extension, DOM selection,
  and music behavior each require a real browser pass; the loopback `/pick` or
  `/chrome/reload` route alone is not evidence of browser integration.
- Start **Record Screen** during a prompt, stop it, and verify the film marker,
  frame files, and contact-sheet image in the prompt. Try a second recording,
  a short run, and a run where frames may be dropped. Confirm each film has its
  own sheet and that cancel/recover does not accidentally attach a stale film.

## Hold, edit, autosend, cancel, and recover

- Send a long and a short synthetic transcript through `POST /test/dictation`.
  Verify the hold countdown scales, the prompt remains visible, Send delivers
  once, and Cancel delivers nothing. Click into the text and edit it; the
  countdown should pause while editing. Press Return to send immediately.
- Toggle **Autosend** in the menu and verify the checkbox, persisted state after
  relaunch, and the pointer-over-panel pause behavior. `POST /test/autosend
  {"on":true}` can set the test state. Exercise `/test/prompt` with `send`,
  `cancel`, and `edit` only in a test session.
- Cancel a real local recording and use **Recover Cancelled Dictation**. Verify
  the recovered WAV belongs to that take, is transcribed once, and does not
  silently reattach a cancelled recording's old images. `POST /test/recover` drives the
  menu action; inspect `/test/state` before and after.
- Repeat cancel/recover while transcription is pending, while a film is open,
  while a prompt is held, and while the selected target has changed. Normal
  dictation delivery latches its destination when recording stops. Recovery
  deliberately uses the destination selected at recovery time; verify both.

## Hotkeys, gestures, caret, and clipboard

- Read the current **Gestures** menu rather than relying on a stale key table.
  Test ⌘⌃B bind/unbind, ⌘⌃D prompt start/stop, ⌘⌃X local-now, prompt-at-caret,
  new-session, cancel, screenshot, Return, and plain dictation. Also test the
  selected Logi or Wheel mode as configured.
- In a text editor, run a plain dictation and verify words are inserted at the
  caret without Return; use the other plain mode to confirm it ends with Return.
  Compare with prompt-at-caret, which carries context: a verified Codex CLI
  prompt is sent directly to its stable ID with actual image inputs; a generic
  field receives paste without Return. Use only a disposable CLI for this check.
  Close that TUI and confirm a shell is never auto-submitted. Test a verified
  VS Code terminal separately from its editor. An attempted RPC error must show
  an acknowledgement warning and preserve the clipboard without fallback paste
  or retry. Verify caret contents survive menu interaction.
- Record a clipboard sentinel, dictate and deliver, then paste. Check the
  finished prompt envelope (or clean dictation words) is now on the clipboard
  for re-pasting. Separately verify selection capture alone preserves the
  sentinel. Avoid pasting into a shell prompt.
- `POST /test/gesture {"name":"forward-right"}` exercises mapped chord
  handling; `{"name":"forward-right","direct":true}` calls a gesture
  handler directly. Check `GET /test/state` and optionally enable
  `POST /test/key-trace {"on":true}`. These hooks do not replace testing the
  physical mouse and keyboard event tap.

## Restart, login, settings, and outbox

- With a disposable bound chat and an idle app, run `./relay-restart.sh --build`.
  Verify build completion, relaunch, and target restoration behavior. Do not
  replace the app bundle under an active recording/transcription. Record build
  logs and whether the Codex target remains bound.
- In **System Settings → General → Login Items**, inspect whether the app is
  configured to start at login. Log out/restart only in a planned test session;
  verify permission grants and model warm-up after relaunch. Do not assume
  login-item status from the app menu.
- Change Engine, model, microphone, gesture mode, autosend, and local caption
  preferences. Restart and verify which settings persist. Use `GET /engine`,
  `GET /target`, and `/test/state` to inspect current state.
- Check `~/.walkie-talkie/outbox.jsonl` after a successful delivery. It should
  contain one delivered event with the expected target/session and attachments;
  a cancelled hold should not appear as a delivered dictation. Treat the log and
  outbox as private user data; redact them before attaching diagnostics.
- Transcribed recordings are retained as WAV plus transcript under
  `~/.walkie-talkie/voice-corpus` whether or not they were delivered. Cancelled
  takes are staged for five minutes for recovery; a cancelled take can enter the
  corpus if recovered and transcribed. Check with a harmless synthetic take and
  confirm the outbox still records delivered prompts only. Do not use private
  journal audio as a fixture; none was used in this fork's tests.
- `helpers/corpus_report.py` is optional and is not installed, scheduled, or
  used to send any report. Its default invocation previews locally. Sending
  requires `--send` and `AGENTMAIL_API_KEY`, `CORPUS_REPORT_TO`, and
  `CORPUS_REPORT_INBOX` in the environment or `~/.walkie-talkie/report.env`.
  Two tests verify preview never sends and missing destinations prevent network
  calls. The optional Claude-specific VM/night development harnesses are described
  in `tools/README.md`; they are not installed and are not app features.

## Evidence to record

For each row in `CODEX_PARITY.md`, record one of: **verified** (with build,
date, and evidence), **failed** (with a minimal reproduction and log excerpt
redacted of private data), **not run**, or **not applicable**. Automated route
success is evidence for the route's layer only; mark end-to-end interaction as
verified only after checking the visible UI or destination.

## Keyboard screenshot and recognition language

- In a disposable bound chat, open example.com in the browser. Press ⌃⌘D,
  speak a short English question, point at the heading, press ⌃⌘S, then ⌃⌘D.
  Confirm a thumbnail/count appeared and the final prompt has an actual image.
  Review and send with Return; verify Codex identifies the heading. A shutter
  flash without a saved image is a failure. Check `screenCaptureAllowed` in
  `/test/state`; a false value requires the installed app's Screen Recording
  permission to be refreshed. Test ⌃⌘S in both Logi and Wheel modes and
  verify holding the key does not add repeated captures. No Options+ is
  required for these keyboard controls.
- While idle, choose **Engine → Local language → English**. Dictate the same
  short English sentence and verify both captions and final transcript remain
  English. Repeat with French selected and a French sentence, then restore
  **Automatic** and check persistence after relaunch. Automatic remains the
  default; explicit choices bypass language guessing and do not reload the
  model. This setting affects local recognition, including local fallback,
  rather than optional cloud providers. The choice is disabled while recording.
- With a configured Logitech mouse, follow the full mapping in GESTURES.md.
  Verify front+right starts a bound prompt, rear click captures, front click
  stops, and front+right during recording switches destination. Confirm the
  destination in the overlay before sending. Wheel-only crop/move needs a
  physical pressable wheel; trackpad drag is not an implemented substitute.

## Effects, reference panel, history, and sound

- Record the current **𝓯𝔁** choices. Try an available style for caret, bound,
  and new-session destinations; start a harmless recording for each. Verify
  the selected effect follows the pointer and reacts to the microphone. Check
  unavailable styles explain why they are disabled. Select each available
  effect engine, voice option, and filter, check persistence after relaunch,
  then restore the original choices. Use the F7/F9 preview controls independently.
- Open the **Built/Version** row near Quit. Verify About has a visible size,
  current build stamp, Codex wording, keyboard reference, the current Logi/Wheel
  gesture table, and a source link to Morgan's fork. Close the panel.
- After harmless delivered test prompts, open **Prompt History**. Check recent
  spoken snippets, newest first, and hover text. Choosing one should copy its
  envelope to the clipboard; paste it into a safe editor to inspect it. Open
  **Full Log**, inspect the last two days of delivered records, and check its
  Copy control and attachment references. A cancelled, unsent take must not
  appear as a delivered event. Test an empty history with a separate fixture
  rather than deleting personal history.
- Focus a safe text editor and choose **Paste last prompt**. Confirm exactly one
  paste and compare the envelope with the latest prompt; repeat after plain
  dictation, which should paste clean words. Avoid testing this in a shell.
- Record the current **Radio squelch** setting. Turn it on: it should play once
  on enabling and when the microphone opens. Turn it off and start another
  harmless recording; check persistence after relaunch, then restore the setting.

## Latest observed results

Real ⌃⌘D speech, English captions/transcript, ⌃⌘S image delivery, automatic
question reply bubble, Edge picker outline/receipt, fixture media pause/resume,
and two film/contact-sheet deliveries passed on 15 October 2026. The first film
contained 14 frames over 2.7 seconds; the second contained 42 frames over 8.3
seconds and included captured synthetic text selections. Both reached the exact
disposable chat as actual image inputs and were described correctly.

A production Codex caret dispatch also passed in an isolated native CLI PTY with
an actual red image. This verifies target resolution and RPC dispatch, while
physical Terminal/VS Code focus and mouse gestures remain manual. Full Swift
checks executed 279 cases with 2 opt-in integration skips and no failures;
those opt-in checks passed separately in the disposable PTY. All 67 Python tests
passed. Optional cloud/Wispr providers, other microphones, real CLI tab closing,
wheel crops/moves, DOM dragging/iframes, and remaining pointer controls have not
been claimed as passed.

The final 12:32 release starts both local workers and preserves English, but
its ad-hoc signature requires renewed Accessibility and Screen Recording grants
before physical shortcuts/capture can be used. About now publishes its 12 real
gesture rows, confirmed through the installed panel. Select the intended chat
again after relaunch; binding currently clears on restart.
