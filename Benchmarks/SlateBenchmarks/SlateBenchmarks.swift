import CollectionsBenchmark
import SlateCore

// MARK: - Terminal-size input type

/// A named terminal size that drives benchmark input generation.
struct TerminalSize: Hashable, Sendable {
  let cols: Int
  let rows: Int

  static let standard80x24 = TerminalSize(cols: 80, rows: 24)
  static let medium143x38 = TerminalSize(cols: 143, rows: 38)
  static let large200x60 = TerminalSize(cols: 200, rows: 60)

  var cellCount: Int { cols * rows }

  /// Encode capacity matching `slateRedrawEncodeCapacity`.
  var encodeCapacity: Int { rows &* cols &* 54 &+ rows &* 32 &+ 640 }
}

// MARK: - Custom input generators

extension Benchmark {
  mutating func registerSlateGenerators() {
    // Map benchmark "size" (Int) to terminal dimensions
    self.registerInputGenerator(for: TerminalSize.self) { size in
      switch size {
      case 0..<1500: return .standard80x24
      case 1500..<5000: return .medium143x38
      default: return .large200x60
      }
    }
  }
}

// MARK: - Grid helper

/// Create a fully-painted grid with varied styles, then encode once
/// to clear initial dirty flags so benchmarks start clean.
private func makeCleanGrid(size ts: TerminalSize) -> TerminalCellGrid {
  var grid = TerminalCellGrid(
    cols: ts.cols, rows: ts.rows,
    filling: TerminalCell(glyph: " ", foreground: .white, background: .black, flags: []))
  for y in 0..<ts.rows {
    for x in 0..<ts.cols {
      grid[column: x, row: y] = TerminalCell(
        glyph: Character(UnicodeScalar(0x41 &+ UInt8((x &+ y) % 26))),
        foreground: TerminalRGB(r: UInt8(x % 256), g: UInt8(y % 256), b: 128),
        background: .black,
        flags: (x &+ y) % 3 == 0 ? .bold : [])
    }
  }
  var buf = TerminalByteBuffer(capacity: ts.encodeCapacity)
  grid.encode(into: &buf)
  return grid
}

/// Create a blank single-row grid for blitText/blitSpans benchmarks.
private func makeSingleRowGrid(size ts: TerminalSize) -> TerminalCellGrid {
  TerminalCellGrid(
    cols: ts.cols, rows: 1,
    filling: TerminalCell(glyph: " ", foreground: .white, background: .black, flags: []))
}

// MARK: - Benchmark definitions

extension Benchmark {

