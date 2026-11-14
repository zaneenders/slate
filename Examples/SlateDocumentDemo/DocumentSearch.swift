import Slate

/// Literal, case-sensitive UTF-8 search over the current logical bytes. Owns one
/// query and one result; no result queue or tasks. Startup payload is 256 query
/// bytes + 256 Int prefix lengths + 4 KiB scratch + TextInput's two 256-byte
/// buffers (6,912 bytes on 64-bit hosts), plus scalar state and input metadata.
/// Edits reject atomically at 256 bytes. Each advance reads at most one cached
/// page / 4 KiB and performs linear KMP work, preserving partial matches across
/// batches. A scan wraps once, with at most query.count - 1 overlap bytes.
/// Page verification and blocking disk latency remain outside the scan budget.
/// Successful steady work reuses startup storage; errors may box Swift values.
struct DocumentSearch: ~Copyable, ~Sendable {
  static let maximumQueryBytes = 256
  static let maximumBytesPerBatch = 4_096

  enum State: Equatable {
    case idle, searching, found, notFound, cancelled
    case failed(FileDocumentError)
  }

  let input = try! TextInput(capacity: maximumQueryBytes)
  private var query = InlineArray<256, UInt8>(repeating: 0)
  private var prefixes = InlineArray<256, Int>(repeating: 0)
  private var scratch = InlineArray<4_096, UInt8>(repeating: 0)
  private var queryCount = 0
  private var matchedBytes = 0
  private var origin = 0
  private var editOrigin = 0
  private var endByte = 0
  private var fileBytes = 0
  private var sourceSnapshot: FileByteSnapshot?
  private var wrapped = false
  private(set) var nextByte = 0
  private(set) var state = State.idle
  private(set) var match: Range<Int>?
  private(set) var isVisible = false
  private(set) var isFocused = false
  private(set) var inputError: TextInputError?

  var hasPendingWork: Bool { state == .searching }
  var storagePayloadBytes: Int {
    MemoryLayout<InlineArray<256, UInt8>>.stride + MemoryLayout<InlineArray<256, Int>>.stride
      + MemoryLayout<InlineArray<4_096, UInt8>>.stride + input.capacity * 2
  }

  var statusMessage: String {
    if let inputError {
      return inputError == .capacityExceeded ? "Query limit: 256 UTF-8 bytes" : "Query contains unsupported controls"
    }
    switch state {
    case .idle: return "Type to search; Enter next; Tab focus; Esc close"
    case .searching: return "Searching... Esc cancels"
    case .found:
      return isFocused ? "Match: Enter next; Tab browse; Esc close" : "Match: Enter / n next; Tab edit; Esc close"
    case .notFound:
      return isFocused ? "No matches; type to edit; Esc close" : "No matches; Tab edit; Esc close"
    case .cancelled: return "Search cancelled"
    case .failed(let error): return DocumentFileViewer.message(for: error)
    }
  }

  mutating func focus(from offset: Int) {
    isFocused = true
    editOrigin = offset
  }

  mutating func blur() { isFocused = false }

  mutating func close() {
    isVisible = false
    isFocused = false
    state = .cancelled
    match = nil
    inputError = nil
  }

  /// Handles search controls without disk access. Nil leaves the key to the viewer.
  mutating func handle(
    _ key: InputKey, modifiers: KeyModifiers, copyBuffer: inout CopyBuffer,
    firstByte: Int, byteCount: Int
  ) -> ScreenUpdate? {
    let modifiers = modifiers.withoutLocks
    let controlC = key == .control(.c) || (key == .character("c") && modifiers == .control)
    if isVisible && (key == .escape || controlC) {
      close()
      return .redraw
    }
    if isVisible && key == .tab && modifiers.isEmpty {
      if isFocused { blur() } else { focus(from: firstByte) }
      return .redraw
    }
    if isFocused {
      if key == .enter && modifiers.isEmpty {
        blur()
        if !hasPendingWork { start(from: match.map { $0.lowerBound + 1 } ?? firstByte, byteCount: byteCount) }
        return .redraw
      }
      // Ctrl-Q remains the application's quit command even while typing.
      if key == .control(.q) || (key == .character("q") && modifiers == .control) { return nil }
      switch input.handle(key, modifiers: modifiers, copyBuffer: &copyBuffer) {
      case .changed:
        inputError = nil
        if !queryMatchesInput() { start(from: editOrigin, byteCount: byteCount) }
        return .redraw
      case .rejected(let error):
        inputError = error
        return .redraw
      case .ignored, .submit: return ScreenUpdate.none
      }
    }
    guard modifiers.isEmpty else { return nil }
    if key == .character("/") {
      isVisible = true
      focus(from: firstByte)
      input.selectAll()
      start(from: firstByte, byteCount: byteCount)
      return .redraw
    }
    if isVisible && (key == .character("n") || key == .enter) {
      start(from: match.map { $0.lowerBound + 1 } ?? firstByte, byteCount: byteCount)
      return .redraw
    }
    return nil
  }

