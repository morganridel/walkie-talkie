#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN_DIR="${WALKIE_SWIFT_TOOLCHAIN_DIR:-$HOME/Library/Caches/WalkieTalkie/Swift6.2.3}"
LOCAL_SWIFT="$TOOLCHAIN_DIR/expanded/swift-6.2.3-RELEASE-osx-package.pkg/Payload/usr/bin/swift"
export WALKIE_SWIFT_TOOLCHAIN_DIR="$TOOLCHAIN_DIR"

if [[ $# -eq 0 || ( "$1" != "build" && "$1" != "test" && "$1" != "run" ) ]]; then
    echo "usage: $0 build|test [SwiftPM arguments…] | run <Swift script and arguments…>" >&2
    exit 2
fi
ACTION="$1"
shift

check_swift() {
    local candidate="$1"
    [[ -x "$candidate" ]] || return 1
    (cd "$ROOT" && "$candidate" package dump-package >/dev/null 2>&1)
}

if [[ -n "${WALKIE_SWIFT:-}" ]]; then
    SWIFT_BIN="$WALKIE_SWIFT"
    if ! check_swift "$SWIFT_BIN"; then
        echo "WALKIE_SWIFT does not run SwiftPM or cannot load this package manifest: $SWIFT_BIN" >&2
        exit 1
    fi
elif check_swift "$LOCAL_SWIFT"; then
    SWIFT_BIN="$LOCAL_SWIFT"
else
    SYSTEM_SWIFT="$(command -v swift || true)"
    if [[ -n "$SYSTEM_SWIFT" ]] && check_swift "$SYSTEM_SWIFT"; then
        SWIFT_BIN="$SYSTEM_SWIFT"
    else
        cat >&2 <<'EOF'
No usable SwiftPM toolchain was found. On a fresh checkout, run:

  ./tools/bootstrap-swift.sh

This downloads Swift 6.2.3 from Swift.org, checks its signed/notarized package,
and expands it under ~/Library/Caches/WalkieTalkie/Swift6.2.3. It does not install
or select a system toolchain. You can instead set WALKIE_SWIFT to a compatible
Swift executable.
EOF
        exit 1
    fi
fi

echo "Using $($SWIFT_BIN --version | head -n 1)"
cd "$ROOT"
if [[ "$ACTION" == "run" ]]; then
    if [[ $# -lt 1 ]]; then
        echo "usage: $0 run <Swift script and arguments…>" >&2
        exit 2
    fi
    SCRIPT="$1"
    shift
    SWIFTC="$(dirname "$SWIFT_BIN")/swiftc"
    RUN_DIR="$(mktemp -d "$ROOT/work/swift-script.XXXXXX")"
    trap 'rm -rf "$RUN_DIR"' EXIT
    SCRIPT_SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
    "$SWIFTC" -sdk "$SCRIPT_SDK" "$SCRIPT" -o "$RUN_DIR/script"
    "$RUN_DIR/script" "$@"
    exit $?
fi
USE_LOCAL_XCTEST=0
if [[ "$ACTION" == "test" ]]; then
    mkdir -p "$ROOT/work"
    PROBE_DIR="$(mktemp -d "$ROOT/work/xctest-probe.XXXXXX")"
    PROBE_FILE="$PROBE_DIR/probe.swift"
    trap 'rm -rf "$PROBE_DIR"' EXIT
    printf 'import XCTest\n' >"$PROBE_FILE"
    SWIFTC="$(dirname "$SWIFT_BIN")/swiftc"
    if [[ ! -x "$SWIFTC" ]] || ! "$SWIFTC" -typecheck "$PROBE_FILE" >/dev/null 2>&1; then
        "$ROOT/tools/bootstrap-corelibs-xctest.sh" >&2
        export WALKIE_CORELIBS_XCTEST=1
        USE_LOCAL_XCTEST=1
        "$SWIFT_BIN" package dump-package >/dev/null
    fi
fi
# Swift 6.2.3 has a debug IRGen crash on a CGFloat closure in this project.
# This frontend switch avoids that compiler bug while preserving diagnostics.
if [[ "$ACTION" == "test" && "$USE_LOCAL_XCTEST" == "1" ]]; then
    "$SWIFT_BIN" build --build-tests \
        -Xswiftc -Xfrontend -Xswiftc -disable-round-trip-debug-types
    exec "$ROOT/tools/run-corelibs-tests.sh" "$@"
fi
exec "$SWIFT_BIN" "$ACTION" \
    -Xswiftc -Xfrontend -Xswiftc -disable-round-trip-debug-types \
    "$@"
