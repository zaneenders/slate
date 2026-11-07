import Slate
import Testing

@Test func terminalInputDrainsMaximumBatchesAndDecoderRecoveryWithoutLosingBytes() {
  var input = TerminalInput()
  let now = ContinuousClock().now
  var bytes = InlineArray<64, UInt8>(repeating: 0x61)
  for _ in 0..<2 {
    var offset = 0
    var count = 0
    while let event = input.next(in: bytes.span, offset: &offset, at: now) {
      #expect(event == .key(.scalar("a")))
      count += 1
    }
    #expect(count == 64 && offset == 64)
  }
  bytes[0] = 0xc2
  var offset = 0
  #expect(input.next(in: bytes.span.extracting(first: 2), offset: &offset, at: now) == .invalid(.invalidUTF8))
  #expect(input.next(in: bytes.span.extracting(first: 2), offset: &offset, at: now) == .key(.scalar("a")))
  #expect(input.next(in: bytes.span.extracting(first: 2), offset: &offset, at: now) == nil)
}

@Test func terminalInputExpiresEscapeExactlyOnceAndPreservesItAcrossResume() {
  var input = TerminalInput()
  let now = ContinuousClock().now
  let escape: InlineArray<1, UInt8> = [0x1b]
  var offset = 0
  #expect(input.next(in: escape.span, offset: &offset, at: now) == nil)
  #expect(input.expire(at: now.advanced(by: .milliseconds(49))) == nil)
  input.resume(at: now.advanced(by: .seconds(1)))
  #expect(input.expire(at: now.advanced(by: .milliseconds(1049))) == nil)
  #expect(input.expire(at: now.advanced(by: .milliseconds(1050))) == .key(.escape))
  #expect(input.expire(at: now.advanced(by: .seconds(2))) == nil)
}

@Test func terminalInputResponseFragmentsCannotExtendTheDeadline() {
  var input = TerminalInput()
  let now = ContinuousClock().now
  let prefix: InlineArray<4, UInt8> = [0x1b, 0x5f, 0x47, 0x69]
  let fragment: InlineArray<1, UInt8> = [0x31]
  var offset = 0
  #expect(input.next(in: prefix.span, offset: &offset, at: now) == nil)
  offset = 0
  #expect(input.next(in: fragment.span, offset: &offset, at: now.advanced(by: .milliseconds(200))) == nil)
  #expect(input.expire(at: now.advanced(by: .milliseconds(250))) == nil)
  let text: InlineArray<1, UInt8> = [0x61]
  offset = 0
  #expect(input.next(in: text.span, offset: &offset, at: now.advanced(by: .milliseconds(251))) == .key(.scalar("a")))
}

@Test func terminalInputPreservesEachCommandWhenSeveralArriveInOneBatch() {
  let bytes = Array("a\u{1b}_first\u{1b}\\b\u{1b}_second\u{1b}\\c".utf8)
  var input = TerminalInput()
  var offset = 0
  var keys: [InputKey] = []
  var commands: [String] = []
  while let event = input.next(in: bytes.span, offset: &offset, at: .now) {
    if case .key(let key) = event { keys.append(key) }
    if event == .terminalReply(.applicationCommand) {
      let command = input.applicationCommand
      commands.append(command.bytes.withUnsafeBufferPointer { unsafe String(decoding: $0, as: UTF8.self) })
    }
  }
  #expect(keys == [.scalar("a"), .scalar("b"), .scalar("c")])
  #expect(commands == ["first", "second"])
}
