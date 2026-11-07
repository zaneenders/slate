# Benchmarks

Standalone Linux/Glibc package; requires Swift 6.4.2.

```sh
swift run --package-path Benchmarks -c release slate-benchmark
```

`slate-benchmark` measures Layer 1 cell rendering, editing, and region
presentation. Its allocator hooks link only into this standalone executable.
It calibrates both C and Swift allocation tracking before checking that the
measured workloads allocate no storage after runtime warm-up.

Region checks exercise redraws at capacity, viewport clipping, movement,
clearing, all 48 layout slots, text and node exhaustion, oversized regions, and
failed output/recovery. Invalid size/layout requests leave the old region owned
and produce no output. Region storage never grows.

`SlateUI.Surface` renders cells without terminal I/O. Its independent allocation
check exercises the maximum grid and layout node count, borrowed cell access,
empty frames, viewport/text/node exhaustion, raw host clipboard delivery, and
copy overflow. This check runs outside the timed workload so paired comparisons
retain identical work.

For paired profiling, build both revisions with Swift 6.4.2 and `-c release`,
retain each executable, and alternate before/after runs on the same idle host.
Compare the median across at least three alternating pairs. Exclude runtime
initialization and build time. Blocking descriptor latency and terminal-side
rendering are outside these CPU and allocation checks.

Run `swift test` from the repository root for exact cell/style/ANSI output,
clipping, exhaustion, clipboard delivery, signal handling,
and partial-write recovery checks.

The optional [graphics transport workload](../../slate-high-res/GraphicsBenchmarks/README.md)
has moved out of this package. Historical totals that included that workload
cannot be compared directly with Layer 1 totals; compare matching fixtures.
