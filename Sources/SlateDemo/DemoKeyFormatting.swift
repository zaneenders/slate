import SlateCore

/// Human-readable labels for decoded ``TerminalKeyEvent`` values shown in the key-history strip.
enum DemoKeyFormatting {
  static func describe(_ event: TerminalKeyEvent) -> String {
    switch event {
    case .character(let ch): return ch == " " ? "␠" : String(ch)
    case .enter: return "↵"
    case .shiftEnter: return "⇧↵"
    case .backspace: return "⌫"
    case .tab: return "⇥"
    case .escape: return "Esc"
    case .arrowUp: return "↑"
    case .arrowDown: return "↓"
    case .arrowLeft: return "←"
    case .arrowRight: return "→"
    case .pageUp: return "PgUp"
    case .pageDown: return "PgDn"
    case .home: return "Home"
    case .end: return "End"
    case .ctrl(let b) where b == 3: return "^C"
    case .ctrl(let b) where b == 4: return "^D"
    case .ctrl(let b) where b >= 1 && b <= 26:
      return "^\(Character(UnicodeScalar(64 &+ b)))"
    case .ctrl(let b): return "^[\(b)]"
    case .bracketedPasteStart: return "paste↓"
    case .bracketedPasteEnd: return "paste↑"
    case .unknown: return "?"
    }
  }
}
