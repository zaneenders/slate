public import SlateUI

public enum InputDecodingError: Error, Equatable, Sendable {
  case invalidUTF8
  /// An unsupported or malformed CSI, SS3 or APC sequence.
  case unknownSequence
  case sequenceTooLong
  /// Input ended after a CSI, SS3 or APC prefix, before its terminator arrived.
  case incompleteSequence
}

public enum InputEvent: Equatable, Sendable {
  case key(InputKey)
  case invalid(InputDecodingError)
  case terminalReply(TerminalReply)
  case modifiedKey(InputKey, KeyModifiers)
  case paste(PasteEvent)
  case mouse(MouseEvent)
}

public enum TerminalReply: Equatable, Sendable {
  /// Read the decoder/input owner's applicationCommand before requesting more input.
  case applicationCommand
  case primaryAttributes
}

public struct InputDecodingProgress: Equatable, Sendable {
  public let bytesConsumed: Int
  public let eventsWritten: Int
}

/// A synchronous decoder with inline storage and no retained input/output views.
/// Work is linear in the supplied bytes plus the output capacity. Timing and I/O
/// belong to the caller; chunk boundaries never implicitly flush pending input.
public struct InputDecoder: ~Copyable, Sendable {
  /// Includes the two-byte introducer and final byte of a CSI sequence.
  public static let maximumSequenceBytes = 32

  private enum State: Equatable, Sendable {
    case ground, finished
    case utf8
    case escape
    case csi
    case ss3
    case discardCSI
    case apc, apcEscape, discardAPC, discardAPCEscape
    case paste
  }

