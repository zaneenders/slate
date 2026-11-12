#!/bin/sh
set -eu

if [ "$(uname -s)" != Darwin ]; then
  echo "The render allocation probe requires macOS." >&2
  exit 1
fi

cd "$(dirname "$0")/.."

probe_directory=$(mktemp -d "${TMPDIR:-/tmp}/slate-render-allocations.XXXXXX")
trap 'rm -rf "$probe_directory"' EXIT HUP INT TERM
probe_library="$probe_directory/libSlateAllocationProbe.dylib"
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -dynamiclib -mmacosx-version-min=27.0 \
  Tests/CAllocationProbe/AllocationProbe.c -o "$probe_library"

# The allocation guarantee covers optimized builds. Build before injection so
# compiler/SwiftPM work is outside the probe process; the probe test skips here.
SLATE_ALLOCATION_PROBE=0 swift test -c release --filter Allocation
products=$(swift build -c release --show-bin-path)
runtime_path=$(swift -print-target-info | sed -n 's/.*"runtimeResourcePath": "\(.*\)".*/\1/p')
test_helper="${runtime_path%/lib/swift}/libexec/swift/pm/swiftpm-testing-helper"
platform=$(xcrun --sdk macosx --show-sdk-platform-path)

# Hardened toolchain launchers can strip DYLD_INSERT_LIBRARIES. Launch the test
# helper directly, with the same Swift Testing and XCTest paths as SwiftPM.
for target in SlateUITests SlateTerminalTests SlateGraphicsDemoTests; do
  SLATE_ALLOCATION_PROBE=1 DYLD_INSERT_LIBRARIES="$probe_library" \
    DYLD_LIBRARY_PATH="$runtime_path/macosx/testing:$platform/Developer/usr/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
    DYLD_FRAMEWORK_PATH="$platform/Developer/Library/Frameworks${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}" \
    "$test_helper" --test-bundle-path "$products/$target.xctest/Contents/MacOS/$target" \
      --testing-library swift-testing --filter Allocation
done
