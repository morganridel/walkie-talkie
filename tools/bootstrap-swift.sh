#!/usr/bin/env bash
set -euo pipefail

# Download and unpack the official Swift toolchain into a user-local cache.
# No installer, sudo, xcode-select, or system-wide writes.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN_DIR="${WALKIE_SWIFT_TOOLCHAIN_DIR:-$HOME/Library/Caches/WalkieTalkie/Swift6.2.3}"
VERSION="6.2.3"
PACKAGE_NAME="swift-${VERSION}-RELEASE-osx.pkg"
PACKAGE_URL="https://download.swift.org/swift-${VERSION}-release/xcode/swift-${VERSION}-RELEASE/swift-${VERSION}-RELEASE-osx.pkg"
PACKAGE_PATH="$TOOLCHAIN_DIR/$PACKAGE_NAME"
EXPANDED="$TOOLCHAIN_DIR/expanded"
SWIFT_BIN="$EXPANDED/swift-${VERSION}-RELEASE-osx-package.pkg/Payload/usr/bin/swift"

if [[ -x "$SWIFT_BIN" ]]; then
    printf 'Swift %s is ready: %s\n' "$VERSION" "$SWIFT_BIN"
    exit 0
fi

mkdir -p "$TOOLCHAIN_DIR"
if [[ ! -s "$PACKAGE_PATH" ]]; then
    echo "Downloading official Swift $VERSION toolchain (about 1.7 GB)…" >&2
    curl --fail --location --retry 3 --output "$PACKAGE_PATH.part" "$PACKAGE_URL"
    mv "$PACKAGE_PATH.part" "$PACKAGE_PATH"
fi

SIGNATURE="$(pkgutil --check-signature "$PACKAGE_PATH")"
printf '%s\n' "$SIGNATURE" >&2
grep -q 'Status: signed by a developer certificate issued by Apple for distribution' <<<"$SIGNATURE"
grep -q 'Notarization: trusted by the Apple notary service' <<<"$SIGNATURE"
grep -q 'Developer ID Installer: Swift Open Source (V9AUD2URP3)' <<<"$SIGNATURE"

rm -rf "$EXPANDED"
pkgutil --expand-full "$PACKAGE_PATH" "$EXPANDED"
[[ -x "$SWIFT_BIN" ]] || {
    echo "Swift toolchain package expanded, but swift was not found at the expected path." >&2
    exit 1
}

"$SWIFT_BIN" --version
printf 'Toolchain ready: %s\n' "$SWIFT_BIN"
