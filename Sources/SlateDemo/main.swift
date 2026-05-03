import SlateCore

/// Multi-line text buffer with simple line wrapping.
actor InputBuffer {
  private var lines: [String] = [""]
  private var cursorVisible = true
  private var cursorTick: UInt64 = 0

  /// Append text (may contain newlines from pasting or soft-newline keys).
  func append(_ text: String) {
    for ch in text {
      if ch == "\n" {
        lines.append("")
      } else {
        lines[lines.count - 1].append(ch)
      }
    }
  }

  /// Insert a soft newline (Shift+Enter, Alt+Enter, etc.).
  func newline() {
    lines.append("")
  }

  func backspace() {
    if var last = lines.last, !last.isEmpty {
      last.removeLast()
      lines[lines.count - 1] = last
    } else if lines.count > 1 {
      lines.removeLast()
    }
  }

  func clear() {
    lines = [""]
  }

  /// Returns the flattened text suitable for submission.
  func flatText() -> String {
    lines.joined(separator: "\n")
  }

  /// Returns visual rows (wrapped) limited to a max row count.
  func visualRows(width: Int, maxRows: Int) -> [String] {
    guard width > 0 else { return [] }
    var out: [String] = []
    for line in lines {
      if line.isEmpty {
        out.append("")
      } else {
        var remaining = line
        while !remaining.isEmpty {
          let take = min(width, remaining.count)
          out.append(String(remaining.prefix(take)))
          remaining = String(remaining.dropFirst(take))
        }
      }
    }
    if out.count > maxRows {
      return Array(out.suffix(maxRows))
    }
    return out
  }

  func rowCount() -> Int { lines.count }

  func tick() {
    cursorTick &+= 1
    cursorVisible = (cursorTick / 30) % 2 == 0
  }

  func cursorOn() -> Bool { cursorVisible }
}

/// Simple scrollback for submitted messages.
actor History {
  private var entries: [String] = []

  func append(_ text: String) {
    entries.append(text)
    if entries.count > 200 {
      entries.removeFirst(entries.count - 200)
    }
  }

  func all() -> [String] { entries }
}

@main
struct SlateDemo {
  static func main() async throws {
    var term = try Terminal()
    let input = InputBuffer()
    let history = History()
    let quit = QuitFlag()

    let events = term.events()

    // Event consumer
    Task {
      for await event in events {
        let isCtrlC = event.code == .character("c") && event.modifiers.contains(.control)
        let isEsc = event.code == .escape
        if isCtrlC || isEsc {
          await quit.set()
          break
        }

        switch event.code {
        case .character(let ch):
          if event.modifiers.contains(.control) {
            break
          }
          await input.append(String(ch))
        case .enter where !event.modifiers.isEmpty:
          // Shift+Enter, Alt+Enter, etc. → soft newline
          await input.newline()
        case .enter:
          // Plain Enter → submit
          let text = await input.flatText()
          if !text.isEmpty {
            await history.append(text)
          }
          await input.clear()
        case .backspace:
          await input.backspace()
        default:
          break
        }
      }
    }

    var frame: UInt64 = 0

    while !(await quit.check()) {
      term.refreshSize()
      term.clear(to: Cell(char: " ", attrs: Attributes(foreground: .default, background: .black)))

      let cols = term.cols
      let rows = term.rows

      // ── Header ─────────────────────────────────────────
      let title = "Slate Demo"
      let titleX = max(0, (cols &- title.count) / 2)
      term.drawText(title, at: titleX, row: 1, attrs: Attributes(foreground: .white, background: .black, style: .bold))

      let subtitle = "Enter submits  ·  Shift+Enter newline  ·  Esc or Ctrl-C exits"
      let subX = max(0, (cols &- subtitle.count) / 2)
      term.drawText(subtitle, at: subX, row: 2, attrs: Attributes(foreground: Color(r: 150, g: 150, b: 150), background: .black))

      // ── History (submitted messages) ───────────────────
      let historyEntries = await history.all()
      let headerRows = 4
      let inputAreaRows = min(8, rows / 4)
      let historyStartRow = headerRows
      let historyEndRow = rows &- inputAreaRows &- 1
      let historyVisibleRows = max(0, historyEndRow &- historyStartRow)

      if historyVisibleRows > 0 {
        var y = historyStartRow
        let visibleEntries = historyEntries.suffix(historyVisibleRows)
        for entry in visibleEntries {
          guard y < historyEndRow else { break }
          // Simple wrap for history entries
          var remaining = entry
          while !remaining.isEmpty && y < historyEndRow {
            let take = min(max(0, cols &- 4), remaining.count)
            let slice = String(remaining.prefix(take))
            term.drawText("  " + slice, at: 2, row: y, attrs: Attributes(foreground: .cyan, background: .black))
            remaining = String(remaining.dropFirst(take))
            y &+= 1
          }
          if remaining.isEmpty && y < historyEndRow {
            y &+= 1 // blank line between entries
          }
        }
      }

      // ── Separator ──────────────────────────────────────
      let sepRow = rows &- inputAreaRows &- 1
      if sepRow >= headerRows {
        let sepText = String(repeating: "─", count: max(0, cols &- 4))
        term.drawText(sepText, at: 2, row: sepRow, attrs: Attributes(foreground: Color(r: 80, g: 80, b: 80), background: .black))
      }

      // ── Input area (multi-line) ────────────────────────
      let prompt = "> "
      let textWidth = max(0, cols &- prompt.count &- 4)
      let maxInputRows = max(1, inputAreaRows - 1)
      let visualRows = await input.visualRows(width: textWidth, maxRows: maxInputRows)
      let inputStartRow = rows &- inputAreaRows

      // Draw background for input area
      for r in inputStartRow..<rows {
        for c in 0..<cols {
          term.draw(Cell(char: " ", attrs: Attributes(foreground: .white, background: Color(r: 32, g: 32, b: 40))), at: c, row: r)
        }
      }

      // Draw prompt and text
      for (i, rowText) in visualRows.enumerated() {
        let row = inputStartRow &+ i
        guard row < rows else { break }
        if i == 0 {
          term.drawText(prompt + rowText, at: 2, row: row, attrs: Attributes(foreground: .white, background: Color(r: 32, g: 32, b: 40)))
        } else {
          let gutter = String(repeating: " ", count: prompt.count)
          term.drawText(gutter + rowText, at: 2, row: row, attrs: Attributes(foreground: .white, background: Color(r: 32, g: 32, b: 40)))
        }
      }

      // Cursor on last row
      let cursorOn = await input.cursorOn()
      if cursorOn, let lastRowText = visualRows.last {
        let cursorX = 2 &+ (visualRows.count == 1 ? prompt.count : 0) &+ lastRowText.count
        let cursorRow = inputStartRow &+ visualRows.count &- 1
        if cursorRow < rows && cursorX < cols {
          term.draw(Cell(char: "▌", attrs: Attributes(foreground: .white, background: Color(r: 32, g: 32, b: 40))), at: cursorX, row: cursorRow)
        }
      }

      term.present()
      frame &+= 1
      await input.tick()

      try? await Task.sleep(for: .milliseconds(16))
    }
  }
}

actor QuitFlag {
  var shouldQuit = false
  func set() { shouldQuit = true }
  func check() -> Bool { shouldQuit }
}
