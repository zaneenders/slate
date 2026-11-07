import Slate

@main
struct SlateDemo: ScreenApplication {
  private let field = try! TextInput("Edit this text", capacity: 256)
  private var editing = false
  private var amber = false

  static var configuration: ScreenApplicationConfiguration {
    .init(maximumSize: TerminalSize(columns: 160, rows: 60), nodeCapacity: 48)
  }

  mutating func handle(_ key: InputKey, modifiers: KeyModifiers, clipboard: inout Clipboard) -> ScreenUpdate {
    if key == .control(.c) { return .quit }
    if key == .tab && modifiers.isEmpty {
      editing.toggle()
      return .redraw
    }
    if key == .escape {
      if !editing { return .quit }
      editing = false
      return .redraw
    }
    if editing {
      return field.handle(key, modifiers: modifiers, clipboard: &clipboard) == .changed ? .redraw : .none
    }
    guard modifiers.isEmpty else { return .none }
    if key == .scalar("q") { return .quit }
    if key == .scalar(" ") {
      amber.toggle()
      return .redraw
    }
    return .none
  }

  mutating func paste(_ text: UTF8Span) -> ScreenUpdate {
    guard editing else { return .none }
    do { try field.insert(text) } catch { return .none }
    return .redraw
  }

  func render(in size: TerminalSize) -> some Block {
    Column(gap: 1) {
      Text("Slate / Layer 1", style: Style(foreground: amber ? .yellow : .cyan, bold: true))
      Text("Terminal cells, blocks, layout, and ANSI styles.")
      Row {
        Text("Normal  ")
        Text("Bold  ", style: Style(bold: true))
        Text("Dim  ", style: Style(dim: true))
        Text("Underline", style: Style(underlined: true))
      }
      InputBox(field, focused: editing).border("Text input")
      Text(editing ? "Editing: Tab / Esc leaves the field." : "Tab: edit  Space: palette  Q / Esc: quit")
    }.padding(1).border("Slate").frame(width: .fixed(56), height: .fixed(16), alignment: .topLeading)
      .frame(width: .fill, height: .fill)
  }
}
