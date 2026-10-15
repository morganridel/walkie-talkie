# Codex fork: implementation and evidence

This matrix describes the current source tree separately from runtime evidence.
“Implemented” means there is code or a route for the behavior; it does not mean
the behavior passed end to end. Record evidence here after following [the manual
test guide](CODEX_TEST_GUIDE.md).

| Area | Implementation in this fork | Verification evidence |
|---|---|---|
| Build and identity | SwiftPM and packaging use `local.walkie-talkie`. Fresh-profile engine default is Local Whisper; microphone discovery is system-based with automatic selection. Packaged Python helpers suppress bytecode writes inside the signed bundle. | **Verified build/install/startup.** Release bundle installed and launched; local API responds; final signature verified after workers started. Full Swift suite: 267 passed. Cached official Swift 6.2.3 leaves system CLT unchanged. Ad-hoc signing means macOS may require permissions again after rebuilding. |
| Codex CLI discovery | `CodexBridge` resolves the helper and bundled native CLI executable; `CODEX_BIN` can override the binary. | **Verified.** Native CLI connected in PTY E2E; installed helper doctor resolves the native binary and version. |
| Chat picker | `Bind Codex chat…` lists chat metadata; picker supports title/project search, project filter, refresh, and explicit bind. | **Pending.** Verify a real list, filtering, bind, target display, disconnect, and rebind. |
| CLI chat sending | Codex target is represented in `TerminalBinding`; delivery calls the bridge with text and recognized screenshot image attachments. Busy sends can steer the exact active turn. | **Verified in native CLI PTY E2E.** First prompt appeared exactly once; follow-up direct send worked; a synthetic red image was interpreted as red; a busy follow-up steered the same turn ID and produced the expected final marker. Test chat was archived and TUI exited 0. This is CLI protocol evidence, not packaged-app UI evidence. |
| Codex desktop delivery | Same-user native desktop IPC adapter preserves protocol version and verifies owner discovery for desktop threads. | **Partial.** Read-only probe confirmed active ownership. No desktop message was sent; end-to-end send awaits explicit approval for a disposable desktop test chat. IPC is internal and version-coupled; compatibility may change with Codex Desktop. Desktop completion uses the receiving model's `set_thread_archived` tool; external exact-window closing is unsupported and unverified. |
| New/resumed sessions | `walkie-codex` starts the shared daemon idempotently, persists the initial prompt through RPC before attaching the CLI TUI, creates/resumes the exact conversation, and writes a tty sidecar. `SpawnTerminal` uses this launcher. | **Verified in native CLI PTY E2E.** Initial prompt delivered once. New launch without an initial prompt is deliberately rejected; `--resume` is supported. Packaged-app spawn UI still needs verification. |
| Search and history | `Rebind to…` searches Codex thread metadata and message history through read-only queries; live hits can bind and closed hits can resume. Prompt History/Full Log remain available. | **Pending.** Verify search, snippet/role, tty association, closed-thread resume, and fresh/archived behavior. |
| Quick answer | `QuickAsk` uses a persistent `quick-worker` for three stages: short answer, web/source check, and adversarial source review. It supports cancellation and source links. | **Protocol smoke passed.** One run: worker ready 0.20 s, first delta 2.61 s, total 2.71 s; web mode first delta 5.24 s, total 5.36 s. Not a performance guarantee. UI stages, source links, and cancellation still need manual verification. |
| Local transcription | Helper discovery can reuse Quiet Journal's runtime and on-disk model cache; default model is multilingual with no language allowlist. A separate worker owns the loaded model and its memory. | **Measured, manual coverage pending.** Cached model warm-up 5.12 s; public 28 s audio sample decoded in 2.85 s on the development Mac. About 1.54 GB active model memory plus a 512 MB decode cache was observed; the in-memory model is not shared with Quiet Journal. |
| Cloud transcription/fallback | ElevenLabs cloud rows and local-now/automatic-local options remain. | **Pending.** Test cloud response, injected failure, local fallback race, and provider/mic switching. |
| Wispr Flow | Wispr implementation and menu integration remain controlled by `WT_WISPR_ENGINE`; current source defaults its row on. The raw chord path is separate from a successful engine transcript/delivery. | **Pending.** Validate menu, transcript capture, and delivery independently; do not infer engine reliability from raw chords. |
| Captions and microphone | Local caption-band controls and microphone chooser are implemented. Test routes can supply synthetic caption text and select devices. | **Pending.** Synthetic caption UI and device selection are route-level only; test actual MLX captions and recorded input. |
| Prompt/reply UI | Held prompt, edit/countdown/autosend/cancel/recover, `walkie-reply` text/image callbacks, reply bubble, images, links, and reply-back actions are present in source. | **Pending UI.** CLI message delivery passed a PTY protocol smoke; reply token, rendered bubble, image persistence, pin, reply-back, and send/cancel UI need manual verification. |
| Kamikaze / finish | `kamikaze` adds a completion cue. CLI `walkie-finish` waits for the active exact turn, verifies sidecar/PID/TTY and root terminal owner identity, then signals only its Codex TUI and closes one tab. Desktop cue asks the receiving model to archive itself through `set_thread_archived`. | **Partial.** 12 mocked helper tests and a safe `--dry-run` pass; no real Terminal close has been tested. Desktop archive route is not end-to-end verified. |
| Screen/context | Screenshot, region crop/move/cancel, accessibility selection, Chrome DOM picker/extension, screen film/contact sheet, and Chrome music bridge have implementation/routes. | **Partial.** Synthetic image delivery passed in CLI PTY smoke. Chrome extension, DOM selection, music, physical event taps, film recording, and crop/move behavior still need real-device checks. |
| Gestures and caret | Menu-described hotkeys, Logi/Wheel handlers, plain dictation, prompt-at-caret, and clipboard/paste-last paths remain implemented. | **Pending.** Test real event tap, destination/caret behavior, and clipboard restoration; route chord injection alone is insufficient. |
| Outbox/restart/login/settings | Outbox records delivered events; guarded restart script and menu preferences remain. | **Partial.** Installed app reports login registration and survived a graceful idle replacement/relaunch. Bound restoration, preference persistence, permission grants, and delivered logging need manual checks. |
| Voice corpus and report helper | Transcribed recordings retain WAV plus transcript whether or not delivered. Cancelled takes are staged for five minutes and can enter the corpus if recovered and transcribed; outbox records delivered prompts only. | **Retention documented; report helper not installed or scheduled.** Default preview and explicit recipient/inbox requirements pass two tests. No report email was sent. No private Quiet Journal audio was used. |

