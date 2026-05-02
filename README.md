# Slate

Simple, fast terminal rendering.

## SlateDemo

```bash
swift run SlateDemo
```

A simple demo that simulates LLM text output on top of a constantly changing background.

Ctrl-C or Ctrl-D exits; the terminal is restored afterward.

## Code coverage

**macOS** (uses `xcrun llvm-cov`; `-arch` must match the test binary, e.g. Apple Silicon `arm64` vs Intel `x86_64`):

```bash
swift test --enable-code-coverage
BIN="$(find .build -type f -path '*/debug/slatePackageTests.xctest/Contents/MacOS/slatePackageTests' | head -n 1)"
PROF="$(find .build -path '*/codecov/default.profdata' | head -n 1)"
xcrun llvm-cov report "$BIN" \
  -instr-profile="$PROF" \
  -arch "$(uname -m)" \
  --ignore-filename-regex='/Tests/' \
  --ignore-filename-regex='\.build/checkouts/' \
  --ignore-filename-regex='/Sources/SlateDemo/' \
  --ignore-filename-regex='BasicContainers' \
  --ignore-filename-regex='ContainersPreview' \
  --ignore-filename-regex='InternalCollectionsUtilities' \
  --ignore-filename-regex='\.derived/'
```

**Linux** (`llvm-cov` on `PATH`; no `-arch`):

```bash
swift test --enable-code-coverage
BIN="$(find .build -type f \( -path '*/debug/slatePackageTests.xctest/**/slatePackageTests' -o -path '*/debug/slatePackageTests' \) ! -path '*dSYM*' | head -n 1)"
PROF="$(find .build -path '*/codecov/default.profdata' | head -n 1)"
llvm-cov report "$BIN" \
  -instr-profile="$PROF" \
  --ignore-filename-regex='/Tests/' \
  --ignore-filename-regex='\.build/checkouts/' \
  --ignore-filename-regex='BasicContainers' \
  --ignore-filename-regex='ContainersPreview' \
  --ignore-filename-regex='InternalCollectionsUtilities' \
  --ignore-filename-regex='\.derived/'
```

Omit the `--ignore-filename-regex=…` lines to include tests and all dependencies in the report.