  public mutating func addSlateBenchmarks() {

    // ── Grid Encode ──────────────────────────────────────────────────

    self.add(
      title: "Grid.encode full-redraw",
      input: TerminalSize.self
    ) { ts in
      let capacity = ts.encodeCapacity
      return { timer in
        var g = makeCleanGrid(size: ts)
        g.reset(filling: .defaultCell)  // re-dirty all rows
        var buf = TerminalByteBuffer(capacity: capacity)
        timer.measure {
          g.encode(into: &buf)
        }
        blackHole(buf.count)
      }
    }

    self.add(
      title: "Grid.encode dirty-region 8 rows",
      input: TerminalSize.self
    ) { ts in
      let capacity = ts.encodeCapacity
      return { timer in
        var g = makeCleanGrid(size: ts)
        let dirtyCount = Swift.min(8, ts.rows)
        for y in 0..<dirtyCount {
          g[column: 0, row: y] = g[column: 0, row: y]
        }
        var buf = TerminalByteBuffer(capacity: capacity)
        timer.measure {
          g.encode(into: &buf)
        }
        blackHole(buf.count)
      }
    }

    self.add(
      title: "Grid.encode idle-frame 1 cell",
      input: TerminalSize.self
    ) { ts in
      let capacity = ts.encodeCapacity
      let row = ts.rows &- 2
      return { timer in
        var g = makeCleanGrid(size: ts)
        g[column: 5, row: row] = TerminalCell(
          glyph: "\u{258F}", foreground: .white,
          background: TerminalRGB(r: 44, g: 40, b: 54), flags: [])
        var buf = TerminalByteBuffer(capacity: capacity)
        timer.measure {
          g.encode(into: &buf)
        }
        blackHole(buf.count)
      }
    }

    self.add(
      title: "Grid.encode 0 dirty rows (skip-all)",
      input: TerminalSize.self
    ) { ts in
      let capacity = ts.encodeCapacity
      return { timer in
        var g = makeCleanGrid(size: ts)  // already clean from makeCleanGrid
        var buf = TerminalByteBuffer(capacity: capacity)
        timer.measure {
          g.encode(into: &buf)
        }
        blackHole(buf.count)
      }
    }

    // ── Grid Blit ────────────────────────────────────────────────────

    self.add(
      title: "Grid.blit full rectangle",
      input: TerminalSize.self
    ) { ts in
      let mark = TerminalCell(
        glyph: "#", foreground: .white, background: .red, flags: [.bold])
      return { timer in
        var g = TerminalCellGrid(
          cols: ts.cols, rows: ts.rows, filling: .defaultCell)
        timer.measure {
          g.blit(column: 0, row: 0, width: ts.cols, height: ts.rows, repeating: mark)
        }
      }
    }

    self.add(
      title: "Grid.blitText single row",
      input: TerminalSize.self
    ) { ts in
      let text = String(repeating: "Hello World! ", count: max(1, ts.cols / 13))
      return { timer in
        var g = makeSingleRowGrid(size: ts)
        timer.measure {
          g.blitText(
            column: 0, row: 0, string: text,
            foreground: .green, background: .black)
        }
      }
    }

    self.add(
      title: "Grid.blitSpans 3-span row (array)",
      input: TerminalSize.self
    ) { ts in
      let spans: [TerminalStyledSpan] = [
        TerminalStyledSpan("[", foreground: .gray, background: .black),
        TerminalStyledSpan("status", foreground: .cyan, background: .black, flags: [.bold]),
        TerminalStyledSpan("] message", foreground: .white, background: .black),
      ]
      return { timer in
        var g = makeSingleRowGrid(size: ts)
        timer.measure {
          g.blitSpans(column: 0, row: 0, maxWidth: ts.cols, spans)
        }
      }
    }

    self.add(
      title: "Grid.blitSpans 3-span row (variadic)",
      input: TerminalSize.self
    ) { ts in
      return { timer in
        var g = makeSingleRowGrid(size: ts)
        timer.measure {
          g.blitSpans(
            column: 0, row: 0, maxWidth: ts.cols,
            TerminalStyledSpan("[", foreground: .gray, background: .black),
            TerminalStyledSpan("status", foreground: .cyan, background: .black, flags: [.bold]),
            TerminalStyledSpan("] message", foreground: .white, background: .black))
        }
      }
    }

    // ── Grid Resize ──────────────────────────────────────────────────

    self.addSimple(
      title: "Grid.resize 80→120 × 24→36",
      input: Int.self
    ) { _ in
      var g = TerminalCellGrid(cols: 80, rows: 24, filling: .defaultCell)
      g.resize(cols: 120, rows: 36, filling: .defaultCell)
      blackHole(g.cols)
    }

    self.add(
      title: "Grid.resize + full encode",
      input: TerminalSize.self
    ) { ts in
      let capacity = ts.encodeCapacity
      return { timer in
        var g = TerminalCellGrid(cols: ts.cols, rows: ts.rows, filling: .defaultCell)
        var buf = TerminalByteBuffer(capacity: capacity)
        timer.measure {
          g.encode(into: &buf)
        }
        blackHole(buf.count)
      }
    }

    // ── Key Decoder ──────────────────────────────────────────────────

    let kittyEnter: ContiguousArray<UInt8> = [0x1B, 0x5B, 0x31, 0x33, 0x3B, 0x32, 0x75]
    let xtermEnter: ContiguousArray<UInt8> = [0x1B, 0x5B, 0x32, 0x37, 0x3B, 0x32, 0x3B, 0x31, 0x33, 0x7E]
    let arrowUp: ContiguousArray<UInt8> = [0x1B, 0x5B, 0x41]

    self.addSimple(
      title: "KeyDecoder kitty Shift+Enter",
      input: Int.self
    ) { _ in
      var d = TerminalKeyDecoder()
      d.decode(kittyEnter) { _ in }
    }

    self.addSimple(
      title: "KeyDecoder xterm Shift+Enter",
      input: Int.self
    ) { _ in
      var d = TerminalKeyDecoder()
      d.decode(xtermEnter) { _ in }
    }

    self.addSimple(
      title: "KeyDecoder arrow (no-params)",
      input: Int.self
    ) { _ in
      var d = TerminalKeyDecoder()
      d.decode(arrowUp) { _ in }
    }

    self.add(
      title: "KeyDecoder ASCII burst",
      input: Int.self
    ) { size in
      let count = Swift.min(size, 1024)
      let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: max(1, count / 45))
      let bytes = ContiguousArray(text.prefix(count).utf8)
      return { timer in
        var d = TerminalKeyDecoder()
        timer.measure {
          d.decode(bytes) { _ in }
        }
      }
    }

