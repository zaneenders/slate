import Slate

@main
struct SlateStarter: ScreenApplication {
  static func main() async {
    var application = Self()
    let session = ScreenSession(maximumOutputBytes: 4 * 1_048_576, taskCapacity: 0)
    await session.main(
      application: &application, inputFileDescriptor: 0, outputFileDescriptor: 1, signalHandling: .managed)
  }

  private let input = try! TextInput()
  private var submittedText = ""

  func render(in size: TerminalSize) -> some Block {
    Column(gap: 1) {
      Text("Hello, Slate!", style: Style(foreground: .cyan, bold: true))
      InputBox(input, placeholder: "Type a message...")
        .border("Input", style: Style(foreground: .cyan))
      Text(submittedText, style: Style(foreground: .green))
        .border("Submitted text", style: Style(foreground: .green))
      Text("Enter: submit / Escape: quit", style: Style(dim: true))
    }.padding(1)
  }

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .key(.escape, _), .key(.control(.c), _):
      return .quit
    case .key(let key, let modifiers):
      if key == .character("c") && modifiers.withoutLocks == .control { return .quit }
      switch input.handle(key, modifiers: modifiers, copyBuffer: &copyBuffer) {
      case .submit:
        // Take a snapshot only when Enter is pressed.
        submittedText = input.snapshot()
        return .redraw
      case .changed:
        return .redraw
      case .ignored, .rejected:
        return .none
      }
    case .paste(let text):
      do { try input.insert(text) } catch { return .none }
      return .redraw
    default:
      return .none
    }
  }
}
