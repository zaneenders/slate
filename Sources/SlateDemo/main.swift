#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import SlateCore

private func terminalWidth(_ ch: Character) -> Int {
  guard let scalar = ch.unicodeScalars.first else { return 1 }
  let w = wcwidth(Int32(scalar.value))
  return w >= 0 ? Int(w) : 1
}

private func columnWidth(_ s: String) -> Int {
  s.reduce(0) { $0 + terminalWidth($1) }
}

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
      } else if ch == "\r" {
        // Ignore lone CR so CRLF pastes normalize to a single newline.
        continue
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
          var cols = 0
          var count = 0
          for ch in remaining {
            let w = terminalWidth(ch)
            if cols + w > width { break }
            cols += w
            count += 1
          }
          let take = max(1, count)
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

/// Chat history with scrollback.
actor History {
  private var entries: [String] = []
  private var scrollOffset: Int = 0

  func append(_ text: String) {
    entries.append(text)
    if entries.count > 500 {
      entries.removeFirst(entries.count - 500)
    }
    scrollOffset = 0
  }

  func scrollUp(lines: Int = 5) {
    scrollOffset += lines
  }

  func scrollDown(lines: Int = 5) {
    scrollOffset = max(0, scrollOffset - lines)
  }

  func resetScroll() {
    scrollOffset = 0
  }

  func currentOffset() -> Int { scrollOffset }
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
          await history.resetScroll()
        case .enter where !event.modifiers.isEmpty:
          // Shift+Enter, Alt+Enter, etc. → soft newline
          await input.newline()
          await history.resetScroll()
        case .enter:
          // Plain Enter → submit
          let text = await input.flatText()
          if !text.isEmpty {
            await history.append(text)
          }
          await input.clear()
          await history.resetScroll()
        case .backspace:
          await input.backspace()
          await history.resetScroll()
        case .pageUp:
          await history.scrollUp(lines: 5)
        case .pageDown:
          await history.scrollDown(lines: 5)
        case .scrollUp:
          await history.scrollUp(lines: 3)
        case .scrollDown:
          await history.scrollDown(lines: 3)
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
      let title = "Slate Chat"
      let titleX = max(0, (cols &- title.count) / 2)
      term.drawText(title, at: titleX, row: 1, attrs: Attributes(foreground: .white, background: .black, style: .bold))

      let subtitle = "Enter submits · Shift+Enter newline · PgUp/PgDn scroll · Esc exits"
      let subX = max(0, (cols &- subtitle.count) / 2)
      term.drawText(subtitle, at: subX, row: 2, attrs: Attributes(foreground: Color(r: 150, g: 150, b: 150), background: .black))

      // ── Layout ─────────────────────────────────────────
      let headerRows = 4
      let inputAreaRows = min(6, rows / 5)
      let chatStartRow = headerRows
      let chatEndRow = rows &- inputAreaRows &- 1
      let chatVisibleRows = max(0, chatEndRow &- chatStartRow)

      // ── Sparkles (chat background) ─────────────────────
      if chatVisibleRows > 0 && cols > 0 {
        let sparkleChars: [Unicode.Scalar] = ["·", "+", "*", "∙", "◦", "-", "=", "~"]
        let sparkleColors: [Color] = [.red, .green, .blue, .yellow, .cyan, .magenta, .white]
        let sparkleCount = min(120, max(0, cols &* chatVisibleRows / 6))
        for _ in 0..<sparkleCount {
          let sx = Int.random(in: 0..<cols)
          let sy = Int.random(in: chatStartRow..<chatEndRow)
          let ch = sparkleChars.randomElement()!
          let color = sparkleColors.randomElement()!
          term.draw(Cell(char: ch, attrs: Attributes(foreground: color, background: .black)), at: sx, row: sy)
        }
      }

      // ── Chat history ───────────────────────────────────
      let historyEntries = await history.all()
      let scrollOffset = await history.currentOffset()

      // (text, msgIdx) — msgIdx == -1 for blank separator rows between messages
      var allWrapped: [(text: String, msgIdx: Int)] = []
      let wrapWidth = max(1, cols &- 4)
      for (msgIdx, entry) in historyEntries.enumerated() {
        let entryLines = entry.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in entryLines {
          if line.isEmpty {
            allWrapped.append(("", msgIdx))
          } else {
            var remaining = line
            while !remaining.isEmpty {
              var w = 0
              var count = 0
              for ch in remaining {
                let cw = terminalWidth(ch)
                if w + cw > wrapWidth { break }
                w += cw
                count += 1
              }
              let take = max(1, count)
              allWrapped.append((String(remaining.prefix(take)), msgIdx))
              remaining = String(remaining.dropFirst(take))
            }
          }
        }
        allWrapped.append(("", -1))
      }

      let maxScroll = max(0, allWrapped.count &- chatVisibleRows)
      let effectiveScroll = min(scrollOffset, maxScroll)
      let viewportBottom = allWrapped.count &- effectiveScroll
      let viewportTop = max(0, viewportBottom &- chatVisibleRows)
      let visibleEnd = min(allWrapped.count, viewportBottom)
      let visibleLines = Array(allWrapped[viewportTop..<visibleEnd])

      let msgBubbleColors: [Color] = [
        Color(r: 25, g: 45, b: 65),
        Color(r: 45, g: 25, b: 65),
      ]
      for (i, (lineText, msgIdx)) in visibleLines.enumerated() {
        let row = chatStartRow &+ i
        guard row < chatEndRow else { break }
        let bg = msgIdx >= 0 ? msgBubbleColors[msgIdx % msgBubbleColors.count] : .black
        for c in 0..<cols {
          term.draw(Cell(char: " ", attrs: Attributes(foreground: .default, background: bg)), at: c, row: row)
        }
        if !lineText.isEmpty {
          term.drawText("  " + lineText, at: 2, row: row, attrs: Attributes(foreground: .cyan, background: bg))
        }
      }

      // ── Separator ──────────────────────────────────────
      let sepRow = rows &- inputAreaRows &- 1
      if sepRow >= headerRows {
        let sepText = String(repeating: "─", count: max(0, cols &- 4))
        term.drawText(sepText, at: 2, row: sepRow, attrs: Attributes(foreground: Color(r: 80, g: 80, b: 80), background: .black))
        if effectiveScroll > 0 {
          let scrollHint = " ↑ scrollback ↑ "
          let hintX = max(2, (cols &- scrollHint.count) / 2)
          term.drawText(scrollHint, at: hintX, row: sepRow, attrs: Attributes(foreground: .yellow, background: .black, style: .bold))
        }
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
        let cursorX = 2 &+ prompt.count &+ columnWidth(lastRowText)
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
