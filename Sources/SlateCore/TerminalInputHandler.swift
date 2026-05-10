/// Typed key event produced by ``TerminalInputHandler`` after decoding stdin bytes.
/// Unlike raw ``TerminalKeyEvent``, these represent user-intent actions — the host
/// never sees raw terminal escape sequences.
public enum TerminalInputAction: Equatable, Sendable {
  case character(Character)
  case backspace
  /// Shift+Enter.
  case shiftEnter
  /// Tab key (or literal tab byte).
  case tab
  /// Enter (submit).
  case enter
  case ctrlC
  case ctrlD
  case escape
  case arrowUp, arrowDown
  case pageUp, pageDown
  case home, end
  /// Bracketed-paste boundaries — the host tracks paste state from these
  /// and decides how to treat Enter, Backspace, etc. during paste.
  case bracketedPasteStart, bracketedPasteEnd
}

// MARK: - TerminalInputHandler

/// Decodes raw stdin bytes into ``TerminalInputAction`` values.
///
/// Pure decoder with no editing state — emits every key event as-is.
/// The host tracks `inPaste` from `.bracketedPasteStart`/`.bracketedPasteEnd`
/// and decides whether to treat Enter as a literal newline, suppress
/// Backspace, etc. during paste.
///
/// ```swift
/// var input = TerminalInputHandler()
/// var myBuffer = ""
/// var inPaste = false
/// for await event in pump.events {
///     if case .stdinBytes(let chunk) = event {
///         for action in input.handle(chunk) {
///             switch action {
///             case .bracketedPasteStart: inPaste = true
///             case .bracketedPasteEnd:   inPaste = false
///             case .enter:
///                 if inPaste { myBuffer.append("\n") }
///                 else { submit(myBuffer); myBuffer = "" }
///             case .character(let ch): myBuffer.append(ch)
///             case .backspace: if !inPaste, !myBuffer.isEmpty { myBuffer.removeLast() }
///             case .shiftEnter: myBuffer.append("\n")
///             case .ctrlC:  interrupt()
///             case .ctrlD:  return .stop
///             case .arrowUp: scrollUp()
///             // ...
///             default: break
///             }
///         }
///     }
/// }
/// ```
public struct TerminalInputHandler: Sendable {
  private var keyDecoder = TerminalKeyDecoder()

  public init() {}

  // MARK: - Decoding

  /// Decode one chunk of raw stdin bytes and return the resulting actions.
  /// No side effects — every key is emitted as-is.
  public mutating func handle(
    _ chunk: ContiguousArray<UInt8>
  ) -> [TerminalInputAction] {
    var actions: [TerminalInputAction] = []
    keyDecoder.decode(chunk) { key in
      switch key {
      case .ctrl(3):
        actions.append(.ctrlC)
      case .ctrl(4):
        actions.append(.ctrlD)
      case .bracketedPasteStart:
        actions.append(.bracketedPasteStart)
      case .bracketedPasteEnd:
        actions.append(.bracketedPasteEnd)
      case .character(let ch):
        actions.append(.character(ch))
      case .backspace:
        actions.append(.backspace)
      case .delete:
        break  // Not handled; host may use for other purposes
      case .enter:
        actions.append(.enter)
      case .escape:
        actions.append(.escape)
      case .shiftEnter:
        actions.append(.shiftEnter)
      case .tab:
        actions.append(.tab)
      case .arrowUp: actions.append(.arrowUp)
      case .arrowDown: actions.append(.arrowDown)
      case .pageUp, .ctrl(2): actions.append(.pageUp)
      case .pageDown, .ctrl(6): actions.append(.pageDown)
      case .home: actions.append(.home)
      case .end: actions.append(.end)
      default: break
      }
    }
    return actions
  }
}
