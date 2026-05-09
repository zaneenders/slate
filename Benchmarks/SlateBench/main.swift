import SlateCore

// MARK: - Benchmark harness

/// Runs `block` `iterations` times and returns the mean duration.
/// Discards the first `warmup` iterations to prime caches / JIT.
@discardableResult
func benchmark(
  name: String,
  iterations: Int = 100,
  warmup: Int = 3,
  _ block: () -> Void
) -> Duration {
  for _ in 0..<warmup { block() }
  var total = Duration.zero
  let clock = ContinuousClock()
  for _ in 0..<iterations {
    let elapsed = clock.measure(block)
    total += elapsed
  }
  let mean = total / iterations
  let ns = Double(mean.components.attoseconds) / 1_000_000_000
  let us = ns / 1_000
  let ms = us / 1_000
  print("  \(name): \(ms >= 1 ? String(format: "%.2f ms", ms) : us >= 1 ? String(format: "%.1f µs", us) : String(format: "%.0f ns", ns))")
  return mean
}

// MARK: - Fixtures

/// 80×24 terminal — the classic default.
let cols = 80, rows = 24
let cellCount = cols * rows

/// Pre-built default cell.
let defaultCell = TerminalCell.defaultCell

// MARK: - Benchmarks

print("=== Slate Core Benchmarks (80×24 grid, \(cellCount) cells) ===\n")

// ── Grid reset ──────────────────────────────────────────────────────

var grid = TerminalCellGrid(cols: cols, rows: rows, filling: defaultCell)
benchmark(name: "grid.reset(filling:)") {
  grid.reset(filling: defaultCell)
}

// ── blit (full grid fill) ───────────────────────────────────────────

grid.reset(filling: defaultCell)
let mark = TerminalCell(glyph: "#", foreground: .white, background: .red, flags: [.bold])
benchmark(name: "blit(repeating:) full grid") {
  grid.blit(column: 0, row: 0, width: cols, height: rows, repeating: mark)
}

// ── blitText ────────────────────────────────────────────────────────

grid.reset(filling: defaultCell)
let sampleText = String(repeating: "Hello World! ", count: cols / 13 + 1)
benchmark(name: "blitText 80-char row") {
  grid.blitText(column: 0, row: 1, string: sampleText, foreground: .green, background: .black)
}

// ── blitSpans (variadic) ────────────────────────────────────────────

grid.reset(filling: defaultCell)
benchmark(name: "blitSpans 3-span row (variadic)") {
  grid.blitSpans(
    column: 0, row: 1, maxWidth: cols,
    TerminalStyledSpan("[", foreground: .gray, background: .black),
    TerminalStyledSpan("status", foreground: .cyan, background: .black, flags: [.bold]),
    TerminalStyledSpan("] message", foreground: .white, background: .black))
}

// ── blitSpans (generic, array) ──────────────────────────────────────

grid.reset(filling: defaultCell)
let spans: [TerminalStyledSpan] = [
  TerminalStyledSpan("[", foreground: .gray, background: .black),
  TerminalStyledSpan("status", foreground: .cyan, background: .black, flags: [.bold]),
  TerminalStyledSpan("] message", foreground: .white, background: .black),
]
benchmark(name: "blitSpans 3-span row (array)") {
  grid.blitSpans(column: 0, row: 1, maxWidth: cols, spans)
}

// ── encode (full dirty grid) ────────────────────────────────────────

var buf = TerminalByteBuffer(capacity: 4096)
do {
  var g = TerminalCellGrid(cols: cols, rows: rows, filling: defaultCell)
  // All rows start dirty from init.
  benchmark(name: "encode(into:) full dirty grid") {
    g.encode(into: &buf)
    // Re-dirty all rows for next iteration (encode clears them).
    g.reset(filling: defaultCell)
  }
}

// ── encode (1 dirty row) ────────────────────────────────────────────

do {
  var g = TerminalCellGrid(cols: cols, rows: rows, filling: defaultCell)
  g.encode(into: &buf)  // clear initial dirty
  benchmark(name: "encode(into:) 1 dirty row") {
    g.blitText(column: 0, row: 5, string: sampleText, foreground: .white, background: .black)
    g.encode(into: &buf)
  }
}

// ── encode (0 dirty rows) ───────────────────────────────────────────

do {
  var g = TerminalCellGrid(cols: cols, rows: rows, filling: defaultCell)
  g.encode(into: &buf)  // clear all dirty flags
  benchmark(name: "encode(into:) 0 dirty rows (skip-all)") {
    g.encode(into: &buf)
  }
}

// ── Grid resize ─────────────────────────────────────────────────────

benchmark(name: "grid.resize(cols:rows:) 80→120×24→36") {
  var g = TerminalCellGrid(cols: 80, rows: 24, filling: defaultCell)
  g.resize(cols: 120, rows: 36, filling: defaultCell)
}

// ── TerminalKeyDecoder (public API) ─────────────────────────────────

var decoder = TerminalKeyDecoder()
let kittyEnterBytes: ContiguousArray<UInt8> = [0x1B, 0x5B, 0x31, 0x33, 0x3B, 0x32, 0x75]
let xtermEnterBytes: ContiguousArray<UInt8> = [0x1B, 0x5B, 0x32, 0x37, 0x3B, 0x32, 0x3B, 0x31, 0x33, 0x7E]
let simpleArrowBytes: ContiguousArray<UInt8> = [0x1B, 0x5B, 0x41]
let characterChunk: ContiguousArray<UInt8> = ContiguousArray("Hello, World! This is a test of keyboard input.".utf8)

benchmark(name: "KeyDecoder kitty Shift+Enter", iterations: 500) {
  var d = decoder
  d.decode(kittyEnterBytes) { _ in }
}
benchmark(name: "KeyDecoder xterm Shift+Enter", iterations: 500) {
  var d = decoder
  d.decode(xtermEnterBytes) { _ in }
}
benchmark(name: "KeyDecoder arrow (no-params)", iterations: 500) {
  var d = decoder
  d.decode(simpleArrowBytes) { _ in }
}
benchmark(name: "KeyDecoder 48-char ASCII", iterations: 500) {
  var d = decoder
  d.decode(characterChunk) { _ in }
}

// ── TerminalInputHandler (full stack: decode + buffer mutate) ───────

var handler = TerminalInputHandler()
let typingChunk = ContiguousArray("Hello, ".utf8)
benchmark(name: "InputHandler 7-char type", iterations: 500) {
  var h = handler
  _ = h.handle(typingChunk)
}
let enterChunk: ContiguousArray<UInt8> = [13]
benchmark(name: "InputHandler Enter", iterations: 500) {
  var h = handler
  _ = h.handle(enterChunk)
}

print("\n=== Done ===")