    self.add(
      title: "KeyDecoder CSI mix",
      input: Int.self
    ) { size in
      let count = Swift.min(size / 10, 50)
      let chunks: [[UInt8]] = (0..<max(1, count)).map { _ in
        [
          0x1B, 0x5B, 0x41,           // ArrowUp
          0x1B, 0x5B, 0x42,           // ArrowDown
          0x1B, 0x5B, 0x35, 0x7E,     // PageUp
          0x68, 0x65, 0x6C, 0x6C, 0x6F, // "hello"
        ]
      }
      return { timer in
        var d = TerminalKeyDecoder()
        timer.measure {
          for chunk in chunks {
            d.decode(ContiguousArray(chunk)) { _ in }
          }
        }
      }
    }

    // ── Input Handler ────────────────────────────────────────────────

    let typingChunk = ContiguousArray("Hello, ".utf8)
    self.addSimple(
      title: "InputHandler 7-char type",
      input: Int.self
    ) { _ in
      var h = TerminalInputHandler()
      blackHole(h.handle(typingChunk))
    }

    let enterChunk: ContiguousArray<UInt8> = [13]
    self.addSimple(
      title: "InputHandler Enter",
      input: Int.self
    ) { _ in
      var h = TerminalInputHandler()
      blackHole(h.handle(enterChunk))
    }

    // ── LLM Streaming Simulation ─────────────────────────────────────

    self.add(
      title: "LLM stream: 10×blitText + encode",
      input: TerminalSize.self
    ) { ts in
      let tokens = (0..<10).map { i in "Token\(i) " }
      let capacity = ts.encodeCapacity
      return { timer in
        var g = TerminalCellGrid(
          cols: ts.cols, rows: ts.rows, filling: .defaultCell)
        var buf = TerminalByteBuffer(capacity: capacity)
        timer.measure {
          for (i, token) in tokens.enumerated() {
            g.blitText(
              column: (i * 7) % ts.cols, row: i % ts.rows,
              string: token,
              foreground: .cyan, background: .black)
          }
          g.encode(into: &buf)
        }
        blackHole(buf.count)
      }
    }

    // ── LLM Streaming: encode-only (pre-painted grid) ─────────────────

    self.add(
      title: "LLM: encode pre-painted (50% rows dirty)",
      input: TerminalSize.self
    ) { ts in
      let capacity = ts.encodeCapacity
      return { timer in
        var g = makeCleanGrid(size: ts)
        // Dirty half the rows to simulate a partial update
        for y in stride(from: 0, to: ts.rows, by: 2) {
          g[column: 0, row: y] = g[column: 0, row: y]
        }
        var buf = TerminalByteBuffer(capacity: capacity)
        timer.measure {
          g.encode(into: &buf)
        }
        blackHole(buf.count)
      }
    }
  }
}
