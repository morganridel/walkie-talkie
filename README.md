# Walkie Talkie — Codex fork

Walkie Talkie is a macOS voice-and-context companion for coding chats. It can
transcribe speech locally with MLX Whisper or through an optional cloud engine,
then assemble words, screenshots, selected text, and browser picks into a prompt.
Prompts are held for review before delivery. The app also has a quick-answer
panel for spoken questions.

This is Morgan's Codex-focused adaptation of [Victor Rentea's upstream
Walkie Talkie project](https://github.com/victorrentea/walkie-talkie). It keeps
the original project's voice-and-context companion idea and credits Victor as
the upstream author; the Codex integrations, workflows, and other fork-specific
changes are maintained here.

## Requirements

- A Mac with Apple Silicon for MLX Whisper.
- Xcode Command Line Tools and Swift Package Manager.
- A Swift toolchain that can load the package manifest. If the installed
  Command Line Tools are mismatched, `tools/bootstrap-swift.sh` prepares the
  official Swift 6.2.3 toolchain locally without changing the system selection.
- Python 3, `ffmpeg`, and `mlx-whisper` in a Python environment on the machine.
- Codex CLI installed and signed in for Codex chat binding, quick answers, and
  other Codex-backed features.
- The native dependencies already checked into this repository (see `Package.swift`).
- Optional: ElevenLabs credentials for cloud transcription; Chrome or Microsoft Edge and the
  unpacked extension for picking page elements.

## Build and launch

```bash
./tools/swift-build.sh build
./tools/swift-build.sh test
./build-app.sh
open "/Applications/Walkie Talkie.app"
```

On a new checkout, if the system Swift toolchain cannot load `Package.swift`, run
`./tools/bootstrap-swift.sh` once before building. It downloads and verifies the
official Swift package, then extracts it under `~/Library/Caches/WalkieTalkie/Swift6.2.3`;
it does not install Swift system-wide or change `xcode-select`. To use another
compatible toolchain, set `WALKIE_SWIFT` to its `swift` executable. If the installed
Command Line Tools omit XCTest, `tools/swift-build.sh test` downloads the matching
open-source XCTest package into the same user cache and runs the XCTest suite.
The debug application build succeeds with the cached Swift 6.2.3 toolchain and
compiler workaround; system Command Line Tools remain unchanged. The full Swift
suite executes 354 tests with 2 opt-in integration skips and no failures (352 passed). The release bundle builds, installs, launches, and loads
the local model successfully. The installed helper discovers the native Codex CLI.
The local signing certificate is unavailable, so macOS may ask for permissions
again after a rebuild. Desktop text, image input, and same-turn steering passed in a disposable chat.
Real keyboard voice, screenshot, film, automatic reply bubble, and Edge picker/media checks also passed. Physical mouse controls and remaining UI features need the manual checks below.

Allow the requested **Accessibility**, **Microphone**, and **Screen Recording**
permissions in macOS. Launch the `.app` through Finder or `open` so macOS keeps
the app identity associated with its permission grants.

The app discovers a Python interpreter that can import `mlx_whisper`. To select
one explicitly, set `RELAY_WHISPER_PYTHON` in the launch environment. The default
model is multilingual `mlx-community/whisper-large-v3-turbo`; set
`RELAY_WHISPER_MODEL` to choose another supported repo or local model directory.
`RELAY_WHISPER_CACHE` can point at an existing Hugging Face/MLX model cache. The
Quiet Journal runtime and on-disk model cache can be discovered automatically
when present; set the variables above to select them explicitly. This reuses
files, not Quiet Journal's in-memory model: Walkie Talkie runs its own worker, so
both processes can hold model memory at once. The measured worker used about
1.54 GB of active model memory and a 512 MB decode cache. Live captions keep an
additional Walkie Talkie worker warm; disable them in Engine to reduce memory.
No language is pinned
or limited by default, and the default vocabulary includes Codex and `AGENTS.md`
terms. A cached-model run took 5.12 s to warm. The installed app decoded an 11 s
public Whisper test sample in 2.56 s without word timings, or 5.31 s with
word timings. Timings vary by hardware, cache state, and requested alignment.

Codex CLI discovery checks `CODEX_BIN` and known app-bundled CLI locations. If
needed, set `CODEX_BIN` to the native Codex executable in the environment used
to launch the app. The `walkie-codex` launcher starts the shared app-server
daemon idempotently, creates or resumes the selected conversation, and records
its terminal mapping. The Codex CLI must already be authenticated. Do not put
API keys in source files.

A native CLI PTY smoke test verified the initial prompt appeared once, a follow-up
sent directly, a synthetic red image was interpreted as red, and a follow-up
while Codex was busy steered the same turn ID and completed with its expected
marker. The test chat was archived and its CLI exited successfully. This verifies
the CLI bridge; desktop and packaged-app evidence is described separately below.

Codex desktop integration uses a same-user IPC adapter that preserves the
desktop protocol version and verifies thread ownership. This is an internal,
version-coupled interface. A disposable desktop chat passed text delivery,
synthetic red-image interpretation, and steering the same active turn. The
installed app also passed bind, hold, edit, send, and cancel checks using a
synthetic transcript; this does not verify microphone gestures or rendered UI.
Desktop steering includes the native composer record and text-element arrays
required by the tested desktop version (26.1007.30912). Quick-answer timing
measured 2.30 s to the first answer and 13.16 s for all three installed-app
stages in English; French measured 3.67 s to first words and 16.06 s for all
stages. Source links survived resize and queued-reply restoration after cancel.
These are observations from individual runs, not performance guarantees.

The installed `walkie-reply` helper supports text and image callbacks tied to
the exact Codex chat. It uses a private temporary file inbox with authenticated
delivery receipts, so normal Codex commands need no localhost/network approval.
Images are staged beside the request and copied for the bubble before staging
is removed. Replies remain hidden when their sending CLI tab is in front.
Timeouts with an unknown outcome are not automatically retried; their staging
directory is retained for a late copy. Older app versions without an inbox use
the original localhost transport.

Quick answers default to `gpt-6-luna` with low reasoning effort for latency.
This changes the model from upstream and does not promise identical answer
quality. Set `WT_QUICK_MODEL` and `WT_QUICK_EFFORT` in the launch environment
or `~/.walkie-talkie/elevenlabs.env` to choose another available Codex model.

Optional ElevenLabs credentials can be stored in the local
`~/.walkie-talkie/elevenlabs.env` configuration file. The browser extension is
loaded from `chrome-extension/` using `chrome://extensions` or Edge’s
`edge://extensions` → Developer mode → **Load unpacked**. During a prompt, hold
Command + Shift until an element is outlined (about half a second), then click
to pick it. The extension also pauses playing browser media while dictating.

## First use

1. Open **Find Codex chat…** for quick access to recent chats, ordered by
   activity and labeled with their folder. Use the keyboard to select a chat;
   **Return** binds it and closes the picker. **⌘Return** opens it in the
   configured destination (Desktop by default). The selected row shows only
   the latest prompt and answer.
2. Start a prompt with **⌘⌃D** or from the menu. Speak, optionally capture a
   screenshot or select context, then press **⌘⌃D again to stop**. Review the prompt and attachments;
   send or cancel it in the held-prompt panel.
3. Choose **Engine** to select a local model or optional cloud recognizer, and
   **Mic** to select an input device. The menu also exposes local warm-up,
   live-caption, and cloud-fallback controls.

Keyboard controls now use **Control + Command + a letter**, including **N**
for a new chat, **V** for film, **T** for typed notes, **A** for Quick Ask, **I**
for plain dictation, **P** for a caret prompt and **R** for destination switching.
**⌃⌘Esc** cancels without starting anything while idle. The recording reminder
shows the available keyboard shortcuts; choose the original mouse legend under
**Gestures → Recording hints** if wanted. These aliases work in either mouse
mode, without Fn or Options+, alongside the existing mouse/F-key mappings.
See the [complete shortcut table](docs/GESTURES.md#your-trackpad-and-keyboard).

Use **⌃⌘S** while recording a prompt to capture the display under the pointer.
For local English recognition, choose **Engine → Local language → English**;
Automatic remains the default. This selection applies to captions and the
final transcript without reloading the model.

The [daily workflows](docs/CODEX_TEST_GUIDE.md#daily-workflows) cover bound
delivery, new background chats, and the folder based history explorer. The
[keyboard and mouse guide](docs/GESTURES.md) covers trackpad use, the optional
one-time Options+ mappings, and Wheel mode. The app's menu shows keyboard
shortcuts beside each action; mouse-only actions have hover hints.

**⌃⌘D** continues the currently bound chat. **Prompt to new / ⌃⌘N** records
for a new chat in the bound chat's full working folder, or the saved default
when unbound. Press **⌃⌘N again while recording** to switch to the saved default
and choose another folder. Review and send the prompt to create the chat; it is
submitted in the background and does not open a terminal or change focus.
Submitted work runs through the shared Codex app-server and can continue after
Walkie quits. Approval requests and questions remain available when Walkie
reopens; see the [workflow guide](docs/CODEX_TEST_GUIDE.md#daily-workflows) and
[parity matrix](docs/CODEX_PARITY.md) for current evidence and limits.

**Find Codex chat…** opens as a keyboard quick-access picker. It immediately
shows recent chats in activity order with a folder label; typing searches chat
titles and folder paths, and an optional folder filter narrows prompt and answer
search. The cached list appears immediately while SQLite reads recent metadata
and the latest prompt/answer asynchronously. The selected chat shows only its
latest prompt and answer. **Return**
binds the selected chat and dismisses the picker. **⌘Return** opens it in the
default destination, Desktop; the **Open Chats in Terminal** preference changes
that destination to CLI. Browsing does not change D's binding. Desktop opens
immediately: when another client holds the chat, Desktop shows saved history in
its read-only conflict view. Walkie does not release or interrupt that client.
CLI attachment and sending retain their ownership checks. Archived chats are hidden by default, and guardian
reviews are excluded. Approval requests and questions are available in a
secondary keyboard mode. The cursor shows bound-chat activity and the total
running count, then briefly marks completed work with a checkmark. There are no
unread markers or completion popups.

The saved default is **`~/workspace`**; change it through **New chat folder →
Choose folder…**, or select **Use ~/workspace** to reset it. The saved setting
wins over the legacy `WT_PROJECT_ROOT` launch-environment fallback.

The packaged app uses the generic local bundle identity `local.walkie-talkie`.
On a fresh profile, Local Whisper is the default engine; saved preferences or
`WT_SOURCE` can select another engine. The Mic menu lists all connected input devices by their macOS names. Automatic
follows the macOS default input; explicit choices survive USB reconnects. A
disconnected choice falls back to the current default until it returns. There is no
machine-specific microphone exclusion in this fork.

Transcribed recordings are kept locally as WAV plus transcript under
`~/.walkie-talkie/voice-corpus`, whether or not their prompt was delivered.
Cancelled takes are staged for five minutes for recovery; a cancelled take can
enter the corpus if it is recovered and transcribed. `~/.walkie-talkie/outbox.jsonl`
records delivered prompts. No private Quiet Journal audio was used for this
fork's testing. The optional `helpers/corpus_report.py` previews locally by
default. Email requires `--send` and explicit destination/credential configuration;
it is not installed or scheduled by the app, and no report email was sent.

## Troubleshooting and verification

The loopback control listener uses the first free port from 8917–8919. The
manual test guide documents safe test routes and known Codex-specific gaps:
[docs/CODEX_TEST_GUIDE.md](docs/CODEX_TEST_GUIDE.md). The feature/evidence matrix
is in [docs/CODEX_PARITY.md](docs/CODEX_PARITY.md).

For a running app, inspect `~/.walkie-talkie/relay.log` and use the guide's
read-only `/target`, `/engine`, and `/test/state` routes. Restart the installed
app only after a build has completed; `./relay-restart.sh --build` performs the
project's guarded build-and-relaunch flow.

The current Python suite has 140 passing tests. The Swift suite has 352 passing
tests and 2 opt-in integration skips (354 executed, no failures); those opt-in
checks also passed separately in a disposable native CLI PTY. The finish helper verifies the exact session and closes only a window containing
that single tab; a window with sibling tabs is refused before signaling Codex. The checks in the guide distinguish route or
protocol evidence from packaged-app and UI evidence. See the parity matrix for
the current status.

Recent chat metadata is read from the local Codex history database. The picker
uses its cached list immediately and reads recent metadata and the latest
prompt/answer asynchronously; it does not scan running processes or test chat
ownership while listing. Ownership is checked only when opening a chat or
sending a prompt.
