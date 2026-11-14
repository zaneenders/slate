import SlateApplication

// Child process for managed signal tests. Keep only the field state needed to
// verify that editing, paste, and clipboard operations survive intercepted signals.
@main
struct SlateSignalFixture: ScreenApplication {
  static var configuration: ScreenApplicationConfiguration { .init(enhancedKeyboard: true) }

  private let field = try! TextInput(capacity: 1_024)
  private var focused = false

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .key(let key, let modifiers): return handle(key, modifiers: modifiers, copyBuffer: &copyBuffer)
    case .paste(let text):
      guard focused else { return .none }
      do { try field.insert(text) } catch { return .quit }
      return .redraw
    case .pasteRejected: return .quit
    case .pasteEmpty: return .none
    case .mouse: return .none
    case .tick: return .none
    }
  }

  private mutating func handle(
    _ key: InputKey, modifiers: KeyModifiers, copyBuffer: inout CopyBuffer
  ) -> ScreenUpdate {
    let modifiers = modifiers.withoutLocks
    let controlC = key == .control(.c) || (key == .character("c") && modifiers == .control)
    // Test-only binding: actual Ctrl-Z quits, including while editing.
    if key == .control(.z) || (key == .character("z") && modifiers == .control) {
      return .quit
    }
    if key == .tab, modifiers.isEmpty {
      focused.toggle()
      return .redraw
    }
    if key == .escape {
      focused = false
      return .redraw
    }
    if focused {
      switch field.handle(key, modifiers: modifiers, copyBuffer: &copyBuffer) {
      case .changed, .submit: return .redraw
      case .rejected: return .quit
      case .ignored: return controlC ? .quit : .none
      }
    }
    return controlC || (modifiers.isEmpty && key == .character("q")) ? .quit : .none
  }

  func render(in size: TerminalSize) -> some Block {
    InputBox(field, focused: focused)
  }
}
