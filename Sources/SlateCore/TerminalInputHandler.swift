/// Typed key event produced by ``TerminalInputHandler`` after decoding stdin bytes.
/// Unlike raw ``TerminalKeyEvent``, these represent user-intent actions — the host
/// never sees raw terminal escape sequences.
public enum TerminalInputAction: Equatable, Sendable {
  case character(Character)
  case backspace
  /// Shift+Enter, or Enter pressed during bracketed paste.
  case newline
  /// Tab pressed during bracketed paste (expands to spaces).
  case tab
  /// Enter pressed outside bracketed paste (submit).
  case enter
  case ctrlC
  case ctrlD
  case arrowUp, arrowDown
  case pageUp, pageDown
  case home, end
}

// MARK: - TerminalInputHandler

/// Owns the input buffer, paste-tracking flag, and ``TerminalKeyDecoder``.
///
/// Call ``handle(_:)`` with each stdin chunk from the wake pump. The returned
/// array of ``TerminalInputAction`` values describes what happened so the host
/// can dispatch to submit logic, viewport scrolling, etc.
///
/// ```swift
/// var input = TerminalInputHandler()
/// for await event in pump.events {
///     if case .stdinBytes(let chunk) = event {
///         for action in input.handle(chunk) {
///             switch action {
///             case .enter:
///                 let text = input.takeBuffer()
///                 submit(text)
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
  public private(set) var buffer: String = ""
  private var keyDecoder = TerminalKeyDecoder()
  private var inPaste = false

  public init() {}

  // MARK: - Decoding

  /// Decode one chunk of raw stdin bytes and return the resulting actions.
  ///
  /// The input buffer is mutated in-place for character insertions, backspace,
  /// and paste-mode newlines/tabs.
  public mutating func handle(
    _ chunk: ContiguousArray<UInt8>
  ) -> [TerminalInputAction] {
    var actions: [TerminalInputAction] = []
    var paste = inPaste  // Local copy for mutation inside the closure
    keyDecoder.decode(chunk) { key in
      switch key {
      case .ctrl(3):
        actions.append(.ctrlC)
      case .ctrl(4):
        actions.append(.ctrlD)
      case .bracketedPasteStart:
        paste = true
      case .bracketedPasteEnd:
        paste = false
      case .character(let ch):
        actions.append(.character(ch))
      case .backspace:
        if !paste { actions.append(.backspace) }
      case .delete:
        break  // Not handled as a buffer mutation; host may use for other purposes
      case .enter:
        if paste {
          actions.append(.newline)
        } else {
          actions.append(.enter)
        }
      case .shiftEnter:
        actions.append(.newline)
      case .tab:
        if paste { actions.append(.tab) }
      case .arrowUp:   actions.append(.arrowUp)
      case .arrowDown: actions.append(.arrowDown)
      case .pageUp, .ctrl(2): actions.append(.pageUp)
      case .pageDown, .ctrl(6): actions.append(.pageDown)
      case .home: actions.append(.home)
      case .end: actions.append(.end)
      default: break
      }
    }
    inPaste = paste
    // Apply buffer mutations after decode (since closure can't mutate self)
    applyBufferMutations(actions)
    return actions
  }

  // MARK: - Buffer management

  /// Take the current buffer contents and clear it (for submission).
  public mutating func takeBuffer() -> String {
    let text = buffer
    buffer = ""
    return text
  }

  /// Replace the buffer contents (used when Ctrl+C recalls a queued message).
  public mutating func setBuffer(_ text: String) {
    buffer = text
  }

  // MARK: - Private

  /// Apply character insertions, backspaces, and paste-mode newlines/tabs to the buffer.
  private mutating func applyBufferMutations(_ actions: [TerminalInputAction]) {
    for action in actions {
      switch action {
      case .character(let ch): buffer.append(ch)
      case .backspace: if !buffer.isEmpty { buffer.removeLast() }
      case .newline: buffer.append("\n")
      case .tab: buffer.append("    ")
      default: break
      }
    }
  }
}