  mutating func paste(_ text: UTF8Span, byteCount: Int) -> ScreenUpdate {
    guard isFocused else { return .none }
    do throws(TextInputError) {
      try input.insert(text)
      start(from: editOrigin, byteCount: byteCount)
    } catch { inputError = error }
    return .redraw
  }

  private func queryMatchesInput() -> Bool {
    input.withText { text in
      guard text.count == queryCount else { return false }
      for index in 0..<queryCount where text.span[index] != query[index] { return false }
      return true
    }
  }

  private mutating func start(from offset: Int, byteCount: Int) {
    precondition((0...byteCount).contains(offset))
    input.withText { text in
      queryCount = text.count
      for index in 0..<queryCount { query[index] = text.span[index] }
    }
    prefixes[0] = 0
    var length = 0
    if queryCount > 1 {
      for index in 1..<queryCount {
        while length > 0 && query[index] != query[length] { length = prefixes[length - 1] }
        if query[index] == query[length] { length += 1 }
        prefixes[index] = length
      }
    }
    origin = offset
    nextByte = offset
    endByte = byteCount
    fileBytes = byteCount
    sourceSnapshot = nil
    matchedBytes = 0
    wrapped = false
    match = nil
    inputError = nil
    if queryCount == 0 { state = .idle } else if byteCount == 0 { state = .notFound } else { state = .searching }
  }

  /// Returns only a newly verified match. Failure latches until another request.
  mutating func advance<Source: FileByteSource & ~Copyable>(from source: inout Source) -> Range<Int>? {
    guard hasPendingWork else { return nil }
    precondition((1...Self.maximumQueryBytes).contains(queryCount))
    precondition(nextByte <= endByte && endByte <= fileBytes)
    do throws(FileDocumentError) {
      // An edit between cooperative batches cancels the obsolete search rather
      // than letting its old byte coordinates trap or produce a stale match.
      guard source.byteCount == fileBytes else { throw .fileChanged }
      let snapshot = FileByteSnapshot(file: source.snapshotIdentity, editRevision: source.editRevision)
      if let sourceSnapshot, sourceSnapshot != snapshot { throw .fileChanged }
      sourceSnapshot = snapshot
      try source.verifyUnchanged()
      if nextByte == endByte {
        guard !wrapped && origin > 0 else {
          state = .notFound
          return nil
        }
        wrapped = true
        nextByte = 0
        endByte = min(fileBytes, origin + queryCount - 1)
        matchedBytes = 0
      }
      let requested = min(Self.maximumBytesPerBatch, endByte - nextByte)
      let count = try source.readBytes(from: nextByte, maximumCount: requested, into: scratch.mutableSpan)
      guard count > 0 && count <= requested else { throw .fileChanged }
      for index in 0..<count {
        let byte = scratch[index]
        while matchedBytes > 0 && byte != query[matchedBytes] { matchedBytes = prefixes[matchedBytes - 1] }
        if byte == query[matchedBytes] { matchedBytes += 1 }
        if matchedBytes == queryCount {
          let end = nextByte + index + 1
          try source.verifyUnchanged()
          match = end - queryCount..<end
          nextByte = end
          state = .found
          return match
        }
      }
      nextByte += count
      try source.verifyUnchanged()
    } catch {
      match = nil
      state = .failed(error)
    }
    return nil
  }
}
