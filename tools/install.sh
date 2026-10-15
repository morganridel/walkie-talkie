#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Walkie Talkie.app"
if [[ "${1:-}" == "--staged" ]]; then
    if pgrep -x "Walkie Talkie" >/dev/null 2>&1; then
        echo "Quit Walkie Talkie before installing a staged bundle; use the normal installer for a guarded restart." >&2
        exit 1
    fi
    "$ROOT/build-app.sh" --swap-staged
elif pgrep -x "Walkie Talkie" >/dev/null 2>&1; then
    "$ROOT/relay-restart.sh" --build
else
    "$ROOT/build-app.sh"
fi
mkdir -p "$HOME/.local/bin"
for helper in walkie-codex walkie-reply walkie-finish; do
    destination="$HOME/.local/bin/$helper"
    if [[ -e "$destination" && ! -L "$destination" ]]; then
        echo "Preserving existing $destination; use $APP/Contents/Resources/$helper directly." >&2
        continue
    fi
    ln -sfn "$APP/Contents/Resources/$helper" "$destination"
done
open "$APP"
echo "Walkie Talkie is installed. Allow its macOS microphone, Accessibility, and Screen Recording prompts."
