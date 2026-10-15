# Walkie Talkie — Codex fork

Walkie Talkie is a macOS voice-and-context companion for coding chats. It can
transcribe speech locally with MLX Whisper or through an optional cloud engine,
then assemble words, screenshots, selected text, and browser picks into a prompt.
Prompts are held for review before delivery. The app also has a quick-answer
panel for spoken questions.

This fork adapts the upstream project for Codex CLI and Codex chats. Upstream:
[walkie-talkie](https://github.com/victorrentea/walkie-talkie).

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
suite executes 299 tests with 2 opt-in integration skips and no failures (297 passed). The release bundle builds, installs, launches, and loads
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
the exact Codex chat. It stages images in the app cache before sending, avoiding
blocked native reads from protected project folders. Images are copied for the
bubble before staging is removed. Timeouts with an unknown outcome are not
automatically retried; their staging directory is retained for a late copy.

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

1. Open the menu-bar app and choose **Bind Codex chat…**. Search by chat title or
   project, select the intended chat, and bind it. Confirm the binding in the
   app's target row before dictating.
2. Start a prompt with **⌘⌃D** or from the menu. Speak, optionally capture a
   screenshot or select context, then press **⌘⌃D again to stop**. Review the prompt and attachments;
   send or cancel it in the held-prompt panel.
3. Choose **Engine** to select a local model or optional cloud recognizer, and
   **Mic** to select an input device. The menu also exposes local warm-up,
   live-caption, and cloud-fallback controls.

Use **⌃⌘S** while recording a prompt to capture the display under the pointer.
For local English recognition, choose **Engine → Local language → English**;
Automatic remains the default. This selection applies to captions and the
final transcript without reloading the model.

The [keyboard and mouse guide](docs/GESTURES.md) covers trackpad use, the
optional one-time Options+ mappings, and Wheel mode. The app's menu lists current gestures and actions. Use **Disconnect** to clear a
binding. **Rebind to…** offers recent destinations and searches Codex session
history. New Codex chats can be launched through the Codex CLI from **Prompt to
new**. Codex desktop text, images, and steering have passed disposable-chat
tests; verify the selected target before sending work prompts.

The packaged app uses the generic local bundle identity `local.walkie-talkie`.
On a fresh profile, Local Whisper is the default engine; saved preferences or
`WT_SOURCE` can select another engine. Microphone choices are discovered from
the current system inputs, with automatic selection as the default; there is no
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

The current Python suite has 70 passing tests. The Swift suite has 297 passing
tests and 2 opt-in integration skips (299 executed, no failures); those opt-in
checks also passed separately in a disposable native CLI PTY. The finish helper verifies the exact session and closes only a window containing
that single tab; a window with sibling tabs is refused before signaling Codex. The checks in the guide distinguish route or
protocol evidence from packaged-app and UI evidence. See the parity matrix for
the current status.
