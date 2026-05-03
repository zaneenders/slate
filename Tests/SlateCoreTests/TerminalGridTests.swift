import Testing

@testable import SlateCore

private func decoded(_ buffer: borrowing TerminalByteBuffer) -> String {
  unsafe buffer.span.bytes.withUnsafeBytes { raw in
    unsafe String(decoding: raw, as: UTF8.self)
  }
}

@Suite struct CSISequenceTests {

  @Test func cup_oneBasedFormat() {
    #expect(CSI.cup(row: 1, column: 1) == "\u{001b}[1;1H")
    #expect(CSI.cup(row: 3, column: 7) == "\u{001b}[3;7H")
  }

  @Test func sgrTruecolor_embedsRgbPairs() {
    let s = CSI.sgrTruecolor(
      backgroundR: 1, backgroundG: 2, backgroundB: 3,
      foregroundR: 4, foregroundG: 5, foregroundB: 6)
    #expect(s.contains("48;2;1;2;3"))
    #expect(s.contains("38;2;4;5;6"))
  }

  @Test func sgrTruecolor_terminalRgbMatchesByteForm() {
    let bg = TerminalRGB(r: 1, g: 2, b: 3)
    let fg = TerminalRGB(r: 4, g: 5, b: 6)
    let a = CSI.sgrTruecolor(background: bg, foreground: fg)
    let b = CSI.sgrTruecolor(
      backgroundR: 1, backgroundG: 2, backgroundB: 3,
      foregroundR: 4, foregroundG: 5, foregroundB: 6)
    #expect(a == b)
  }

  @Test func sgrForeground_embeds38_2() {
    let s = CSI.sgrForeground(TerminalRGB(r: 10, g: 20, b: 30))
    #expect(s == "\u{001b}[38;2;10;20;30m")
  }

  @Test func sgrBoldForeground_ordersBoldBeforeFg() {
    let s = CSI.sgrBoldForeground(TerminalRGB(r: 7, g: 8, b: 9))
    #expect(s.hasPrefix(CSI.sgrBold))
    #expect(s.contains("38;2;7;8;9"))
  }

  @Test func sgrFaint_isSGR2() {
    #expect(CSI.sgrFaint == "\u{001b}[2m")
  }

  @Test func staticFragments_nonEmpty() {
    #expect(!CSI.sgr0.isEmpty)
    #expect(!CSI.sgrBold.isEmpty)
    #expect(!CSI.sgrNormalIntensity.isEmpty)
    #expect(!CSI.sgrFaint.isEmpty)
    #expect(!CSI.clrHome.isEmpty)
  }
}

@Suite struct TerminalGridTests {

  @Test func cellGrid_encode_strideFill_writesCellsAndEndsWithReset() {
    var grid = TerminalCellGrid(
      cols: 2,
      rows: 2,
      filling: TerminalCell(
        glyph: ".", foreground: .black, background: .white, flags: []))
    let glyphs: [Character] = ["A", "B", "X", "Y"]
    for i in stride(from: 0, to: 4, by: 1) {
      let x = i % 2
      let y = i / 2
      grid[column: x, row: y] = TerminalCell(
        glyph: glyphs[i], foreground: .white, background: .black, flags: [])
    }
    var buffer = TerminalByteBuffer(capacity: 512)
    grid.encode(into: &buffer)
    let s = decoded(buffer)
    #expect(s.hasSuffix(CSI.sgr0))
    #expect(s.contains("A"))
    #expect(s.contains("B"))
    #expect(s.contains("X"))
    #expect(s.contains("Y"))
  }

  @Test func cellGrid_encode_replacesPriorBufferContents() {
    let grid = TerminalCellGrid(
      cols: 1,
      rows: 1,
      filling: TerminalCell(
        glyph: "Z", foreground: .black, background: .white, flags: []))
    var buffer = TerminalByteBuffer(capacity: 64)
    buffer.append(0xFF)
    buffer.append(0xFE)
    grid.encode(into: &buffer)
    let s = decoded(buffer)
    #expect(s.hasPrefix("\u{001b}["))
    #expect(s.contains("Z"))
    #expect(s.hasSuffix(CSI.sgr0))
  }