  private var sequence = InlineArray<32, UInt8>(repeating: 0)
  private var sequenceByteCount = 0
  private var utf8 = IncrementalUTF8Decoder()
  /// Payload for the latest command event; valid until the next decode call.
  /// Only command consumers copy this snapshot, keeping ordinary key events small.
  public private(set) var applicationCommand = ApplicationCommand()
  private var state: State = .ground
  private var pastePrefix = 0
  private var pasteLiteralIndex = 0
  private var pasteLiteralCount = 0
  private let pasteEnd: InlineArray<6, UInt8> = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]

  public init() {}

  /// Includes oversized CSI/APC sequences whose tails are being discarded.
  public var hasPendingInput: Bool { state != .ground && state != .finished }

  /// A caller may apply its Escape deadline only while this is true.
  public var hasPendingEscape: Bool { state == .escape }

  // With no held delimiter prefix or queued literal, bytes preceding the next ESC are pure payload.
  var canReadLiteralPaste: Bool {
    state == .paste && pastePrefix == 0 && pasteLiteralIndex == pasteLiteralCount
  }

  public var hasPendingTerminalResponse: Bool {
    state == .apc || state == .apcEscape || state == .discardAPC || state == .discardAPCEscape
  }

  /// Only the reported prefix of `events` is modified. At capacity, stops before
  /// inspecting another byte. Resume with the unconsumed suffix of `bytes` and
  /// reusable output storage. Empty input or output makes no progress. A complete
  /// APC command ends this call so its payload can be read before another command.
  ///
  /// Recovery may emit an event without consuming the next byte: for example, an
  /// invalid UTF-8 prefix followed by ASCII. Retain that byte when resuming.
  public mutating func decode(
    _ bytes: Span<UInt8>, into events: consuming MutableSpan<InputEvent>
  ) -> InputDecodingProgress {
    precondition(state != .finished, "Cannot decode after end of input")
    var events = consume events
    var bytesConsumed = 0
    var eventsWritten = 0
    while bytesConsumed < bytes.count && eventsWritten < events.count {
      let byte = bytes[bytesConsumed]
      // Ordinary terminal text needs no protocol/framing result. Keep command
      // boundaries off this common path; paste and partial sequences still use next.
      if state == .ground && (0x20...0x7e).contains(byte) {
        events[eventsWritten] = .key(.character(Unicode.Scalar(byte)))
        bytesConsumed += 1
        eventsWritten += 1
        continue
      }
      let step = next(byte)
      if step.consumesByte { bytesConsumed += 1 }
      if let event = step.event {
        events[eventsWritten] = event
        eventsWritten += 1
      }
      // Each iteration consumes one byte or emits one event, bounding recovery.
      assert(step.consumesByte || step.event != nil)
      if step.endsCommand { break }
    }
    return InputDecodingProgress(bytesConsumed: bytesConsumed, eventsWritten: eventsWritten)
  }

  /// End of input only. Returns at most one event and closes the decoder.
  /// A lone ESC becomes Escape; truncated UTF-8
  /// becomes invalidUTF8; unfinished CSI/SS3 becomes incompleteSequence. An
  /// oversized sequence was already reported, so its discarded tail emits nil.
  /// Do not call for a deadline or merely because a read returned zero. Repeated
  /// finish calls return nil; decoding after finish violates a precondition.
  public mutating func finish() -> InputEvent? {
    let event: InputEvent?
    switch state {
    case .ground, .finished, .discardCSI, .discardAPC, .discardAPCEscape: event = nil
    case .escape: event = .key(.escape)
    case .utf8: event = .invalid(.invalidUTF8)
    case .csi, .ss3, .apc, .apcEscape: event = .invalid(.incompleteSequence)
    case .paste: event = .paste(.cancelled)
    }
    state = .finished
    return event
  }

  package mutating func expireEscape() -> InputEvent? {
    guard state == .escape else { return nil }
    reset()
    return .key(.escape)
  }

  /// Preserve framing, including a partially received ST, while dropping payload.
  package mutating func discardTerminalResponse() {
    precondition(hasPendingTerminalResponse)
    state = state == .apcEscape || state == .discardAPCEscape ? .discardAPCEscape : .discardAPC
    applicationCommand = ApplicationCommand()
  }

  private struct Step {
    let event: InputEvent?
    let consumesByte: Bool
    let endsCommand: Bool

    init(_ event: InputEvent? = nil, consumesByte: Bool = true, endsCommand: Bool = false) {
      self.event = event
      self.consumesByte = consumesByte
      self.endsCommand = endsCommand
    }
  }

  // Keep state dispatch in decode's loop, avoiding a call for every input byte.
  @inline(always)
  private mutating func next(_ byte: UInt8) -> Step {
    switch state {
    case .finished: preconditionFailure("Cannot decode after end of input")
    case .ground:
      return start(byte)
    case .paste:
      return continuePaste(byte)
    case .utf8:
      switch utf8.append(byte) {
      case .pending:
        return Step()
      case .scalar(let scalar):
        reset()
        return Step(.key(.character(scalar)))
      case .invalid:
        // Report the maximal valid prefix, then reconsider the offending byte.
        reset()
        return Step(.invalid(.invalidUTF8), consumesByte: false)
      }
    case .escape:
      switch byte {
      case 0x5b: state = .csi  // ESC [
      case 0x4f: state = .ss3  // ESC O
      case 0x5f:
        applicationCommand = ApplicationCommand()
        state = .apc  // ESC _ (application command)
      default:
        // ESC-prefixed ordinary input is Escape followed by the original key.
        // Alt/Meta interpretation is deliberately left to a higher layer.
        reset()
        return Step(.key(.escape), consumesByte: false)
      }
      sequence[1] = byte
      sequenceByteCount = 2
      return Step()
    case .csi, .ss3:
      return continueSequence(byte)
    case .apc:
      if byte == 0x1b {
        state = .apcEscape
        return Step()
      }
      guard (32...126).contains(byte) else {
        state = .discardAPC
        return Step(.invalid(.unknownSequence))
      }
      applicationCommand.append(byte)
      return Step()
    case .apcEscape:
      guard byte == 0x5c else {
        state = byte == 0x1b ? .discardAPCEscape : .discardAPC
        return Step(.invalid(.unknownSequence))
      }
      let hasPayload = applicationCommand.count > 0
      reset()
      return Step(
        hasPayload ? .terminalReply(.applicationCommand) : .invalid(.unknownSequence), endsCommand: hasPayload)
    case .discardAPC:
      if byte == 0x1b { state = .discardAPCEscape }
      return Step()
    case .discardAPCEscape:
      if byte == 0x5c { reset() } else if byte != 0x1b { state = .discardAPC }
      return Step()
    case .discardCSI:
      if (0x40...0x7e).contains(byte) {
        reset()
      } else if !(0x20...0x3f).contains(byte) {
        reset()
        // An ESC or unrelated control/UTF-8 byte can start fresh input.
        return start(byte)
      }
      return Step()
    }
  }

  private mutating func start(_ byte: UInt8) -> Step {
    assert(state == .ground)
    switch byte {
    case 0x08, 0x7f: return Step(.key(.backspace))
    case 0x09: return Step(.key(.tab))
    case 0x0a, 0x0d: return Step(.key(.enter))
    case 0x1b:
      sequence[0] = byte
      sequenceByteCount = 1
      state = .escape
      return Step()
    case 0x00...0x1f:
      // ControlKey covers every C0 byte; dedicated cases take precedence above.
      guard let control = ControlKey(rawValue: byte) else {
        preconditionFailure("Missing C0 control key")
      }
      return Step(.key(.control(control)))
    case 0x20...0x7e: return Step(.key(.character(Unicode.Scalar(byte))))
    default:
      guard case .pending = utf8.append(byte) else { return Step(.invalid(.invalidUTF8)) }
      state = .utf8
      return Step()
    }
  }

  private mutating func continueSequence(_ byte: UInt8) -> Step {
    let isFinal = (0x40...0x7e).contains(byte)
    let isBody = state == .csi && (0x20...0x3f).contains(byte)
    guard isFinal || isBody else {
      reset()
      return Step(.invalid(.unknownSequence), consumesByte: false)
    }
    assert(sequenceByteCount >= 2 && sequenceByteCount <= sequence.count)
    guard sequenceByteCount < sequence.count else {
      // Emit exactly once, then discard CSI bytes through the final byte.
      reset()
      if !isFinal { state = .discardCSI }
      return Step(.invalid(.sequenceTooLong))
    }
    sequence[sequenceByteCount] = byte
    sequenceByteCount += 1
    guard isFinal else { return Step() }
    if state == .csi, sequenceByteCount == 6,
      sequence[2] == 0x32, sequence[3] == 0x30, sequence[4] == 0x30, byte == 0x7e
    {
      reset()
      state = .paste
      return Step(.paste(.begin))
    }
    if state == .csi, byte == 0x63, sequenceByteCount >= 4, sequence[2] == 0x3f {
      reset()
      return Step(.terminalReply(.primaryAttributes))
    }
    let key: InputEvent?
    if state == .csi, byte == 0x75 {
      key = unicodeKeyEvent()
    } else if state == .csi, sequence[2] == 0x3c {
      key = mouseEvent(final: byte)
    } else {
      key = sequenceEvent(final: byte)
    }
    reset()
    if let key { return Step(key) }
    return Step(.invalid(.unknownSequence))
  }

  private borrowing func sequenceEvent(final: UInt8) -> InputEvent? {
    var first = 0
    var modifier = 1
    var hasModifier = false
    if sequenceByteCount > 3 {
      guard state == .csi, let fields = decimalFields(from: 2, limits: [24, 256, 0]) else { return nil }
      first = fields.values[0]
      hasModifier = fields.count == 2
      modifier = hasModifier ? fields.values[1] : 1
    }
    guard (1...256).contains(modifier) else { return nil }
    var modifiers = KeyModifiers(rawValue: UInt8(modifier - 1))
    let key: InputKey
    if final != 0x7e {
      guard sequenceByteCount == 3 || (hasModifier && first == 1) else { return nil }
      // Normal (CSI) and application (SS3) cursor keys share final bytes.
      switch final {
      case 0x41: key = .up
      case 0x42: key = .down
      case 0x43: key = .right
      case 0x44: key = .left
      case 0x48: key = .home
      case 0x46: key = .end
      case 0x50: key = .function(.f1)
      case 0x51: key = .function(.f2)
      case 0x52: key = .function(.f3)
      case 0x53: key = .function(.f4)
      case 0x5a where state == .csi:
        key = .tab
        modifiers.insert(.shift)
      case 0x4d where state == .ss3: key = .enter
      default: return nil
      }
    } else {
      guard state == .csi else { return nil }
      switch first {
      case 1, 7: key = .home
      case 2: key = .insert
      case 3: key = .delete
      case 4, 8: key = .end
      case 5: key = .pageUp
      case 6: key = .pageDown
      case 11: key = .function(.f1)
      case 12: key = .function(.f2)
      case 13: key = .function(.f3)
      case 14: key = .function(.f4)
      case 15: key = .function(.f5)
      case 17: key = .function(.f6)
      case 18: key = .function(.f7)
      case 19: key = .function(.f8)
      case 20: key = .function(.f9)
      case 21: key = .function(.f10)
      case 23: key = .function(.f11)
      case 24: key = .function(.f12)
      default: return nil
      }
    }
    return modifiers.isEmpty ? .key(key) : .modifiedKey(key, modifiers)
  }

  /// CSI u keys from Kitty's disambiguate-escape-codes enhancement. Other
  /// enhancements (alternate keys, release events and associated text) are not
  /// requested, so accepting their extra fields would lose input information.
  private borrowing func unicodeKeyEvent() -> InputEvent? {
    guard let fields = decimalFields(from: 2, limits: [0x10ffff, 256, 0]) else { return nil }
    let codepoint = UInt32(fields.values[0])
    let modifier = fields.count == 2 ? fields.values[1] : 1
    guard (1...256).contains(modifier) else { return nil }
    let key: InputKey
    switch codepoint {
    case 9: key = .tab
    case 13: key = .enter
    case 27: key = .escape
    case 127: key = .backspace
    // Disambiguation gives keypad keys distinct codes. Preserve their ordinary
    // equivalents in InputKey, which does not distinguish keypad locations.
    case 57399...57408: key = .character(Unicode.Scalar(UInt8(codepoint - 57399 + 48)))
    case 57409: key = .character(".")
    case 57410: key = .character("/")
    case 57411: key = .character("*")
    case 57412: key = .character("-")
    case 57413: key = .character("+")
    case 57414: key = .enter
    case 57415: key = .character("=")
    case 57416: key = .character(",")
    case 57417: key = .left
    case 57418: key = .right
    case 57419: key = .up
    case 57420: key = .down
    case 57421: key = .pageUp
    case 57422: key = .pageDown
    case 57423: key = .home
    case 57424: key = .end
    case 57425: key = .insert
    case 57426: key = .delete
    case 0x20...0x7e, 0xa0...0xd7ff, 0xe000...0x10ffff:
      guard let scalar = Unicode.Scalar(codepoint), !(57344...63743).contains(codepoint) else {
        return nil
      }
      key = .character(scalar)
    default: return nil
    }
    let modifiers = KeyModifiers(rawValue: UInt8(modifier - 1))
    return modifiers.isEmpty ? .key(key) : .modifiedKey(key, modifiers)
  }

  // Keep decimal mouse parsing out of the per-byte UTF-8/keyboard dispatch.
  @inline(never)
  private borrowing func mouseEvent(final: UInt8) -> InputEvent? {
    guard final == 0x4d || final == 0x6d else { return nil }
    guard let parsed = decimalFields(from: 3, limits: [127, 65_535, 65_535]), parsed.count == 3 else { return nil }
    let fields = parsed.values
    guard fields[1] > 0, fields[2] > 0 else { return nil }
    let code = fields[0]
    let button: MouseButton
    switch code & 3 {
    case 0: button = .left
    case 1: button = .middle
    case 2: button = .right
    default: button = .none
    }
    let action: MouseAction
    if code & 64 != 0 {
      guard code & 32 == 0, final == 0x4d else { return nil }
      switch code & 3 {
      case 0: action = .scrollUp
      case 1: action = .scrollDown
      case 2: action = .scrollLeft
      default: action = .scrollRight
      }
    } else if code & 32 != 0 {
      guard final == 0x4d else { return nil }
      action = .move
    } else {
      guard button != .none else { return nil }
      action = final == 0x4d ? .press : .release
    }
    return .mouse(
      MouseEvent(
        action: action, button: code & 64 != 0 ? .none : button,
        column: fields[1] - 1, row: fields[2] - 1,
        modifiers: KeyModifiers(rawValue: UInt8((code >> 2) & 7))))
  }

  // A zero limit disables that field. Per-digit bounds keep multiplication safe
  // while callers retain their protocol-specific arity and zero-value rules.
  private borrowing func decimalFields(
    from start: Int, limits: InlineArray<3, Int>
  ) -> (values: InlineArray<3, Int>, count: Int)? {
    var values = InlineArray<3, Int>(repeating: 0)
    var field = 0
    var sawDigit = false
    for index in start..<(sequenceByteCount - 1) {
      let byte = sequence[index]
      if byte == 0x3b, sawDigit, field < 2, limits[field + 1] > 0 {
        field += 1
        sawDigit = false
      } else if (0x30...0x39).contains(byte) {
        values[field] = values[field] * 10 + Int(byte - 0x30)
        guard values[field] <= limits[field] else { return nil }
        sawDigit = true
      } else {
        return nil
      }
    }
    return sawDigit ? (values, field + 1) : nil
  }

  private mutating func continuePaste(_ byte: UInt8) -> Step {
    // Release a mismatched delimiter prefix without consuming the next byte.
    // At most five bytes are retained; every step consumes or emits progress.
    if pasteLiteralIndex < pasteLiteralCount {
      let literal = pasteEnd[pasteLiteralIndex]
      pasteLiteralIndex += 1
      return Step(.paste(.byte(literal)), consumesByte: false)
    }
    if byte == pasteEnd[pastePrefix] {
      pastePrefix += 1
      if pastePrefix == pasteEnd.count {
        reset()
        return Step(.paste(.end))
      }
      return Step()
    }
    if pastePrefix > 0 {
      pasteLiteralCount = pastePrefix
      pasteLiteralIndex = 1
      pastePrefix = 0
      return Step(.paste(.byte(0x1b)), consumesByte: false)
    }
    return Step(.paste(.byte(byte)))
  }

  private mutating func reset() {
    state = .ground
    sequenceByteCount = 0
    utf8.reset()
    pastePrefix = 0
    pasteLiteralIndex = 0
    pasteLiteralCount = 0
  }

}
