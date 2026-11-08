/// One-line editable field view. The application owns focus and routes keys and
/// paste to its TextInput. Rendering borrows that state synchronously.
public struct InputBox: Block, ~Sendable {
  public typealias Body = Never
  private let input: TextInput
  private let focused: Bool
  private let placeholder: String
  private let style: Style

  public init(_ input: TextInput, focused: Bool = true, placeholder: String = "", style: Style = Style()) {
    self.input = input
    self.focused = focused
    self.placeholder = placeholder
    self.style = style
  }

  public borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    try builder.inputBox(input, focused: focused, placeholder: placeholder, style: style)
  }
}