  @Test func cellGrid_encode_emitsCupPerRowColorsAndReset() {
    var grid = TerminalCellGrid(
      cols: 2,
      rows: 2,
      filling: TerminalCell(
        glyph: ".", foreground: .black, background: .white, flags: []))
    grid[column: 0, row: 0] = TerminalCell(
      glyph: "A", foreground: .white, background: .black, flags: [.bold])
    grid[column: 1, row: 0] = TerminalCell(
      glyph: "B", foreground: .black, background: .white, flags: [])
    grid[column: 0, row: 1] = TerminalCell(
      glyph: "X", foreground: .white, background: .black, flags: [])
    grid[column: 1, row: 1] = TerminalCell(
      glyph: "Y", foreground: .black, background: .white, flags: [])
    var buffer = TerminalByteBuffer(capacity: 512)
    grid.encode(into: &buffer)
    let s = decoded(buffer)
    #expect(s.hasSuffix(CSI.sgr0))
    #expect(s.contains("\u{001b}[1;1H"))
    #expect(s.contains("\u{001b}[2;1H"))
    #expect(s.contains(CSI.sgrBold))
    #expect(s.contains(CSI.sgrNormalIntensity))
    #expect(s.contains("A"))
    #expect(s.contains("B"))
    #expect(s.contains("X"))
    #expect(s.contains("Y"))
  }

  @Test func cellGrid_blitText_overwritesRun() {
    let red = TerminalRGB(r: 200, g: 0, b: 0)
    let green = TerminalRGB(r: 0, g: 200, b: 0)
    var grid = TerminalCellGrid(
      cols: 6,
      rows: 1,
      filling: TerminalCell(
        glyph: "#", foreground: .white, background: red, flags: []))
    for k in 0..<6 {
      grid[column: k, row: 0] = TerminalCell(
        glyph: "#", foreground: .white, background: red, flags: [])
    }
    grid.blitText(
      column: 1,
      row: 0,
      string: "hi",
      foreground: .black,
      background: green,
      flags: [])
    #expect(grid[column: 0, row: 0].glyph == "#")
    #expect(grid[column: 1, row: 0].glyph == "h")
    #expect(grid[column: 2, row: 0].glyph == "i")
    #expect(grid[column: 3, row: 0].glyph == "#")
  }

  @Test func cellGrid_blitText_appliesFlags() {
    var grid = TerminalCellGrid(
      cols: 1,
      rows: 1,
      filling: TerminalCell(
        glyph: ".", foreground: .white, background: .black, flags: []))
    grid.blitText(
      column: 0,
      row: 0,
      string: "Q",
      foreground: .white,
      background: .black,
      flags: [.bold])
    #expect(grid[column: 0, row: 0].flags == [.bold])
  }

  @Test func cellGrid_blitText_noOpWhenRowOutOfRange() {
    var grid = TerminalCellGrid(
      cols: 2,
      rows: 2,
      filling: TerminalCell(
        glyph: ".", foreground: .black, background: .white, flags: []))
    grid.blitText(
      column: 0,
      row: -1,
      string: "@",
      foreground: .white,
      background: .black,
      flags: [])
    grid.blitText(
      column: 0,
      row: 2,
      string: "@",
      foreground: .white,
      background: .black,
      flags: [])
    #expect(grid[column: 0, row: 0].glyph == ".")
    #expect(grid[column: 0, row: 1].glyph == ".")
  }

  @Test func cellGrid_blitText_noOpWhenColumnPastEnd() {
    var grid = TerminalCellGrid(
      cols: 2,
      rows: 1,
      filling: TerminalCell(
        glyph: ".", foreground: .black, background: .white, flags: []))
    grid.blitText(
      column: 2,
      row: 0,
      string: "ab",
      foreground: .white,
      background: .black,
      flags: [])
    #expect(grid[column: 0, row: 0].glyph == ".")
    #expect(grid[column: 1, row: 0].glyph == ".")
  }

  @Test func cellGrid_blitText_truncatesAtRightEdge() {
    var grid = TerminalCellGrid(
      cols: 3,
      rows: 1,
      filling: TerminalCell(
        glyph: ".", foreground: .black, background: .white, flags: []))
    grid.blitText(
      column: 1,
      row: 0,
      string: "abcd",
      foreground: .white,
      background: .black,
      flags: [])
    #expect(grid[column: 0, row: 0].glyph == ".")
    #expect(grid[column: 1, row: 0].glyph == "a")
    #expect(grid[column: 2, row: 0].glyph == "b")
  }

