import Testing

@testable import SlateCore

// MARK: - Grid encoding benchmarks

@Suite(.serialized) struct Benchmarks {
  private static let terminalSizes: [(cols: Int, rows: Int, label: String)] = [
    (80, 24, "80x24"),
    (143, 38, "143x38"),
    (200, 60, "200x60"),
  ]

  // MARK: Full redraw (every row dirty)

  @Test(arguments: terminalSizes)
  func fullRedrawAllCells(_ size: (cols: Int, rows: Int, label: String)) {
    let fill = TerminalCell(glyph: " ", foreground: .white, background: .black, flags: [])
    let (us, bytes) = benchmarkEncode(cols: size.cols, rows: size.rows, fill: fill) { grid in
      for y in 0..<size.rows {
        for x in 0..<size.cols {
          grid[column: x, row: y] = TerminalCell(
            glyph: Character(UnicodeScalar(0x41 &+ UInt8((x &+ y) % 26))),
            foreground: TerminalRGB(r: UInt8(x % 256), g: UInt8(y % 256), b: 128),
            background: .black,
            flags: (x &+ y) % 3 == 0 ? .bold : [])
        }
      }
    }
    let cellsPerMs = Double(size.cols &* size.rows) / (us / 1_000)
    bench(
      "full-redraw \(size.label)",
      "\(f1(us))us/frame",
      "\(f1(Double(bytes) / 1024))KB",
      "\(Int(cellsPerMs / 1_000))M cells/s")
    #expect(us < 50_000)
    #expect(bytes > 0)
  }

  // MARK: Dirty-region (only a few rows changed)

  @Test(arguments: terminalSizes)
  func dirtyRegionFewRows(_ size: (cols: Int, rows: Int, label: String)) {
    let fill = TerminalCell(glyph: " ", foreground: .white, background: .black, flags: [])
    let dirtyRowCount = min(8, size.rows)
    let (us, bytes) = benchmarkEncode(cols: size.cols, rows: size.rows, fill: fill) { grid in
      for y in 0..<dirtyRowCount {
        for x in 0..<size.cols {
          grid[column: x, row: y] = TerminalCell(
            glyph: Character(UnicodeScalar(0x61 &+ UInt8(x % 26))),
            foreground: TerminalRGB(r: UInt8(x % 256), g: UInt8(y % 256), b: 200),
            background: .black,
            flags: [])
        }
      }
    }
    bench(
      "dirty-region \(size.label) (\(dirtyRowCount) rows)",
      "\(f1(us))us/frame",
      "\(f1(Double(bytes) / 1024))KB")
    #expect(us < 10_000)
    #expect(bytes > 0)
  }

  // MARK: Idle frame (single-cell cursor blink)

  @Test(arguments: terminalSizes)
  func idleFrameCursorBlink(_ size: (cols: Int, rows: Int, label: String)) {
    let fill = TerminalCell(glyph: " ", foreground: .white, background: .black, flags: [])
    let (us, bytes) = benchmarkEncode(cols: size.cols, rows: size.rows, fill: fill) { grid in
      let row = size.rows &- 2
      grid[column: 5, row: row] = TerminalCell(
        glyph: "\u{258F}", foreground: .white, background: TerminalRGB(r: 44, g: 40, b: 54), flags: [])
    }
    bench(
      "idle-frame \(size.label)",
      "\(f1(us))us/frame",
      "\(bytes)B")
    #expect(us < 1_000)
    #expect(bytes > 0 && bytes < 500)  // CUP + SGR overhead grows with row number
  }

  @Test func blitFullRectangle() {
    let cols = 143
    let rows = 38
    var grid = TerminalCellGrid(
      cols: cols, rows: rows,
      filling: TerminalCell(glyph: " ", foreground: .white, background: .black, flags: []))
    let fill = TerminalCell(glyph: "X", foreground: .cyan, background: .black, flags: [])

    let us = benchmark(iterations: 500) {
      grid.blit(column: 0, row: 0, width: cols, height: rows, repeating: fill)
    }
    let cellsPerMs = Double(cols &* rows) / (us / 1_000)
    bench("blit \(cols)x\(rows)", "\(f1(us))us", "\(Int(cellsPerMs / 1_000))M cells/s")
    #expect(us < 5_000)
  }

  @Test func blitSpansThroughput() {
    let cols = 143
    var grid = TerminalCellGrid(
      cols: cols, rows: 1,
      filling: TerminalCell(glyph: " ", foreground: .white, background: .black, flags: []))
    let spans: [TerminalStyledSpan] = (0..<10).map { i in
      TerminalStyledSpan(
        String(repeating: "x", count: min(15, cols / 10)),
        foreground: TerminalRGB(r: UInt8(i * 25), g: 128, b: 200),
        background: .black, flags: [])
    }

    let us = benchmark(iterations: 500) {
      grid.blitSpans(column: 0, row: 0, maxWidth: cols, spans)
    }
    bench("blitSpans \(cols)cols", "\(f1(us))us")
    #expect(us < 500)
  }

