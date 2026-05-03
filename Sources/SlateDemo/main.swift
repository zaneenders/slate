import SlateCore

/// Single-line input buffer.
actor InputBuffer {
  private var text: String = ""
  private var cursorVisible = true
  private var cursorTick: UInt64 = 0

  func append(_ char: Character) {
    text.append(char)
  }

  func backspace() {
    if !text.isEmpty {
      text.removeLast()
    }
  }

  func clear() {
    text = ""
  }

  func currentText() -> String { text }

  func tick() {
    cursorTick &+= 1
    cursorVisible = (cursorTick / 30) % 2 == 0
  }

  func cursorOn() -> Bool { cursorVisible }
}

@main
struct SlateDemo {
  static func main() async throws {
    var term = try Terminal()
    let input = InputBuffer()
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
          guard !event.modifiers.contains(.control) else { continue }
          await input.append(ch)
        case .enter:
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
      let title = "Slate"
      let titleX = max(0, (cols &- title.count) / 2)
      term.drawText(title, at: titleX, row: 1, attrs: Attributes(foreground: .white, background: .black, style: .bold))

      let subtitle = "Enter clears · Esc or Ctrl-C exits"
      let subX = max(0, (cols &- subtitle.count) / 2)
      term.drawText(subtitle, at: subX, row: 2, attrs: Attributes(foreground: Color(r: 150, g: 150, b: 150), background: .black))

      // ── Stats ──────────────────────────────────────────
      let statsText = "frame \(frame)  ·  \(cols)×\(rows)"
      term.drawText(statsText, at: 2, row: 4, attrs: Attributes(foreground: Color(r: 100, g: 100, b: 100), background: .black))

      // ── Sparkles ───────────────────────────────────────
      let sparkleChars: [Unicode.Scalar] = ["·", "+", "*", "∙", "◦", "-", "=", "~"]
      let sparkleColors: [Color] = [.red, .green, .blue, .yellow, .cyan, .magenta, .white]
      for _ in 0..<80 {
        let sx = Int.random(in: 0..<cols)
        let sy = Int.random(in: 6..<rows &- 2)
        let ch = sparkleChars.randomElement()!
        let color = sparkleColors.randomElement()!
        term.draw(Cell(char: ch, attrs: Attributes(foreground: color, background: .black)), at: sx, row: sy)
      }

      // ── Input (bottom, plain text) ─────────────────────
      let text = await input.currentText()
      let prompt = "> "
      let maxTextWidth = cols &- prompt.count &- 3
      let displayText = text.count > maxTextWidth ? String(text.suffix(maxTextWidth)) : text
      let fullText = prompt + displayText

      let inputRow = rows &- 2
      term.drawText(fullText, at: 2, row: inputRow, attrs: Attributes(foreground: .white, background: .black))

      // Cursor
      let cursorOn = await input.cursorOn()
      if cursorOn {
        let cursorX = 2 &+ prompt.count &+ displayText.count
        if cursorX < cols {
          term.draw(Cell(char: "▌", attrs: Attributes(foreground: .white, background: .black)), at: cursorX, row: inputRow)
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
