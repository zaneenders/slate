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
  private var editMessage: String?

  func render(in size: TerminalSize) -> some Block {
    Column(gap: 1) {
      Text("Hello, Slate!", style: Style(foreground: .cyan, bold: true))
      InputBox(input, placeholder: "Type a message...")
        .border("Input", style: Style(foreground: .cyan))
      Text(submittedText, style: Style(foreground: .green))
        .border("Submitted text", style: Style(foreground: .green))
      if let editMessage {
        Text(editMessage, style: Style(foreground: .yellow))
      } else {
        Text("Ctrl-A selects all / Ctrl-C copies selection / Enter submits / Escape quits", style: Style(dim: true))
      }
    }.padding(1)
  }

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .key(.escape, _):
      return .quit
    case .key(let key, let modifiers):
      switch input.handle(key, modifiers: modifiers, copyBuffer: &copyBuffer) {
      case .submit:
        // Take a snapshot only when Enter is pressed.
        submittedText = input.snapshot()
        editMessage = nil
        return .redraw
      case .changed:
        editMessage = nil
        return .redraw
      case .rejected(let error): return reject(error)
      case .ignored:
        let controlC = key == .control(.c) || (key == .character("c") && modifiers.withoutLocks == .control)
        return controlC ? .quit : .none
      }
    case .paste(let text):
      do { try input.insert(text) } catch { return reject(error) }
      editMessage = nil
      return .redraw
    case .pasteRejected(let error):
      switch error {
      case .tooLarge: editMessage = "Paste exceeds the session limit."
      case .incomplete: editMessage = "Paste was interrupted."
      case .invalidUTF8: editMessage = "Paste contains invalid UTF-8."
      }
      return .redraw
    default:
      return .none
    }
  }

  private mutating func reject(_ error: TextInputError) -> ScreenUpdate {
    switch error {
    case .capacityExceeded: editMessage = "Input is limited to \(input.capacity) bytes."
    case .invalidControl: editMessage = "Input contains an unsupported control character."
    case .invalidCapacity: editMessage = "Invalid input capacity."
    }
    return .redraw
  }
}
