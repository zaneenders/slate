import SlateTerminal
import Testing

@Test func terminalInputDrainsMaximumBatchesAndDecoderRecoveryWithoutLosingBytes() throws {
  var input = TerminalInput()
  let now = ContinuousClock().now
  var bytes = InlineArray<64, UInt8>(repeating: 0x61)
  for _ in 0..<2 {
    var offset = 0
    var count = 0
    while let event = try input.next(in: bytes.span, offset: &offset, at: now) {
      #expect(event == .key(.character("a")))
      count += 1
    }
    #expect(count == 64 && offset == 64)
  }
  bytes[0] = 0xc2
  var offset = 0
  #expect(try input.next(in: bytes.span.extracting(first: 2), offset: &offset, at: now) == .invalid(.invalidUTF8))
  #expect(try input.next(in: bytes.span.extracting(first: 2), offset: &offset, at: now) == .key(.character("a")))
  #expect(try input.next(in: bytes.span.extracting(first: 2), offset: &offset, at: now) == nil)
}

@Test func terminalInputExpiresEscapeExactlyOnceAndPreservesItAcrossResume() throws {
  var input = TerminalInput()
  let now = ContinuousClock().now
  let escape: InlineArray<1, UInt8> = [0x1b]
  var offset = 0
  #expect(try input.next(in: escape.span, offset: &offset, at: now) == nil)
  #expect(try input.expire(at: now.advanced(by: .milliseconds(49))) == nil)
  input.resume(at: now.advanced(by: .seconds(1)))
  #expect(try input.expire(at: now.advanced(by: .milliseconds(1049))) == nil)
  #expect(try input.expire(at: now.advanced(by: .milliseconds(1050))) == .key(.escape))
  #expect(try input.expire(at: now.advanced(by: .seconds(2))) == nil)
}

@Test func terminalInputResponseFragmentsCannotExtendTheDeadline() throws {
  var input = TerminalInput()
  let now = ContinuousClock().now
  let prefix: InlineArray<4, UInt8> = [0x1b, 0x5f, 0x47, 0x69]
  let fragment: InlineArray<1, UInt8> = [0x31]
  var offset = 0
  #expect(try input.next(in: prefix.span, offset: &offset, at: now) == nil)
  offset = 0
  #expect(try input.next(in: fragment.span, offset: &offset, at: now.advanced(by: .milliseconds(200))) == nil)
  #expect(try input.expire(at: now.advanced(by: .milliseconds(250))) == nil)
  let text = Array("q\u{1b}\\a".utf8)
  offset = 0
  #expect(
    try input.next(in: text.span, offset: &offset, at: now.advanced(by: .milliseconds(251))) == .key(.character("a")))
  #expect(try input.next(in: text.span, offset: &offset, at: now.advanced(by: .milliseconds(251))) == nil)
}

@Test func terminalInputRecoversExpiredRepliesAtEveryTerminatorSplit() throws {
  let now = ContinuousClock().now
  let prefix = Array("\u{1b}_unfinished".utf8)
  let tail = Array("q\u{3}\u{1b}\\a".utf8)
  for split in 0...tail.count {
    var input = TerminalInput()
    var offset = 0
    #expect(try input.next(in: prefix.span, offset: &offset, at: now) == nil)
    // next itself enforces the deadline; expire is not required before input.
    var keys: [InputEvent] = []
    for range in [0..<split, split..<tail.count] {
      offset = range.lowerBound
      while let event = try input.next(
        in: tail.span.extracting(first: range.upperBound), offset: &offset,
        at: now.advanced(by: .milliseconds(251)))
      { keys.append(event) }
    }
    #expect(keys == [.key(.character("a"))])
  }
  // A timeout between ESC and backslash must preserve the partial terminator.
  var input = TerminalInput()
  var offset = 0
  let partial = Array("\u{1b}_unfinished\u{1b}".utf8)
  #expect(try input.next(in: partial.span, offset: &offset, at: now) == nil)
  offset = 0
  let end = Array("\\a".utf8)
  #expect(
    try input.next(in: end.span, offset: &offset, at: now.advanced(by: .milliseconds(250))) == .key(.character("a")))
}

