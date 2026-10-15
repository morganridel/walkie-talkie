# Optional development harnesses

`wt-night.sh` and `vm-lab.sh` support an optional Tart-based development and
test workflow. The nightly runner starts Claude Code in a tmux session; this
workflow remains Claude-specific and is not required by Walkie Talkie's app
features. It does not claim Codex parity for those harnesses.

The `local.walkie-talkie.*.plist.example` files are examples only. They are not
installed or scheduled by the app. Before using one, replace `@REPO@`, `@HOME@`
and `@TART_HOME@` with local paths, then review its schedule and VM lifecycle
effects. `wt-night.sh` derives the repository root from its own location by
default; set `WT_REPO` to override it.
