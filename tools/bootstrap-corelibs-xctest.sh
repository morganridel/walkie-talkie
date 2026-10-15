#!/usr/bin/env bash
set -euo pipefail

# Apple ships XCTest with full Xcode, but some Command Line Tools installs omit
# its Swift module. Prepare Swift's matching open-source XCTest implementation
# locally for `swift test`; normal Xcode builds continue to use Apple's XCTest.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN_DIR="${WALKIE_SWIFT_TOOLCHAIN_DIR:-$HOME/Library/Caches/WalkieTalkie/Swift6.2.3}"
CHECKOUT="$TOOLCHAIN_DIR/swift-corelibs-xctest"
REVISION="fb33dcf66316ec90809f877eaa41de5bc9f2e798"

if [[ ! -d "$CHECKOUT/.git" ]]; then
    mkdir -p "$TOOLCHAIN_DIR"
    git clone --depth 1 --branch swift-6.2.3-RELEASE \
        https://github.com/swiftlang/swift-corelibs-xctest.git "$CHECKOUT"
fi
ACTUAL_REVISION="$(git -C "$CHECKOUT" rev-parse HEAD)"
[[ "$ACTUAL_REVISION" == "$REVISION" ]] || {
    echo "Unexpected swift-corelibs-xctest revision: $ACTUAL_REVISION" >&2
    echo "Expected the Swift 6.2.3 release revision $REVISION." >&2
    exit 1
}

python3 - "$CHECKOUT/Package.swift" "$CHECKOUT/Sources/XCTest/Public/Asynchronous/XCTWaiter.swift" \
    "$CHECKOUT/Sources/XCTest/Public/Asynchronous/XCTNSPredicateExpectation.swift" <<'PY'
from pathlib import Path
import sys

manifest, *sources = map(Path, sys.argv[1:])
text = manifest.read_text()
text = text.replace("// swift-tools-version:4.0", "// swift-tools-version:5.9", 1)
old = '.target(name: "XCTest", dependencies: [], path: "Sources"),'
new = '.target(name: "XCTest", dependencies: [], path: "Sources", swiftSettings: [.define("USE_FOUNDATION_FRAMEWORK")]),'
if new not in text:
    if old not in text:
        raise SystemExit("Could not locate XCTest target in the upstream package manifest")
    text = text.replace(old, new, 1)
manifest.write_text(text)

# Swift 6.2 renamed this Foundation spelling; upstream's 6.2.3 tag predates it.
for source in sources:
    text = source.read_text()
    source.write_text(text.replace("forMode: .defaultRunLoopMode", "forMode: .default").replace("forMode: .default,", "forMode: .default,").replace("mode: .defaultRunLoopMode", "mode: .default"))
PY

printf 'Local XCTest support ready at %s\n' "$CHECKOUT"
