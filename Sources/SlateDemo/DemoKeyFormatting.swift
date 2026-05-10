import SlateCore

/// Human-readable labels for decoded actions shown in the key-history strip.
enum DemoKeyFormatting {
  static func describe(_ action: TerminalInputAction) -> String {
    switch action {
    case .character(let ch): return ch == " " ? "␠" : String(ch)
    case .enter: return "↵"
    case .shiftEnter: return "⇧↵"
    case .backspace: return "⌫"
    case .tab: return "⇥"
    case .ctrlC: return "^C"
    case .ctrlD: return "^D"
    case .arrowUp: return "↑"
    case .arrowDown: return "↓"
    case .pageUp: return "PgUp"
    case .pageDown: return "PgDn"
    case .home: return "Home"
    case .end: return "End"
    case .escape: return "Esc"
    case .bracketedPasteStart: return "Past+"
    case .bracketedPasteEnd: return "Past-"
    }
  }
}