  @Test func blitTextThroughput() {
    let cols = 143
    var grid = TerminalCellGrid(
      cols: cols, rows: 1,
      filling: TerminalCell(glyph: " ", foreground: .white, background: .black, flags: []))
    let text = String(repeating: "Hello World! ", count: cols / 13)

    let us = benchmark(iterations: 500) {
      grid.blitText(column: 0, row: 0, string: text, foreground: .white, background: .black)
    }
    bench("blitText \(cols)cols", "\(f1(us))us")
    #expect(us < 1_000)
  }

  @Test func decodeAsciiBurst() {
    let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 20)
    let bytes = ContiguousArray(text.utf8)

    let us = benchmark(iterations: 200) {
      var decoder = TerminalKeyDecoder()
      decoder.decode(bytes) { _ in }
    }
    bench("key-decode ascii-burst \(bytes.count)B", "\(f1(us))us")
    #expect(us < 5_000)
  }

  @Test func decodeCSIMix() {
    let chunks: [[UInt8]] = (0..<20).map { _ in
      [
        0x1B, 0x5B, 0x41,  // ArrowUp
        0x1B, 0x5B, 0x42,  // ArrowDown
        0x1B, 0x5B, 0x35, 0x7E,  // PageUp
        0x68, 0x65, 0x6C, 0x6C, 0x6F,
      ]  // "hello"
    }

    let us = benchmark(iterations: 100) {
      var decoder = TerminalKeyDecoder()
      for chunk in chunks {
        decoder.decode(ContiguousArray(chunk)) { _ in }
      }
    }
    let totalBytes = chunks.reduce(0) { $0 + $1.count }
    bench("key-decode csi-mix \(totalBytes)B", "\(f1(us))us")
    #expect(us < 10_000)
  }

  @Test func resizeGrowToSize() {
    let fill = TerminalCell(glyph: " ", foreground: .white, background: .black, flags: [])

    // 80x24 → 143x38 (small → medium)
    let us = benchmark(iterations: 500) {
      var grid = TerminalCellGrid(cols: 80, rows: 24, filling: fill)
      grid.resize(cols: 143, rows: 38, filling: fill)
    }
    bench("resize-grow 80x24→143x38", "\(f1(us))us")
    #expect(us < 1_000)
  }

  @Test func resizeShrinkFromLarge() {
    let fill = TerminalCell(glyph: " ", foreground: .white, background: .black, flags: [])

    // 200x60 → 80x24 (large → small)
    let us = benchmark(iterations: 500) {
      var grid = TerminalCellGrid(cols: 200, rows: 60, filling: fill)
      grid.resize(cols: 80, rows: 24, filling: fill)
    }
    bench("resize-shrink 200x60→80x24", "\(f1(us))us")
    #expect(us < 1_000)
  }

  @Test func resizeRegrowToLarge() {
    let fill = TerminalCell(glyph: " ", foreground: .white, background: .black, flags: [])

    // 80x24 → 200x60 (small → large, biggest gap)
    let us = benchmark(iterations: 500) {
      var grid = TerminalCellGrid(cols: 80, rows: 24, filling: fill)
      grid.resize(cols: 200, rows: 60, filling: fill)
    }
    bench("resize-regrow 80x24→200x60", "\(f1(us))us")
    #expect(us < 1_000)
  }
}

// MARK: - Benchmark helpers

/// Formats a Double to 1 decimal place without String(format:).
private func f1(_ d: Double) -> String {
  let rounded = (d * 10).rounded() / 10
  // Simple formatting: integer part . decimal
  let intPart = Int(rounded)
  let decPart = Int((rounded - Double(intPart)) * 10 + 0.5)
  return "\(intPart).\(decPart)"
}

/// Text-only label for benchmark identification — avoids String(format:).
private func bench(_ label: String, _ metrics: String...) {
  print("[BENCH] \(label): \(metrics.joined(separator: " "))")
}

/// Runs `iterations` calls of `body` and returns average microseconds per call.
private func benchmark(iterations: Int = 1000, _ body: () -> Void) -> Double {
  let clock = ContinuousClock()
  // Warm-up
  for _ in 0..<5 { body() }
  let elapsed = clock.measure {
    for _ in 0..<iterations { body() }
  }
  let us = Double(elapsed.components.attoseconds) / 1_000_000_000_000 / Double(iterations)
  return us
}

/// Returns (average_us, total_bytes_encoded).
private func benchmarkEncode(
  iterations: Int = 1000,
  cols: Int, rows: Int,
  fill: TerminalCell,
  painter: (inout TerminalCellGrid) -> Void
) -> (us: Double, bytes: Int) {
  var grid = TerminalCellGrid(cols: cols, rows: rows, filling: fill)
  painter(&grid)
  var buffer = TerminalByteBuffer(capacity: cols &* rows &* 54 &+ 640)

  // Warm-up: encode once so dirty flags are set correctly
  grid.encode(into: &buffer)
  painter(&grid)

  let clock = ContinuousClock()
  var totalBytes = 0
  let elapsed = clock.measure {
    for _ in 0..<iterations {
      grid.encode(into: &buffer)
      totalBytes += buffer.count
      painter(&grid)
    }
  }
  let us = Double(elapsed.components.attoseconds) / 1_000_000_000_000 / Double(iterations)
  return (us, totalBytes / iterations)
}