  @Test func cellGrid_blit_fillsClippedRectangle() {
    var grid = TerminalCellGrid(
      cols: 3,
      rows: 3,
      filling: TerminalCell(
        glyph: ".", foreground: .black, background: .white, flags: []))
    let mark = TerminalCell(
      glyph: "#", foreground: .white, background: .black, flags: [])
    grid.blit(column: 1, row: 1, width: 2, height: 2, repeating: mark)
    #expect(grid[column: 0, row: 0].glyph == ".")
    #expect(grid[column: 1, row: 1].glyph == "#")
    #expect(grid[column: 2, row: 1].glyph == "#")
    #expect(grid[column: 1, row: 2].glyph == "#")
    #expect(grid[column: 2, row: 2].glyph == "#")
  }

  @Test func cellGrid_blit_skipsWhenWidthOrHeightZero() {
    var grid = TerminalCellGrid(
      cols: 2,
      rows: 2,
      filling: TerminalCell(
        glyph: ".", foreground: .black, background: .white, flags: []))
    let mark = TerminalCell(
      glyph: "#", foreground: .white, background: .black, flags: [])
    grid.blit(column: 0, row: 0, width: 0, height: 2, repeating: mark)
    grid.blit(column: 0, row: 0, width: 2, height: 0, repeating: mark)
    #expect(grid[column: 0, row: 0].glyph == ".")
  }

  @Test func cellGrid_blit_negativeOriginClips() {
    var grid = TerminalCellGrid(
      cols: 2,
      rows: 2,
      filling: TerminalCell(
        glyph: ".", foreground: .black, background: .white, flags: []))
    let mark = TerminalCell(
      glyph: "#", foreground: .white, background: .black, flags: [])
    grid.blit(column: -1, row: 0, width: 2, height: 1, repeating: mark)
    #expect(grid[column: 0, row: 0].glyph == "#")
    #expect(grid[column: 1, row: 0].glyph == ".")
  }

  @Test func cellGrid_blitSpans_appliesPerSpanStyles() {
    let fg1 = TerminalRGB(r: 1, g: 2, b: 3)
    let bg1 = TerminalRGB(r: 4, g: 5, b: 6)
    let fg2 = TerminalRGB(r: 7, g: 8, b: 9)
    var grid = TerminalCellGrid(
      cols: 5,
      rows: 1,
      filling: TerminalCell(
        glyph: ".", foreground: .white, background: .black, flags: []))
    grid.blitSpans(
      column: 0,
      row: 0,
      maxWidth: 5,
      [
        TerminalStyledSpan("ab", foreground: fg1, background: bg1, flags: [.bold]),
        TerminalStyledSpan("cd", foreground: fg2, background: .black, flags: []),
      ])
    #expect(grid[column: 0, row: 0].glyph == "a")
    #expect(grid[column: 0, row: 0].foreground == fg1)
    #expect(grid[column: 0, row: 0].background == bg1)
    #expect(grid[column: 0, row: 0].flags == [.bold])
    #expect(grid[column: 2, row: 0].glyph == "c")
    #expect(grid[column: 2, row: 0].foreground == fg2)
    #expect(grid[column: 4, row: 0].glyph == ".")
  }

  @Test func cellGrid_blitSpans_respectsMaxWidth() {
    var grid = TerminalCellGrid(
      cols: 4,
      rows: 1,
      filling: TerminalCell(
        glyph: ".", foreground: .black, background: .white, flags: []))
    grid.blitSpans(
      column: 1,
      row: 0,
      maxWidth: 2,
      [TerminalStyledSpan("xxxx", foreground: .white, background: .black, flags: [])])
    #expect(grid[column: 0, row: 0].glyph == ".")
    #expect(grid[column: 1, row: 0].glyph == "x")
    #expect(grid[column: 2, row: 0].glyph == "x")
    #expect(grid[column: 3, row: 0].glyph == ".")
  }

