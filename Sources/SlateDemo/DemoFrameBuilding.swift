import SlateCore

// MARK: - Palette

private enum P {
  static let bg = TerminalRGB(r: 14, g: 14, b: 24)
  static let headerBg = TerminalRGB(r: 22, g: 22, b: 42)
  static let inputBg = TerminalRGB(r: 20, g: 20, b: 36)
  static let title = TerminalRGB(r: 100, g: 155, b: 255)
  static let dim = TerminalRGB(r: 70, g: 70, b: 105)
  static let light = TerminalRGB(r: 195, g: 205, b: 220)
  static let orange = TerminalRGB(r: 255, g: 165, b: 60)
  static let yellow = TerminalRGB(r: 255, g: 218, b: 95)
  static let green = TerminalRGB(r: 95, g: 210, b: 130)
  static let blue = TerminalRGB(r: 100, g: 190, b: 255)
  static let white = TerminalRGB(r: 230, g: 235, b: 245)
}

// MARK: - Frame builder

enum DemoFrameBuilder {
  /// Hard cap on how many rows the input region may consume — prevents a long paste
  /// or held Shift+Enter from swallowing the transcript / key strip.
  static let maxInputRows = 6
  /// Lines moved per ``TerminalKeyEvent/pageUp`` / ``TerminalKeyEvent/pageDown`` press.
  static let pageScrollLines = 5

  /// Makes a fresh grid for the given terminal size. Use when the terminal is resized.
  static func makeGrid(cols: Int, rows: Int) -> TerminalCellGrid {
    TerminalCellGrid(
      cols: cols, rows: rows,
      filling: TerminalCell(glyph: " ", foreground: P.light, background: P.bg, flags: []))
  }

  /// Renders one frame into `grid` (which must already match `cols`×`rows`).
  /// Uses ``TerminalCellGrid/reset(filling:)`` to clear, ``TerminalCellGrid/blitSpans(column:row:maxWidth:_:)``
  /// for all styled text, and ``TerminalCellGrid/blitText(column:row:string:foreground:background:flags:)``
  /// for plain text runs.
  ///
  /// Scrollback uses an **absolute first-visible-row** model (matching scribe's
  /// `Sources/ScribeCLI/SlateChat/SlateChatHost.swift`): when ``followingLiveTranscript`` is
  /// `true` the viewport always shows the live tail; when `false`, ``firstVisibleRow`` pins
  /// the top of the viewport so streaming tokens at the bottom don't drag the user's
  /// scrolled-up position. Both are clamped in-place against the wrapped transcript so the
  /// caller can mutate them freely from key handlers without knowing the current geometry,
  /// and the render automatically re-attaches to the live tail when scrolling reaches the
  /// bottom.
  static func render(
    into grid: inout TerminalCellGrid,
    cols: Int,
    rows: Int,
    transcript: [(speaker: String, text: String)],
    streamingText: String,
    inputBuffer: String,
    keyHistory: [String],
    keyCount: Int,
    firstVisibleRow: inout Int,
    followingLiveTranscript: inout Bool
  ) {
    // ── reset ────────────────────────────────────────────────────────────────
    grid.reset(
      filling: TerminalCell(glyph: " ", foreground: P.light, background: P.bg, flags: []))

    guard rows >= 3, cols >= 10 else { return }

    // ── header (row 0) ───────────────────────────────────────────────────────
    paintHeader(into: &grid, cols: cols, keyCount: keyCount)

    // Reserve at least 1 row for header + 1 for key history + 1 for input.
    let inputHeight = computeInputHeight(inputBuffer: inputBuffer, cols: cols, rows: rows)
    let keyRow = rows &- inputHeight &- 1
    let inputStartRow = rows &- inputHeight

    // ── transcript (rows 1 … keyRow-1) ──────────────────────────────────────
    let contentRows = max(0, keyRow &- 1)
    let hiddenBelow: Int
    if contentRows > 0 {
      hiddenBelow = paintTranscript(
        into: &grid, transcript: transcript, streamingText: streamingText,
        cols: cols, startRow: 1, height: contentRows,
        firstVisibleRow: &firstVisibleRow,
        followingLiveTranscript: &followingLiveTranscript)
    } else {
      firstVisibleRow = 0
      followingLiveTranscript = true
      hiddenBelow = 0
    }

    // ── key-history strip (row keyRow) ───────────────────────────────────────
    paintKeyHistory(
      into: &grid, keyHistory: keyHistory, row: keyRow, cols: cols,
      hiddenBelow: hiddenBelow)

    // ── input rows (inputStartRow … rows-1) ──────────────────────────────────
    paintInput(
      into: &grid, inputBuffer: inputBuffer,
      startRow: inputStartRow, height: inputHeight, cols: cols)
  }

