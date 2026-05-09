# Benchmarking & Regression Detection

Slate uses the [swift-collections-benchmark][scb] framework for micro-benchmarks
and [swift-profile-recorder][spr] for statistical profiling.  A committed
baseline lets any branch diff its performance against `main` in one command.

The `BenchRunner` executable (written in Swift) orchestrates everything:
running benchmarks, comparing against the baseline, and detecting regressions
— no shell scripting involved.

[scb]: https://github.com/apple/swift-collections-benchmark
[spr]: https://github.com/apple/swift-profile-recorder

## Quick start — check for regressions

```bash
swift run -c release BenchRunner
```

This builds and runs all benchmarks, then compares the results against the
committed baseline at `Benchmarks/Baselines/main.json`.  If any task regressed
more than 10% it exits with a non-zero status and prints the culprit.

## Updating the baseline

After a deliberate change that shifts performance (or after adding new
benchmarks), update the baseline on `main`:

```bash
swift run -c release BenchRunner save
git add Benchmarks/Baselines/main.json
git commit -m "Update benchmark baseline"
```

## Listing available tasks

```bash
swift run -c release BenchRunner list
```

## Running a single task

```bash
swift run -c release SlateBenchmarks run /tmp/one.json \
  --mode replace-all --cycles 10 \
  --tasks "Grid.encode full-redraw" \
  --sizes 1 --sizes 2000 --sizes 10000
```

## Understanding the comparison output

```
  Task                                               Geomean  Per-size ratios
  ────────────────────────────────────────────────   ───────  ──────────────
  Grid.blit full rectangle                       ✓   0.982   1:0.960 2000:0.930 10000:0.931
  Grid.encode 0 dirty rows (skip-all)            ✗   1.131   1:1.352 2000:1.078 10000:1.242
```

| Column | Meaning |
|---|---|
| **Task** | Benchmark name with ✓ (ok) or ✗ (regressed) |
| **Geomean** | Geometric mean of new/baseline ratios across all sizes (1.0 = identical) |
| **Per-size ratios** | Individual `size:ratio` ratios for diagnosing which sizes shifted |

A task is flagged (✗) when the **geometric mean** across all sizes exceeds 1.10
(>10% slower than baseline overall). Using the geometric mean dampens single-size
measurement noise — a task that's noisy at one size but fine at others won't
falsely flag.

## Porting to another Swift project

1. **Add the dependency** to `Package.swift`:
   ```swift
   .package(url: "https://github.com/apple/swift-collections-benchmark.git", from: "0.0.4"),
   ```

2. **Create a benchmark target** under `Benchmarks/`:
   ```swift
   .executableTarget(
     name: "MyBenchmarks",
     dependencies: [
       "MyLib",
       .product(name: "CollectionsBenchmark", package: "swift-collections-benchmark"),
     ],
     path: "Benchmarks/MyBenchmarks",
     swiftSettings: [.unsafeFlags(["-O"])]),
   ```

3. **Define benchmarks** following the pattern in
   `Benchmarks/SlateBenchmarks/SlateBenchmarks.swift` —
   `registerInputGenerator` + `add`/`addSimple`.

4. **Generate and commit a baseline**:
   ```bash
   swift run -c release MyBenchmarks run Baselines/main.json \
     --mode replace-all --cycles 5 --sizes 1 --sizes 1000 --sizes 10000
   git add Baselines/main.json && git commit -m "Add benchmark baseline"
   ```

5. **Add a `BenchRunner` target** (see `Benchmarks/BenchRunner/main.swift`)
   to get the same `swift run BenchRunner` / `swift run BenchRunner save`
   workflow. Adjust the constants at the top of the file for your target
   name, sizes, and baseline path.

## CI integration (GitHub Actions example)

```yaml
benchmarks:
  runs-on: macos-15
  steps:
    - uses: actions/checkout@v4
    - name: Check for regressions
      run: swift run -c release BenchRunner
```

Because the baseline is committed to the repo, the CI job naturally diffs the
PR against `main`'s last committed baseline.

## Benchmarks reference

| Benchmark | What it measures |
|---|---|
| `Grid.encode full-redraw` | Full 80×24 / 143×38 / 200×60 encode with all rows dirty |
| `Grid.encode dirty-region 8 rows` | Partial update (8 dirty rows) |
| `Grid.encode idle-frame 1 cell` | Single-cell cursor blink |
| `Grid.encode 0 dirty rows (skip-all)` | Early-exit path when nothing changed |
| `Grid.blit full rectangle` | Bulk cell fill via `blit(repeating:)` |
| `Grid.blitText single row` | `blitText` with a wide ASCII string |
| `Grid.blitSpans 3-span row (array)` | Styled-span rendering via array |
| `Grid.blitSpans 3-span row (variadic)` | Styled-span rendering via variadic |
| `Grid.resize grow to size` | Resize from 80×24 up to terminal size |
| `Grid.resize shrink from 200×60` | Resize from 200×60 down to terminal size |
| `Grid.resize regrow to 200×60` | Resize from terminal size up to 200×60 |
| `KeyDecoder kitty/xterm/arrow` | CSI escape sequence decoding |
| `KeyDecoder ASCII burst` | Plain ASCII decode throughput |
| `KeyDecoder CSI mix` | Mixed CSI + ASCII decode |
| `InputHandler 7-char type` | Full input pipeline (decode + buffer) |
| `InputHandler Enter` | Enter key through the full pipeline |
| `LLM stream: 10×blitText + encode` | Simulated LLM token streaming |
| `LLM: encode pre-painted (50% rows dirty)` | Encode-only with half the grid dirty |
