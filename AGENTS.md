# Working on the Codex fork

This is the Codex adaptation of upstream Walkie Talkie. Read `README.md`,
`docs/CODEX_PARITY.md`, and the relevant source before changing behavior.
The old `.claude/rules/` and historical evaluation notes contain upstream
measurements and design history; some agent commands and identities are obsolete.

## Build and validate

- Use `./tools/swift-build.sh build` and `./tools/swift-build.sh test`.
- Run `python3 -m unittest discover -s helpers -p 'test_*.py'` for helper changes.
- Use `./tools/install.sh` to build/install with a guarded restart when running.
  `./build-app.sh --stage-only` stages without replacing a running app.
- Launch through `open "/Applications/Walkie Talkie.app"`, not the executable.
- Verify `codesign --verify --deep --strict "/Applications/Walkie Talkie.app"`
  after the Python workers have started. Do not write caches into the bundle.
- Distinguish unit/protocol tests from visible UI, microphone, browser, and
  physical gesture tests. Update the parity matrix with evidence and remaining gaps.

## Codex targets

- Bind by stable thread ID. Never guess an existing target from foreground focus.
- Use the shared app-server for its own threads and owner-verified desktop IPC
  for desktop threads. Do not resume a second private copy of a desktop thread.
- Desktop IPC is internal/version-coupled: fail clearly on incompatibility.
  Do not automatically retry a send whose outcome is unknown.
- Keep sidecar PID, exact conversation command, and TTY ownership checks.
- Use genuine image inputs for referenced screenshot/crop/film sheets.
- `walkie-finish` may close only its verified CLI tab after the exact turn ends.
  Desktop completion archives only the receiving chat using its legitimate app tool.

## Identity and local data

- Keep bundle ID `local.walkie-talkie` stable. Ad-hoc signing can require renewed
  macOS permissions after rebuilds. Never modify the TCC database.
- Runtime state is in `~/.walkie-talkie`; screenshots are under
  `~/Library/Caches/local.walkie-talkie`. Treat voice corpus and logs as private.
- Quiet Journal's Python/model cache may be reused; do not alter its service,
  settings, or journal contents for Walkie Talkie tests. Use public/synthetic audio.
- Keep generated tools, logs, captures, credentials, and model caches out of Git.
- Optional VM/night harnesses remain legacy development tools; see `tools/README.md`.