  /// Wrapped-line count of the input buffer, capped to ``maxInputRows`` (and to the available
  /// rows after reserving header + key strip).
  static func computeInputHeight(inputBuffer: String, cols: Int, rows: Int) -> Int {
    let prompt = "you: "
    let textWidth = max(1, cols &- prompt.count &- 1)  // -1 for cursor glyph
    let lines = wrapText(inputBuffer, width: textWidth)
    let desired = max(1, lines.count)
    let geometryCap = max(1, rows &- 2)  // header + key strip
    return min(maxInputRows, min(desired, geometryCap))
  }

  // MARK: - Sections

  private static func paintHeader(
    into grid: inout TerminalCellGrid, cols: Int, keyCount: Int
  ) {
    grid.blit(
      column: 0, row: 0, width: cols, height: 1,
      repeating: TerminalCell(glyph: " ", foreground: P.light, background: P.headerBg, flags: []))

    // Left: "Slate · Demo" — three spans, different colours
    grid.blitSpans(column: 1, row: 0, maxWidth: cols &- 1, [
      TerminalStyledSpan("Slate", foreground: P.title, background: P.headerBg, flags: .bold),
      TerminalStyledSpan(" · ", foreground: P.dim, background: P.headerBg),
      TerminalStyledSpan("Demo", foreground: P.light, background: P.headerBg),
    ])

    // Right: "keys: N" — right-aligned
    let countLabel = "keys: "
    let countValue = "\(keyCount)"
    let totalW = countLabel.count &+ countValue.count &+ 1
    let startCol = max(2, cols &- totalW)
    grid.blitSpans(column: startCol, row: 0, maxWidth: cols &- startCol, [
      TerminalStyledSpan(countLabel, foreground: P.dim, background: P.headerBg),
      TerminalStyledSpan(countValue, foreground: P.yellow, background: P.headerBg, flags: .bold),
    ])
  }

  /// Returns the count of wrapped transcript lines hidden below the visible viewport
  /// (used by ``paintKeyHistory`` to render the "↑ N · End to follow" badge).
  private static func paintTranscript(
    into grid: inout TerminalCellGrid,
    transcript: [(speaker: String, text: String)],
    streamingText: String,
    cols: Int,
    startRow: Int,
    height: Int,
    firstVisibleRow: inout Int,
    followingLiveTranscript: inout Bool
  ) -> Int {
    struct VLine {
      var prefix: String
      var prefixColor: TerminalRGB
      var text: String
      var textColor: TerminalRGB
    }

    var lines: [VLine] = []

    func addEntry(speaker: String, text: String) {
      let isUser = speaker == "you"
      let speakerColor: TerminalRGB = isUser ? P.orange : P.blue
      let textColor: TerminalRGB = isUser ? P.white : P.light
      let prompt = speaker + ": "
      let indent = String(repeating: " ", count: prompt.count)
      let textWidth = max(1, cols &- prompt.count)
      let wrapped = wrapText(text, width: textWidth)
      for (i, chunk) in wrapped.enumerated() {
        lines.append(VLine(
          prefix: i == 0 ? prompt : indent,
          prefixColor: i == 0 ? speakerColor : P.bg,
          text: chunk,
          textColor: textColor))
      }
    }

    for entry in transcript { addEntry(speaker: entry.speaker, text: entry.text) }
    if !streamingText.isEmpty { addEntry(speaker: "Neville", text: streamingText) }

    // Resolve the effective top-of-viewport row using the current geometry. When following the
    // live tail we always pin to the bottom; when scrolled, we clamp the caller's stored row
    // and re-attach to the tail if it has caught up.
    let maxFirstRow = max(0, lines.count &- height)
    let effectiveFirstRow: Int
    if followingLiveTranscript {
      effectiveFirstRow = maxFirstRow
    } else {
      let clamped = max(0, min(firstVisibleRow, maxFirstRow))
      if clamped >= maxFirstRow {
        followingLiveTranscript = true
        effectiveFirstRow = maxFirstRow
      } else {
        effectiveFirstRow = clamped
      }
    }
    firstVisibleRow = effectiveFirstRow

    let endIdx = min(effectiveFirstRow &+ height, lines.count)
    let visible = Array(lines[effectiveFirstRow..<endIdx])
    let topPad = height &- visible.count
    for (i, line) in visible.enumerated() {
      let row = startRow &+ topPad &+ i
      guard row >= 0, row < grid.rows else { continue }
      grid.blitSpans(column: 0, row: row, maxWidth: cols, [
        TerminalStyledSpan(line.prefix, foreground: line.prefixColor, background: P.bg),
        TerminalStyledSpan(line.text, foreground: line.textColor, background: P.bg),
      ])
    }
    return max(0, lines.count &- (effectiveFirstRow &+ visible.count))
  }