@Test func terminalInputFailsPermanentlyWhenRecoveryTimeOrBytesAreExhausted() throws {
  let now = ContinuousClock().now
  let prefix = Array("\u{1b}_unfinished".utf8)
  for exhaustBytes in [false, true] {
    var input = TerminalInput()
    var offset = 0
    #expect(try input.next(in: prefix.span, offset: &offset, at: now) == nil)
    #expect(try input.expire(at: now.advanced(by: .milliseconds(250))) == nil)
    if exhaustBytes {
      let body = InlineArray<64, UInt8>(repeating: 0x71)
      for _ in 0..<63 {
        offset = 0
        #expect(try input.next(in: body.span, offset: &offset, at: now.advanced(by: .milliseconds(251))) == nil)
      }
      offset = 0
      #expect(throws: TerminalInputError.responseRecoveryExceeded) {
        try input.next(in: body.span, offset: &offset, at: now.advanced(by: .milliseconds(251)))
      }
      #expect(offset == 64)
    } else {
      #expect(try input.expire(at: now.advanced(by: .milliseconds(499))) == nil)
      input.resume(at: now.advanced(by: .seconds(1)))
      #expect(throws: TerminalInputError.responseRecoveryExceeded) {
        try input.expire(at: now.advanced(by: .seconds(1)))
      }
    }
    offset = 0
    let tail = Array("\u{1b}\\q".utf8)
    #expect(throws: TerminalInputError.responseRecoveryExceeded) {
      try input.next(in: tail.span, offset: &offset, at: now.advanced(by: .seconds(2)))
    }
    #expect(offset == 0)
  }
}

@Test func terminalInputAcceptsTheTerminatorAtItsExactRecoveryByteLimit() throws {
  let now = ContinuousClock().now
  var input = TerminalInput()
  let prefix = Array("\u{1b}_unfinished".utf8)
  var offset = 0
  #expect(try input.next(in: prefix.span, offset: &offset, at: now) == nil)
  #expect(try input.expire(at: now.advanced(by: .milliseconds(250))) == nil)
  var batch = InlineArray<64, UInt8>(repeating: 0x71)
  for _ in 0..<63 {
    offset = 0
    #expect(try input.next(in: batch.span, offset: &offset, at: now.advanced(by: .milliseconds(251))) == nil)
  }
  batch[62] = 0x1b
  batch[63] = 0x5c
  offset = 0
  #expect(try input.next(in: batch.span, offset: &offset, at: now.advanced(by: .milliseconds(499))) == nil)
  offset = 0
  #expect(
    try input.next(in: "a".utf8Span.span, offset: &offset, at: now.advanced(by: .milliseconds(500)))
      == .key(.character("a")))
}

@Test func terminalInputFinishClosesTheStreamAndReportsIncompletePasteOnce() throws {
  var input = TerminalInput()
  let bytes = Array("\u{1b}[200~".utf8)
  var offset = 0
  #expect(try input.next(in: bytes.span, offset: &offset, at: .now) == .paste(.begin))
  #expect(try input.next(in: bytes.span, offset: &offset, at: .now) == nil)
  #expect(input.finish() == .paste(.cancelled))
  #expect(input.finish() == nil)
  offset = 0
  #expect(throws: TerminalInputError.finished) { try input.next(in: bytes.span, offset: &offset, at: .now) }
  #expect(offset == 0)
}

@Test func terminalInputPreservesEachCommandWhenSeveralArriveInOneBatch() throws {
  let bytes = Array("a\u{1b}_first\u{1b}\\b\u{1b}_second\u{1b}\\c".utf8)
  var input = TerminalInput()
  var offset = 0
  var keys: [InputKey] = []
  var commands: [String] = []
  while let event = try input.next(in: bytes.span, offset: &offset, at: .now) {
    if case .key(let key) = event { keys.append(key) }
    if event == .terminalReply(.applicationCommand) {
      let command = input.applicationCommand
      commands.append(command.bytes.withUnsafeBufferPointer { unsafe String(decoding: $0, as: UTF8.self) })
    }
  }
  #expect(keys == [.character("a"), .character("b"), .character("c")])
  #expect(commands == ["first", "second"])
}
