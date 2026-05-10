/// Typed key event produced by ``TerminalInputHandler`` after decoding stdin bytes.
/// Unlike raw ``TerminalKeyEvent``, these represent user-intent actions — the host
/// never sees raw terminal escape sequences.
public enum TerminalInputAction: Equatable, Sendable {
  case character(Character)
  case backspace
  /// Shift+Enter.
  case newline
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
  /// Bracketed-paste boundaries — the host can use these to track paste state
  /// and convert `.enter`→`.newline`, suppress `.backspace`, etc. during paste.
  case bracketedPasteStart, bracketedPasteEnd
}

// MARK: - TerminalInputHandler

/// Decodes raw stdin bytes into ``TerminalInputAction`` values.
///
/// Emits every key event as-is, including `.bracketedPasteStart`/`.bracketedPasteEnd`
/// so the host can track paste state.  The handler performs no action conversion —
/// during bracketed paste, Enter is still `.enter`, Backspace is still `.backspace`,
/// and Tab is still `.tab`.  The host decides whether to treat those differently
/// while `inPaste` is true.
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
  private var inPaste = false

  public init() {}

  // MARK: - Decoding

  /// Decode one chunk of raw stdin bytes and return the resulting actions.
  /// Tracks bracketed-paste state so that Enter inside a paste is emitted as
  /// `.newline`, Tab as `.tab`, and Backspace is suppressed.
  public mutating func handle(
    _ chunk: ContiguousArray<UInt8>
  ) -> [TerminalInputAction] {
    var actions: [TerminalInputAction] = []
    var paste = inPaste
    keyDecoder.decode(chunk) { key in
      switch key {
      case .ctrl(3):
        actions.append(.ctrlC)
      case .ctrl(4):
        actions.append(.ctrlD)
      case .bracketedPasteStart:
        paste = true
        actions.append(.bracketedPasteStart)
      case .bracketedPasteEnd:
        paste = false
        actions.append(.bracketedPasteEnd)
      case .character(let ch):
        actions.append(.character(ch))
      case .backspace:
        if !paste { actions.append(.backspace) }
      case .delete:
        break  // Not handled; host may use for other purposes
      case .enter:
        if paste {
          actions.append(.newline)
        } else {
          actions.append(.enter)
        }
      case .escape:
        actions.append(.escape)
      case .shiftEnter:
        actions.append(.newline)
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
    inPaste = paste
    return actions
  }
}
