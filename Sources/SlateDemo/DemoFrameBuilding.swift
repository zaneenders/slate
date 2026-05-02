import SlateCore

enum DemoFrameBuilder {
  /// Builds the logical screen for one present. Encoding and raw IO stay on ``MainActor``.
  static func makeGrid(cols: Int, rows: Int, transcript: String) -> TerminalCellGrid {
    var grid = TerminalCellGrid(
      cols: cols,
      rows: rows,
      filling: TerminalCell(
        glyph: " ",
        foreground: .black,
        background: .black,
        flags: []))

    var y = 0
    while y < rows {
      var x = 0
      while x < cols {
        let backgroundRed = UInt8.random(in: 0...255)
        let backgroundGreen = UInt8.random(in: 0...255)
        let backgroundBlue = UInt8.random(in: 0...255)
        let foregroundRed = UInt8.random(in: 0...255)
        let foregroundGreen = UInt8.random(in: 0...255)
        let foregroundBlue = UInt8.random(in: 0...255)
        let ch = Character(UnicodeScalar(UInt8.random(in: 32...126)))
        grid[column: x, row: y] = TerminalCell(
          glyph: ch,
          foreground: TerminalRGB(r: foregroundRed, g: foregroundGreen, b: foregroundBlue),
          background: TerminalRGB(r: backgroundRed, g: backgroundGreen, b: backgroundBlue),
          flags: [])
        x &+= 1
      }
      y &+= 1
    }

    let hud = "tokens + 33ms bg tick — ExternalWake ≤60Hz — keys: reshuffle"
    let hudColumns = min(hud.count, cols)
    grid.blit(
      column: 0,
      row: 0,
      width: hudColumns,
      height: 1,
      repeating: TerminalCell(
        glyph: " ",
        foreground: .white,
        background: .black,
        flags: []))
    grid.blitText(
      column: 0,
      row: 0,
      string: String(hud.prefix(hudColumns)),
      foreground: .white,
      background: .black,
      flags: .bold)

    let boxWidth = max(12, min(78, cols &- 2))
    let boxHeight = max(4, min(rows &- 2, max(4, rows * 2 / 5)))
    let startCol = max(0, (cols &- boxWidth) / 2)
    let startRow = max(1, (rows &- boxHeight) / 2)

    grid.blit(
      column: startCol,
      row: startRow,
      width: boxWidth,
      height: boxHeight,
      repeating: TerminalCell(
        glyph: " ",
        foreground: .white,
        background: .black,
        flags: []))

    let lines: [String]
    if transcript.isEmpty {
      lines = ["…"]
    } else {
      lines = linesFromTranscript(transcript, width: boxWidth)
    }
    let visible = Array(lines.suffix(boxHeight))
    let paddingRows = boxHeight &- visible.count
    var lineRow = startRow
    if paddingRows > 0 {
      lineRow &+= paddingRows
    }
    for line in visible {
      grid.blitText(
        column: startCol,
        row: lineRow,
        string: String(line.prefix(boxWidth)),
        foreground: .white,
        background: .black,
        flags: [])
      lineRow &+= 1
    }

    return grid
  }

  /// Splits on `\n` so each ``model.text += "\n"`` starts a new row in the viewport; each segment is word-wrapped to `width`.
  private static func linesFromTranscript(_ transcript: String, width: Int) -> [String] {
    var out: [String] = []
    for segment in transcript.split(separator: "\n", omittingEmptySubsequences: false) {
      let s = String(segment)
      if s.isEmpty {
        out.append("")
      } else {
        out.append(contentsOf: wrappedLines(s, width: width))
      }
    }
    return out
  }

  private static func wrappedLines(_ text: String, width: Int) -> [String] {
    guard width > 0 else { return [] }
    var lines: [String] = []
    var current = ""

    func flushCurrent() {
      if !current.isEmpty {
        lines.append(current)
        current = ""
      }
    }

    for word in text.split(separator: " ", omittingEmptySubsequences: false) {
      let w = String(word)
      let sep = current.isEmpty ? "" : " "
      let candidate = current + sep + w
      if candidate.count <= width {
        current = candidate
        continue
      }

      flushCurrent()

      if w.count <= width {
        current = w
        continue
      }

      var rest = Substring(w)
      while !rest.isEmpty {
        let take = min(width, rest.count)
        lines.append(String(rest.prefix(take)))
        rest = rest.dropFirst(take)
      }
    }

    flushCurrent()
    return lines
  }
}
