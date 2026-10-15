#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_BIN="${WALKIE_SWIFT:-$WALKIE_SWIFT_TOOLCHAIN_DIR/expanded/swift-6.2.3-RELEASE-osx-package.pkg/Payload/usr/bin/swift}"
SWIFTC="$(dirname "$SWIFT_BIN")/swiftc"
CORELIBS="$WALKIE_SWIFT_TOOLCHAIN_DIR/swift-corelibs-xctest"
CORELIBS_BIN="$("$SWIFT_BIN" build --package-path "$CORELIBS" --show-bin-path)"
BIN_PATH="$("$SWIFT_BIN" build --show-bin-path)"
LINK_LIST="$BIN_PATH/WalkieTalkiePackageTests.product/Objects.LinkFileList"

[[ -f "$LINK_LIST" ]] || {
    echo "SwiftPM did not produce its test object link list at $LINK_LIST" >&2
    exit 1
}

FILTER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --filter)
            [[ $# -ge 2 ]] || { echo "--filter needs a pattern" >&2; exit 2; }
            FILTER="$2"
            shift 2
            ;;
        *)
            echo "Local corelibs XCTest runner supports only --filter; unexpected argument: $1" >&2
            exit 2
            ;;
    esac
done

RUN_DIR="$(mktemp -d "$ROOT/work/corelibs-tests.XXXXXX")"
trap 'rm -rf "$RUN_DIR"' EXIT
python3 - "$ROOT/Tests/WalkieTalkieTests" "$RUN_DIR/main.swift" "$FILTER" <<'PY'
from pathlib import Path
import re
import sys

source_dir, output, filter_pattern = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
pattern = re.compile(filter_pattern) if filter_pattern else None
classes = []
for path in sorted(source_dir.glob("*.swift")):
    text = path.read_text()
    declarations = list(re.finditer(r"^(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b[^\n]*\{", text, re.M))
    for index, declaration in enumerate(declarations):
        end = declarations[index + 1].start() if index + 1 < len(declarations) else len(text)
        section = text[declaration.end():end]
        methods = re.findall(
            r"^\s*(?:@\w+(?:\([^\n]*\))?\s+)*func\s+(test\w+)\s*\(([^)]*)\)\s*([^\{\n]*)\{",
            section,
            re.M,
        )
        selected = []
        for name, arguments, signature in methods:
            if arguments.strip() or "async" in signature:
                raise SystemExit(f"Unsupported XCTest method signature in {path.name}: {name}({arguments}) {signature}")
            if pattern is None or pattern.search(f"WalkieTalkieTests.{declaration.group(1)}/{name}"):
                selected.append(name)
        if selected:
            classes.append((declaration.group(1), selected))

count = sum(len(methods) for _, methods in classes)
if count == 0:
    raise SystemExit(f"No XCTest cases matched filter {filter_pattern!r}; refusing a zero-test success")
lines = ["import XCTest", "@testable import WalkieTalkieTests", "import Darwin", "", "exit(XCTMain(["]
for classname, methods in classes:
    lines.append("    testCase([")
    for method in methods:
        lines.append(f'        ("{method}", {classname}.{method}),')
    lines.append("    ]),")
lines.append("]))")
output.write_text("\n".join(lines) + "\n")
print(f"Running {count} XCTest cases in {len(classes)} classes")
PY

python3 - "$LINK_LIST" "$RUN_DIR/objects.nul" <<'PY'
from pathlib import Path
import sys
link_list, output = Path(sys.argv[1]), Path(sys.argv[2])
objects = [line for line in link_list.read_text().splitlines()
           if not line.endswith("/WalkieTalkiePackageTests.build/runner.swift.o")]
output.write_bytes(b"\0".join(path.encode() for path in objects) + b"\0")
PY

xargs -0 "$SWIFTC" \
    -sdk "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}" \
    -enable-testing \
    -I "$BIN_PATH/Modules" \
    -I "$BIN_PATH/ObjCTry.build" \
    -I "$BIN_PATH/CProjectM.build" \
    -I "$ROOT/Sources/ObjCTry/include" \
    -I "$ROOT/Sources/CProjectM/include" \
    -I "$CORELIBS_BIN/Modules" \
    -L "$CORELIBS_BIN" -lXCTest -Xlinker -rpath -Xlinker "$CORELIBS_BIN" \
    -L "$BIN_PATH" -Xlinker -rpath -Xlinker "$BIN_PATH" \
    -L "$ROOT/vendor/projectm/lib" -lprojectM-4 -lprojectM_eval -lc++ \
    -framework OpenGL -framework IOSurface -framework CoreFoundation \
    -framework AppKit -framework AVFoundation -framework ApplicationServices \
    -framework WebKit -framework ServiceManagement -framework ScreenCaptureKit \
    -framework AVFAudio -framework CoreAudio -framework AudioToolbox \
    -framework UniformTypeIdentifiers -framework Security -framework Carbon \
    -framework CoreGraphics -framework QuartzCore \
    "$RUN_DIR/main.swift" -o "$RUN_DIR/walkie-tests" <"$RUN_DIR/objects.nul"

"$RUN_DIR/walkie-tests"
