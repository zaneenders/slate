# Performance

Slate uses [swift-collections-benchmark][scb] for micro-benchmarks and
[swift-profile-recorder][spr] for in-process statistical profiling. A committed
baseline lets any branch diff its performance against `main` in one command.

The `BenchRunner` executable (written in Swift) orchestrates everything:
running benchmarks, comparing against the baseline, and detecting regressions
— no shell scripting involved.

[scb]: https://github.com/apple/swift-collections-benchmark
[spr]: https://github.com/apple/swift-profile-recorder

---

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

---

## Profiling the demo

The `SlateDemo` executable includes an in-process sampling profiler via
[swift-profile-recorder][spr]. It runs in the background and exposes a UNIX
domain socket that you can query with `curl` to capture CPU profiles — no
kernel privileges or external tools needed.

### 1. Start the demo with profiling enabled

Set the `PROFILE_RECORDER_SERVER_URL_PATTERN` environment variable before
launching the demo. The `{PID}` placeholder is replaced with the process ID:

```bash
PROFILE_RECORDER_SERVER_URL_PATTERN='unix:///tmp/slate-samples-{PID}.sock' \
  swift run -c release SlateDemo
```

The demo runs normally; the profiler is idle until you request samples.

### 2. Capture a profile

While the demo is running, use `curl` to request samples via the socket. The
PID is printed at startup, or find it with `pgrep SlateDemo`:

```bash
# Capture 500 samples at 10 ms intervals (~5 seconds of profiling)
curl -sd '{"numberOfSamples":500,"timeInterval":"10 ms"}' \
  --unix-socket /tmp/slate-samples-<PID>.sock \
  http://unix/sample | swift demangle --simplified > /tmp/samples.perf
```

| Parameter | Description |
|---|---|
| `numberOfSamples` | How many stack samples to collect |
| `timeInterval` | Time between samples (e.g. `"10 ms"`, `"1 ms"`) |

### 3. Visualize the profile

Drag `/tmp/samples.perf` onto either:

- [Firefox Profiler](https://profiler.firefox.com) — recommended, supports the
  Linux `perf script` format that `swift-profile-recorder` emits
- [Speedscope](https://speedscope.app) — lighter-weight alternative

### 4. How it works

`SlateDemoEntry` starts the profile recorder server on a background task at
launch time (see `Sources/SlateDemo/SlateDemoEntry.swift`). It reads its
configuration from the environment — if `PROFILE_RECORDER_SERVER_URL_PATTERN`
is unset, the server exits silently and the demo runs with zero overhead.
The profiling has no measurable impact on the demo unless you explicitly
request samples.

---

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
