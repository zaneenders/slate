import SlateApplication

// Child process for managed signal tests. Keep only the field state needed to
// verify that editing, paste, and clipboard operations survive suspension.
@main
struct SlateSignalFixture: ScreenApplication {
  private let field = try! TextInput(capacity: 1_024)
  private var focused = false

  mutating func handle(_ key: InputKey, modifiers: KeyModifiers, clipboard: inout Clipboard) -> ScreenUpdate {
    if key == .tab, modifiers.isEmpty {
      focused.toggle()
      return .redraw
    }
    if key == .escape {
      focused = false
      return .redraw
    }
    if focused {
      switch field.handle(key, modifiers: modifiers, clipboard: &clipboard) {
      case .changed, .submit: return .redraw
      case .rejected: return .quit
      case .ignored: return key == .control(.c) ? .quit : .none
      }
    }
    return modifiers.isEmpty && (key == .scalar("q") || key == .control(.c)) ? .quit : .none
  }

  mutating func paste(_ text: UTF8Span) -> ScreenUpdate {
    guard focused else { return .none }
    // Rejection ends the fixture; the parent detects missing expected output.
    do { try field.insert(text) } catch { return .quit }
    return .redraw
  }

  mutating func pasteRejected(_ error: PasteError) -> ScreenUpdate { .quit }

  func render(in size: TerminalSize) -> some Block {
    InputBox(field, focused: focused)
  }
}