  private static func paintKeyHistory(
    into grid: inout TerminalCellGrid, keyHistory: [String], row: Int, cols: Int,
    hiddenBelow: Int
  ) {
    guard row >= 0, row < grid.rows else { return }
    grid.blit(
      column: 0, row: row, width: cols, height: 1,
      repeating: TerminalCell(glyph: " ", foreground: P.dim, background: P.bg, flags: []))

    let label = "keys: "
    let tail = keyHistory.isEmpty ? "(type something)" : keyHistory.joined(separator: " ")
    let maxTail = max(0, cols &- label.count)
    let trimmedTail = tail.count > maxTail ? String(tail.suffix(maxTail)) : tail

    grid.blitSpans(column: 0, row: row, maxWidth: cols, [
      TerminalStyledSpan(label, foreground: P.dim, background: P.bg),
      TerminalStyledSpan(trimmedTail, foreground: P.green, background: P.bg),
    ])

    // Right-aligned scroll indicator: only shown when the live tail is below the viewport.
    if hiddenBelow > 0 {
      let badge = "↓ \(hiddenBelow) · End to follow"
      let startCol = max(label.count &+ trimmedTail.count &+ 2, cols &- badge.count)
      if startCol < cols {
        grid.blitSpans(column: startCol, row: row, maxWidth: cols &- startCol, [
          TerminalStyledSpan(badge, foreground: P.yellow, background: P.bg),
        ])
      }
    }
  }

  private static func paintInput(
    into grid: inout TerminalCellGrid, inputBuffer: String,
    startRow: Int, height: Int, cols: Int
  ) {
    guard height >= 1, startRow >= 0, startRow < grid.rows else { return }
    let drawHeight = min(height, grid.rows &- startRow)
    grid.blit(
      column: 0, row: startRow, width: cols, height: drawHeight,
      repeating: TerminalCell(glyph: " ", foreground: P.white, background: P.inputBg, flags: []))

    let prompt = "you: "
    let indent = String(repeating: " ", count: prompt.count)
    let textWidth = max(1, cols &- prompt.count &- 1)  // -1 for cursor glyph
    let allLines = wrapText(inputBuffer, width: textWidth)
    let visibleLines = Array(allLines.suffix(drawHeight))
    let lastIdx = visibleLines.count &- 1

    for (i, line) in visibleLines.enumerated() {
      let row = startRow &+ i
      guard row < grid.rows else { break }
      let pre = (i == 0) ? prompt : indent
      let preColor: TerminalRGB = (i == 0) ? P.orange : P.white
      var spans: [TerminalStyledSpan] = [
        TerminalStyledSpan(pre, foreground: preColor, background: P.inputBg),
        TerminalStyledSpan(line, foreground: P.white, background: P.inputBg),
      ]
      if i == lastIdx {
        spans.append(
          TerminalStyledSpan("▏", foreground: P.white, background: P.inputBg))
      }
      grid.blitSpans(column: 0, row: row, maxWidth: cols, spans)
    }
  }

  // MARK: - Text wrapping

  /// Word-wrap that **preserves explicit `\n`** as hard line breaks. Used for both transcript
  /// entries (so multi-paragraph assistant text reads correctly) and the multi-line input
  /// buffer (where Shift+Enter and pasted newlines insert real `\n`).
  static func wrapText(_ text: String, width: Int) -> [String] {
    guard width > 0 else { return [text] }
    var lines: [String] = []
    let paragraphs = text.split(
      separator: "\n", maxSplits: Int.max, omittingEmptySubsequences: false)
    for paragraph in paragraphs {
      let para = String(paragraph)
      if para.isEmpty {
        lines.append("")
        continue
      }
      var current = ""
      for word in para.split(separator: " ", omittingEmptySubsequences: false) {
        let w = String(word)
        let sep = current.isEmpty ? "" : " "
        let candidate = current + sep + w
        if candidate.count <= width {
          current = candidate
          continue
        }
        if !current.isEmpty {
          lines.append(current)
          current = ""
        }
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
      lines.append(current)
    }
    return lines.isEmpty ? [""] : lines
  }
}
