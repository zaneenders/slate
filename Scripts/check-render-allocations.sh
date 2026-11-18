#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

probe_directory=$(mktemp -d "${TMPDIR:-/tmp}/slate-render-allocations.XXXXXX")
trap 'rm -rf "$probe_directory"' EXIT HUP INT TERM
case "$(uname -s)" in
  Darwin)
    probe_library="$probe_directory/libSlateAllocationProbe.dylib"
    xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -dynamiclib -mmacosx-version-min=27.0 \
      Tests/CAllocationProbe/AllocationProbe.c -o "$probe_library"
    ;;
  Linux)
    probe_library="$probe_directory/libSlateAllocationProbe.so"
    cc -std=c11 -O2 -Wall -Wextra -Werror -fPIC -shared \
      Tests/CAllocationProbe/LinuxAllocationProbe.c -o "$probe_library" -ldl -pthread
    ;;
  *)
    echo "The render allocation probe requires macOS or glibc Linux." >&2
    exit 1
    ;;
esac

# The allocation guarantee covers optimized builds. Build before injection so
# compiler/SwiftPM work is outside the probe process; the probe test skips here.
SLATE_ALLOCATION_PROBE=0 swift test -c release --filter Allocation

if [ "$(uname -s)" = Linux ]; then
  # Isolate each suite so Swift Testing cannot start concurrent process-wide
  # measurements, including toolchains that link all targets into one runner.
  for filter in RenderAllocationTests terminalColorAllocation bufferedOutputAllocation nativeBackpressureAllocation graphicsDragAllocation gamepadAllocation keyboardDemoAllocation; do
    SLATE_ALLOCATION_PROBE=1 LD_PRELOAD="$probe_library${LD_PRELOAD:+:$LD_PRELOAD}" \
      swift test -c release --skip-build --filter "$filter"
  done
  exit 0
fi

products=$(swift build -c release --show-bin-path)
runtime_path=$(swift -print-target-info | sed -n 's/.*"runtimeResourcePath": "\(.*\)".*/\1/p')
test_helper="${runtime_path%/lib/swift}/libexec/swift/pm/swiftpm-testing-helper"
if platform=$(xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null); then
  testing_libraries="$platform/Developer/usr/lib"
  testing_frameworks="$platform/Developer/Library/Frameworks"
else
  # Command Line Tools ships Testing without an Xcode platform directory.
  developer_support="$(xcode-select -p)/Library/Developer"
  testing_libraries="$developer_support/usr/lib"
  testing_frameworks="$developer_support/Frameworks"
fi

# Hardened toolchain launchers can strip DYLD_INSERT_LIBRARIES. Launch the test
# helper directly, with the same Swift Testing and XCTest paths as SwiftPM.
for target in SlateUITests SlateTerminalTests SlateGraphicsDemoTests SlateGamepadTests SlateKeyboardDemoTests; do
  SLATE_ALLOCATION_PROBE=1 DYLD_INSERT_LIBRARIES="$probe_library" \
    DYLD_LIBRARY_PATH="$runtime_path/macosx/testing:$testing_libraries${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
    DYLD_FRAMEWORK_PATH="$testing_frameworks${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}" \
    "$test_helper" --test-bundle-path "$products/$target.xctest/Contents/MacOS/$target" \
      --testing-library swift-testing --no-parallel --filter Allocation
done
