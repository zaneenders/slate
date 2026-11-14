import BasicContainers

public enum TextInputError: Error, Equatable, Sendable {
  case invalidCapacity
  case capacityExceeded
  case invalidControl
}

public enum TextInputAction: Equatable, Sendable {
  case ignored, changed, submit
  case rejected(TextInputError)
}

/// Long-lived field identity shared with its synchronous InputBox views. This
/// owner is deliberately not Sendable. Do not mutate it while a borrowed view
/// of its text is live. Both buffers are allocated at initialization (2*capacity
/// bytes); editing, selection, and drawing never grow them.
public final class TextInput: ~Sendable {
  public static let maximumCapacity = 65_536
  public let capacity: Int
  private var bytes: RigidArray<UInt8>
  private var scratch: RigidArray<UInt8>
  public private(set) var byteCount = 0
  public private(set) var cursorByteOffset = 0
  private var anchor: Int?

  public init(_ text: String = "", capacity: Int = 4_096) throws(TextInputError) {
    guard (1...Self.maximumCapacity).contains(capacity) else { throw .invalidCapacity }
    self.capacity = capacity
    bytes = RigidArray(repeating: 0, count: capacity)
    scratch = RigidArray(repeating: 0, count: capacity)
    try insert(text.utf8Span)
  }

  public var selection: Range<Int> {
    min(anchor ?? cursorByteOffset, cursorByteOffset)..<max(anchor ?? cursorByteOffset, cursorByteOffset)
  }

  /// The view is valid only during this synchronous callback. Mutating the field
  /// while its storage is borrowed is forbidden by Swift's exclusive-access rule.
  public func withText<Result, Failure: Error>(
    _ body: (UTF8Span) throws(Failure) -> Result
  ) throws(Failure) -> Result {
    try withInputText(bytes, count: byteCount, body: body)
  }

  /// An explicitly allocating snapshot for use outside the editing/render loop.
  public func snapshot() -> String { withText { String(copying: $0) } }

  public func selectAll() {
    anchor = 0
    cursorByteOffset = byteCount
  }

  /// Atomic replacement: errors leave text and selection unchanged. CR, LF and
  /// TAB become spaces in this single-line field; other C0/C1 controls reject.
  public func insert(_ text: UTF8Span) throws(TextInputError) {
    let range = selection
    guard text.count <= capacity - (byteCount - range.count) else { throw .capacityExceeded }
    var scalars = text.makeUnicodeScalarIterator()
    while let scalar = scalars.next() {
      let value = scalar.value
      guard value >= 0x20 && !(0x7f...0x9f).contains(value) || value == 9 || value == 10 || value == 13 else {
        throw .invalidControl
      }
    }
    // Stage normalization before shifting or mutating live text.
    let source = text.span
    for index in 0..<source.count {
      let byte = source[index]
      scratch[index] = byte == 9 || byte == 10 || byte == 13 ? 0x20 : byte
    }
    replace(range, with: source.count)
  }

  private func replace(_ range: Range<Int>, with insertedCount: Int) {
    let delta = insertedCount - range.count
    if delta > 0 {
      for index in stride(from: byteCount - 1, through: range.upperBound, by: -1) {
        bytes[index + delta] = bytes[index]
      }
    } else if delta < 0 {
      for index in range.upperBound..<byteCount { bytes[index + delta] = bytes[index] }
    }
    for index in 0..<insertedCount { bytes[range.lowerBound + index] = scratch[index] }
    byteCount += delta
    // A newly inserted combining scalar or ZWJ may join a neighboring cluster.
    cursorByteOffset = withText { text in
      var characters = text.makeCharacterIterator()
      characters.reset(roundingForwardsFrom: range.lowerBound + insertedCount)
      return characters.currentCodeUnitOffset
    }
    anchor = nil
  }

  private func boundary(from offset: Int, forward: Bool) -> Int {
    withText { text in
      var characters = text.makeCharacterIterator()
      characters.reset(roundingBackwardsFrom: offset)
      if forward { _ = characters.skipForward() } else { _ = characters.skipBack() }
      return characters.currentCodeUnitOffset
    }
  }

  private func move(to offset: Int, selecting: Bool) {
    if selecting {
      if anchor == nil { anchor = cursorByteOffset }
    } else {
      anchor = nil
    }
    cursorByteOffset = offset
  }

  public func handle(
    _ key: InputKey, modifiers: KeyModifiers = [], copyBuffer: inout CopyBuffer
  ) -> TextInputAction {
    var key = key
    var modifiers = modifiers.withoutLocks
    if case .control(let control) = key,
      (ControlKey.a.rawValue...ControlKey.z.rawValue).contains(control.rawValue)
    {
      key = .character(Unicode.Scalar(control.rawValue + 96))
      modifiers.insert(.control)
    }
    if modifiers == .control, case .character(let scalar) = key {
      switch scalar {
      case "a":
        selectAll()
        return .changed
      case "c", "x":
        let range = selection
        guard !range.isEmpty else { return .ignored }
        withText { text in
          copyBuffer.copy(unsafe UTF8Span(unchecked: text.span.extracting(range)))
        }
        if scalar == "x" { replace(range, with: 0) }
        return .changed
      case "u":
        replace(0..<cursorByteOffset, with: 0)
        return .changed
      case "k":
        replace(cursorByteOffset..<byteCount, with: 0)
        return .changed
      case "b":
        key = .left
        modifiers = []
      case "f":
        key = .right
        modifiers = []
      case "h":
        key = .backspace
        modifiers = []
      case "d":
        key = .delete
        modifiers = []
      case "e":
        key = .end
        modifiers = []
      default: return .ignored
      }
    }
    guard modifiers.isEmpty || modifiers == .shift else { return .ignored }
    let selecting = modifiers == .shift
    switch key {
    case .left, .right:
      let forward = key == .right
      let offset =
        !selecting && !selection.isEmpty
        ? (forward ? selection.upperBound : selection.lowerBound)
        : boundary(from: cursorByteOffset, forward: forward)
      move(to: offset, selecting: selecting)
    case .home: move(to: 0, selecting: selecting)
    case .end: move(to: byteCount, selecting: selecting)
    case .backspace, .delete:
      var range = selection
      if range.isEmpty {
        range =
          key == .backspace
          ? boundary(from: cursorByteOffset, forward: false)..<cursorByteOffset
          : cursorByteOffset..<boundary(from: cursorByteOffset, forward: true)
      }
      guard !range.isEmpty else { return .ignored }
      replace(range, with: 0)
    case .enter: return .submit
    case .character(let scalar):
      var encoded = InlineArray<4, UInt8>(repeating: 0)
      var count = 0
      UTF8.encode(scalar) {
        encoded[count] = $0
        count += 1
      }
      do { try insert(unsafe UTF8Span(unchecked: encoded.span.extracting(first: count))) } catch {
        return .rejected(error)
      }
    default: return .ignored
    }
    return .changed
  }

}

private func withInputText<Result, Failure: Error>(
  _ storage: borrowing RigidArray<UInt8>, count: Int,
  body: (UTF8Span) throws(Failure) -> Result
) throws(Failure) -> Result {
  // All mutations validate before committing; these bytes are always valid UTF-8.
  try body(unsafe UTF8Span(unchecked: storage.span.extracting(first: count)))
}