  @Test func cellGrid_blitSpans_noOpWhenMaxWidthZeroOrOutOfBounds() {
    var grid = TerminalCellGrid(
      cols: 2,
      rows: 2,
      filling: TerminalCell(
        glyph: ".", foreground: .black, background: .white, flags: []))
    let span = TerminalStyledSpan("@", foreground: .white, background: .black, flags: [])
    grid.blitSpans(column: 0, row: 0, maxWidth: 0, [span])
    grid.blitSpans(column: 0, row: -1, maxWidth: 1, [span])
    grid.blitSpans(column: 0, row: 2, maxWidth: 1, [span])
    grid.blitSpans(column: -1, row: 0, maxWidth: 1, [span])
    grid.blitSpans(column: 2, row: 0, maxWidth: 1, [span])
    #expect(grid[column: 0, row: 0].glyph == ".")
  }

  @Test func cellGrid_reset_refillsWithCell() {
    var grid = TerminalCellGrid(
      cols: 2,
      rows: 2,
      filling: TerminalCell(
        glyph: ".", foreground: .black, background: .white, flags: []))
    grid[column: 0, row: 0] = TerminalCell(
      glyph: "!", foreground: .white, background: .black, flags: [])
    let fill = TerminalCell(
      glyph: "x", foreground: .white, background: .black, flags: [.bold])
    grid.reset(filling: fill)
    for x in 0..<2 {
      for y in 0..<2 {
        #expect(grid[column: x, row: y].glyph == "x")
        #expect(grid[column: x, row: y].flags == [.bold])
      }
    }
  }
}

@Suite struct IOCTLWindowSizeTests {

  @Test func ioctl_clampsToMaxDimensions() {
    let s = ioctlStdoutWindowSize(maxCols: 2, maxRows: 3)
    #expect(s.cols >= 1 && s.cols <= 2)
    #expect(s.rows >= 1 && s.rows <= 3)
  }

  @Test func tty_matchesIoctl_whenDefaults() {
    let a = ioctlStdoutWindowSize(maxCols: 999, maxRows: 999)
    let b = TTY.windowSize()
    #expect(a == b)
  }
}

@Suite struct TerminalEncodingExtrasTests {

  @Test func cellGrid_encode_nonAsciiGlyph_UTF8Embedded() {
    var grid = TerminalCellGrid(
      cols: 1,
      rows: 1,
      filling: TerminalCell(
        glyph: ".", foreground: .black, background: .white, flags: []))
    grid[column: 0, row: 0] = TerminalCell(
      glyph: "Ω",
      foreground: .white,
      background: .black,
      flags: [])
    var buffer = TerminalByteBuffer(capacity: 128)
    grid.encode(into: &buffer)
    let s = decoded(buffer)
    #expect(s.hasSuffix(CSI.sgr0))
    #expect(s.contains("Ω"))
    #expect(s.contains("\u{001b}[48;2;0;0;0m"))
    #expect(s.contains("\u{001b}[38;2;255;255;255m"))
  }

  @Test func cellGrid_encode_cupDoubleDigitRow() {
    let grid = TerminalCellGrid(
      cols: 1,
      rows: 12,
      filling: TerminalCell(
        glyph: "*", foreground: .white, background: .black, flags: []))
    var buffer = TerminalByteBuffer(capacity: 4096)
    grid.encode(into: &buffer)
    let s = decoded(buffer)
    #expect(s.contains("\u{001b}[10;1H"))
    #expect(s.contains("\u{001b}[12;1H"))
  }
}

@Suite struct DoubleBufferedPresenterTests {

  @Test func presenter_callsEncodeClosurePerFrameThenStopsCleanly() async {
    let presenter = DoubleBufferedTerminalPresenter()
    presenter.ensureEncodedByteCapacity(for: 1, rows: 1)
    var invokes = 0
    presenter.presentFrame { buf in
      invokes += 1
      buf.removeAll()
      buf.append(0x43)  // "C"
    }
    presenter.presentFrame { buf in
      invokes += 1
      buf.removeAll()
      buf.append(0x44)  // "D"
    }
    await presenter.flushAndStopWriter()
    #expect(invokes == 2)
  }

  @Test func presenter_capacityCanBeResized_beforeFirstSubmit() async {
    let presenter = DoubleBufferedTerminalPresenter()
    presenter.ensureEncodedByteCapacity(for: 80, rows: 24)
    presenter.ensureEncodedByteCapacity(for: 1, rows: 1)
    presenter.presentFrame { buf in
      buf.removeAll()
      buf.append(0x5A)
    }
    await presenter.flushAndStopWriter()
  }
}
