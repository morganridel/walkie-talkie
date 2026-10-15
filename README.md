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
- Optional: ElevenLabs credentials for cloud transcription; Chrome and the
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
suite passes 268 tests. The release bundle builds, installs, launches, and loads
the local model successfully. The installed helper discovers the native Codex CLI.
The local signing certificate is unavailable, so macOS may ask for permissions
again after a rebuild. Physical controls and desktop message delivery still need
the manual checks below.

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
terms. One cached-model run took 5.12 s to warm and 2.85 s to decode a 28 s public
sample; timings vary by hardware and cache state.

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
the CLI bridge only; it does not verify desktop-app delivery or the packaged app.

Codex desktop integration uses a same-user IPC adapter that preserves the
desktop protocol version and verifies thread ownership. This is an internal,
version-coupled interface. Ownership discovery has passed a read-only probe;
desktop message delivery still needs an end-to-end check in a disposable desktop
chat before relying on it. Quick-answer timing measured roughly 0.20 s to worker
ready, 2.61 s to first delta, and 2.71 s total; web mode measured 5.24 s to first
delta and 5.36 s total. These are observations from one run, not performance
guarantees.

Quick answers default to `gpt-6-luna` with low reasoning effort for latency.
This changes the model from upstream and does not promise identical answer
quality. Set `WT_QUICK_MODEL` and `WT_QUICK_EFFORT` in the launch environment
or `~/.walkie-talkie/elevenlabs.env` to choose another available Codex model.

Optional ElevenLabs credentials can be stored in the local
`~/.walkie-talkie/elevenlabs.env` configuration file. The Chrome extension is
loaded from `chrome-extension/` using `chrome://extensions` → Developer mode →
**Load unpacked**.

## First use

1. Open the menu-bar app and choose **Bind Codex chat…**. Search by chat title or
   project, select the intended chat, and bind it. Confirm the binding in the
   app's target row before dictating.
2. Start a prompt with **⌘⌃D** or from the menu. Speak, optionally capture a
   screenshot or select context, then stop. Review the prompt and attachments;
   send or cancel it in the held-prompt panel.
3. Choose **Engine** to select a local model or optional cloud recognizer, and
   **Mic** to select an input device. The menu also exposes local warm-up,
   live-caption, and cloud-fallback controls.

The app's menu lists current gestures and actions. Use **Disconnect** to clear a
binding. **Rebind to…** offers recent destinations and searches Codex session
history. New Codex chats can be launched through the Codex CLI from **Prompt to
new**. Codex desktop message delivery remains under validation; verify the
result in the selected chat before relying on it.

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

The current Python suite has 43 passing tests and the Swift suite has 268 passing
tests. The finish helper has 12 mocked tests and a safe dry-run check; it has not
closed a real Terminal tab. The checks in the guide distinguish route or
protocol evidence from packaged-app and UI evidence. See the parity matrix for
the current status.
