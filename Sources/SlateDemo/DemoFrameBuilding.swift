import SlateCore

enum DemoFrameBuilder {
  /// Builds the logical screen for one present (encoding vs raw tty writes are split elsewhere).
  static func makeGrid(
    cols: Int,
    rows: Int,
    transcript: String,
    keyHistoryLine: String,
    keyPressCount: Int
  ) -> TerminalCellGrid {
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

    if rows > 1 {
      let counter = "key count: \(keyPressCount)"
      let counterLen = counter.count
      let counterDisplayLen = min(counterLen, cols)
      let counterStartCol = cols &- counterDisplayLen

      let historyPrefix = "key history: "
      let rawTail =
        keyHistoryLine.isEmpty ? "(type / arrows —)" : keyHistoryLine
      let historyMaxWidth = max(0, counterStartCol &- 1)
      let historyText: String
      if historyMaxWidth == 0 {
        historyText = ""
      } else if historyMaxWidth <= historyPrefix.count {
        historyText = String(historyPrefix.prefix(historyMaxWidth))
      } else {
        let tailBudget = historyMaxWidth &- historyPrefix.count
        let tail =
          rawTail.count <= tailBudget
          ? rawTail
          : String(rawTail.suffix(tailBudget))
        historyText = historyPrefix + tail
      }
      let historyWidth = historyText.count

      if historyWidth > 0 {
        grid.blit(
          column: 0,
          row: 0,
          width: historyWidth,
          height: 1,
          repeating: TerminalCell(
            glyph: " ",
            foreground: TerminalRGB(r: 0, g: 200, b: 220),
            background: .black,
            flags: []))
        grid.blitText(
          column: 0,
          row: 0,
          string: String(historyText.prefix(historyWidth)),
          foreground: TerminalRGB(r: 0, g: 220, b: 240),
          background: .black,
          flags: [])
      }

      grid.blit(
        column: counterStartCol,
        row: 0,
        width: counterDisplayLen,
        height: 1,
        repeating: TerminalCell(
          glyph: " ",
          foreground: TerminalRGB(r: 255, g: 220, b: 120),
          background: .black,
          flags: []))
      grid.blitText(
        column: counterStartCol,
        row: 0,
        string: String(counter.suffix(counterDisplayLen)),
        foreground: TerminalRGB(r: 255, g: 230, b: 140),
        background: .black,
        flags: .bold)
    }

    let topMargin = rows > 1 ? 1 : 0
    let boxWidth = max(12, min(78, cols &- 2))
    let boxHeight = max(4, min(rows &- 2, max(4, rows * 2 / 5)))
    let startCol = max(0, (cols &- boxWidth) / 2)
    let startRow = max(topMargin, (rows &- boxHeight) / 2)

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