## Evidence log

Evidence below separates implementation from observed results. A helper
protocol test or read-only ownership probe does not establish desktop send or
full UI parity. Include app build/revision, date, method, and evidence location
for future runs. Redact private chat content, audio, tokens, paths, and credentials.

| Date/build | Area and method | Result/evidence |
|---|---|---|
| Current debug build | `./tools/swift-build.sh build` using cached official Swift 6.2.3 toolchain and compiler workaround; system CLT unchanged. | Debug application build succeeds; full XCTest suite: 267 passed. |
| 2026-10-15 release | Signed bundle build, install, launch, local API, and signature verification after model startup. | Passed. Both transcription workers ready using Quiet Journal runtime/cache; Quiet Journal health remains good. Accessibility is not granted, so event tap is unavailable. Automated native UI access was not approved. |
| Current Python tests | Full Python test suite. | 35 tests pass. |
| CLI integration | Native Codex CLI PTY smoke on a disposable conversation. | Initial prompt exactly once; follow-up direct send; synthetic red image read as red; busy send steered the same turn ID and reached expected final marker. Test chat archived; TUI exited 0. |
| Finish helper | `walkie-finish` unit tests and `--dry-run`. | 12 mocked tests pass; safe dry-run passed. No real terminal tab close has been attempted. |
| Current desktop probe | Read-only same-user Codex Desktop IPC ownership probe. | Active ownership confirmed; no message was sent. End-to-end desktop delivery awaits explicit disposable-chat approval. |
| Current performance samples | Cached MLX model and quick-worker measurements on development Mac. | MLX warm-up 5.12 s; 28 s public WAV decode 2.85 s. Quick worker ready 0.20 s, first delta 2.61 s, total 2.71 s; web mode first delta 5.24 s, total 5.36 s. Single-run measurements only. |

For detailed procedures, including loopback test hooks and safety boundaries,
see [CODEX_TEST_GUIDE.md](CODEX_TEST_GUIDE.md).
