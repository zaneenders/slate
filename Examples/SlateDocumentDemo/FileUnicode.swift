import Slate

/// In-memory state immediately before a bounded grapheme fragment. No borrowed
/// bytes or pointers survive the indexing batch. Each disk page retains one.
struct FileUnicodeCheckpoint: Sendable {
  var offset = 0
  var recognizer = UnicodeGraphemeRecognizer()
  var fragmented = false
}

/// Validates scalars and records fragment boundaries in the same indexing pass.
/// Invalid bytes each act as a NUL boundary; rejected continuations are retried
/// as fresh bytes. At most four scalar events are produced per input byte.
struct FileUnicodeIndexState: ~Copyable {
  private var decoder = IncrementalUTF8Decoder()
  private var scalarStart = 0
  private var pendingBytes = 0
  private var recognizer = UnicodeGraphemeRecognizer()
  private var fragmentBytes = 0
  private var deferredASCII: UInt8?
  private(set) var checkpoint = FileUnicodeCheckpoint()

  /// After the first two ASCII bytes, the last two determine the checkpoint:
  /// CRLF is the only contextual ASCII boundary. Batch runs in the checksum
  /// loop instead of decoding/updating Unicode state for every ASCII scalar.
  mutating func appendASCII(_ bytes: Span<UInt8>, at offset: Int) -> Int? {
    precondition(!bytes.isEmpty)
    let failure = append(bytes[0], at: offset)
    guard bytes.count > 1 else { return failure }
    let secondFailure = append(bytes[1], at: offset + 1)
    if bytes.count > 2 {
      let last = bytes[bytes.count - 1]
      let crlf = last == 10 && bytes[bytes.count - 2] == 13
      checkpoint = .init(offset: offset + bytes.count - (crlf ? 2 : 1))
      fragmentBytes = crlf ? 2 : 1
      deferredASCII = last
    }
    return failure ?? secondFailure
  }

  mutating func append(_ byte: UInt8, at offset: Int) -> Int? {
    if decoder.isComplete { scalarStart = offset }
    switch decoder.append(byte) {
    case .pending:
      pendingBytes += 1
      return nil
    case .scalar(let scalar):
      emit(scalar, at: scalarStart, bytes: offset - scalarStart + 1)
      pendingBytes = 0
      return nil
    case .invalid:
      let failure = scalarStart
      if pendingBytes == 0 {
        emit("\0", at: offset, bytes: 1)
      } else {
        for position in scalarStart..<offset { emit("\0", at: position, bytes: 1) }
        pendingBytes = 0
        scalarStart = offset
        switch decoder.append(byte) {
        case .pending: pendingBytes = 1
        case .scalar(let scalar): emit(scalar, at: offset, bytes: 1)
        case .invalid: emit("\0", at: offset, bytes: 1)
        }
      }
      return failure
    }
  }

  mutating func finish() -> Int? {
    guard pendingBytes > 0 else { return nil }
    for position in scalarStart..<scalarStart + pendingBytes { emit("\0", at: position, bytes: 1) }
    pendingBytes = 0
    decoder.reset()
    return scalarStart
  }

  private mutating func emit(_ scalar: Unicode.Scalar, at offset: Int, bytes: Int) {
    if scalar.isASCII, let previous = deferredASCII {
      // ASCII pairs break except CRLF. Defer the native recognizer until a
      // non-ASCII scalar needs its context, keeping large ASCII scans cheap.
      if previous == 13 && scalar.value == 10 {
        fragmentBytes += bytes
      } else {
        checkpoint = .init(offset: offset)
        fragmentBytes = bytes
      }
      deferredASCII = UInt8(scalar.value)
      return
    }
    if let previous = deferredASCII {
      recognizer = UnicodeGraphemeRecognizer()
      _ = recognizer.hasBreak(before: Unicode.Scalar(previous))
      deferredASCII = nil
    }
    let before = recognizer
    let boundary = recognizer.hasBreak(before: scalar)
    let overflow = fragmentBytes + bytes > Glyph.maximumUTF8Bytes
    if boundary || overflow || fragmentBytes == 0 {
      checkpoint = .init(offset: offset, recognizer: before, fragmented: !boundary)
      fragmentBytes = 0
    }
    fragmentBytes += bytes
    if scalar.isASCII { deferredASCII = UInt8(scalar.value) }
  }
}

struct FileUnicodeScalar {
  let scalar: Unicode.Scalar
  let range: Range<Int>
  let raw: InlineArray<4, UInt8>
}

/// One 4 KiB source-read buffer reused for scalar decoding and bounded replay.
/// A malformed sequence advances by one byte, preserving binary byte offsets.
struct FileUnicodeCursor: ~Copyable {
  private var buffer = InlineArray<4_096, UInt8>(repeating: 0)
  private var bufferOffset = -1
  private var bufferCount = 0
  private(set) var offset: Int
  private(set) var readBytes = 0

  init(offset: Int) { self.offset = offset }

  mutating func next(from source: inout PagedFileDocument) throws(FileDocumentError) -> FileUnicodeScalar? {
    guard offset < source.byteCount else { return nil }
    let start = offset
    var decoder = IncrementalUTF8Decoder()
    var raw = InlineArray<4, UInt8>(repeating: 0)
    for index in 0..<4 {
      guard offset < source.byteCount else { break }
      let byte = try nextByte(from: &source)
      raw[index] = byte
      switch decoder.append(byte) {
      case .pending: continue
      case .scalar(let scalar):
        if Glyph.scalarColumns(scalar) != nil { return .init(scalar: scalar, range: start..<offset, raw: raw) }
        // Controls/unsupported scalars retain one placeholder per source byte.
        offset = start + 1
        return .init(scalar: "\0", range: start..<offset, raw: raw)
      case .invalid: break
      }
      break
    }
    offset = start + 1
    return .init(scalar: "\0", range: start..<offset, raw: raw)
  }

  private mutating func nextByte(from source: inout PagedFileDocument) throws(FileDocumentError) -> UInt8 {
    if offset < bufferOffset || offset >= bufferOffset + bufferCount {
      bufferOffset = offset
      bufferCount = try source.readBytes(from: offset, into: buffer.mutableSpan)
      guard bufferCount > 0 else { throw .fileChanged }
      readBytes += bufferCount
    }
    let value = buffer[offset - bufferOffset]
    offset += 1
    return value
  }
}
