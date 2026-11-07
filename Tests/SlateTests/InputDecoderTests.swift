import Slate
import Testing

@Test func decoderRecognizesNamedControlKeysAndPreservesDedicatedKeysAtEverySplit() {
  let keys: [InputKey] = [
    .control(.space), .control(.a), .control(.b), .control(.c),
    .control(.d), .control(.e), .control(.f), .control(.g),
    .backspace, .tab, .enter, .control(.k),
    .control(.l), .enter, .control(.n), .control(.o),
    .control(.p), .control(.q), .control(.r), .control(.s),
    .control(.t), .control(.u), .control(.v), .control(.w),
    .control(.x), .control(.y), .control(.z), .escape,
    .control(.backslash), .control(.rightBracket), .control(.caret), .control(.underscore)
  ]
  #expect(keys.count == 32)
  for (byte, key) in keys.enumerated() {
    expectEverySplit([UInt8(byte)], events: [.key(key)])
    expectEverySplit([UInt8(byte), 0x71], events: [.key(key), .key(.scalar("q"))])
  }
  expectEverySplit([0x7f], events: [.key(.backspace)])
}

@Test func controlKeysCoverOnlyC0Bytes() {
  for byte in UInt8.min...UInt8.max {
    #expect((ControlKey(rawValue: byte) != nil) == (byte < 0x20))
  }
  // These control bytes have dedicated InputKey cases in the decoder.
  #expect(ControlKey.h.rawValue == 0x08)
  #expect(ControlKey.i.rawValue == 0x09)
  #expect(ControlKey.j.rawValue == 0x0a)
  #expect(ControlKey.m.rawValue == 0x0d)
  #expect(ControlKey.leftBracket.rawValue == 0x1b)
}

@Test func decoderRecognizesMouseButtonsMotionWheelAndModifiersAtEverySplit() {
  for (code, button) in [(0, MouseButton.left), (1, .middle), (2, .right)] {
    for (suffix, action) in [("M", MouseAction.press), ("m", .release)] {
      expectEverySplit(
        Array("\u{1b}[<\(code + 28);301;402\(suffix)".utf8),
        events: [
          .mouse(
            MouseEvent(
              action: action, button: button, column: 300, row: 401,
              modifiers: [.shift, .alt, .control]))
        ])
    }
    expectEverySplit(
      Array("\u{1b}[<\(code + 32);1;1M".utf8),
      events: [
        .mouse(MouseEvent(action: .move, button: button, column: 0, row: 0))
      ])
  }
  expectEverySplit(
    Array("\u{1b}[<35;65535;65535M".utf8),
    events: [
      .mouse(MouseEvent(action: .move, column: 65_534, row: 65_534))
    ])
  for (code, action) in [(64, MouseAction.scrollUp), (65, .scrollDown), (66, .scrollLeft), (67, .scrollRight)] {
    expectEverySplit(
      Array("\u{1b}[<\(code);2;3Mq".utf8),
      events: [
        .mouse(MouseEvent(action: action, column: 1, row: 2)), .key(.scalar("q"))
      ])
  }
}

@Test func decoderRejectsMalformedMouseReportsAndRecoversWithoutTypingTheirTails() {
  for body in [
    "", "0", "0;1", "0;1;", "0;;1", ";1;1", "0;0;1", "0;1;0",
    "0;65536;1", "0;1;65536", "128;1;1", "3;1;1", "0;1;1;1",
    "0:1;1;1", "999999999999999999;1;1"
  ] {
    expectEverySplit(
      Array("\u{1b}[<\(body)Mq".utf8),
      events: [.invalid(.unknownSequence), .key(.scalar("q"))])
  }
  for sequence in ["\u{1b}[<64;1;1m", "\u{1b}[<32;1;1m", "\u{1b}[<96;1;1M", "\u{1b}[<0;1;1A"] {
    expectEverySplit(Array((sequence + "q").utf8), events: [.invalid(.unknownSequence), .key(.scalar("q"))])
  }
  expectEverySplit(Array("\u{1b}[<0;12;".utf8), events: [.invalid(.incompleteSequence)])
  expectEverySplit(
    Array(("\u{1b}[<0;" + String(repeating: "1", count: 40) + ";1Mq").utf8),
    events: [.invalid(.sequenceTooLong), .key(.scalar("q"))])
}

@Test func decoderFramesApplicationCommandsWithoutInterpretingOrTypingTheirContents() {
  for body in [
    "protocol-specific response", "Gi=31;OK", "Gi=4294967296;OK", "Gp=1,i=31;ENOENT:missing",
    String(repeating: "q", count: ApplicationCommand.maximumBytes - 1),
    String(repeating: "q", count: ApplicationCommand.maximumBytes),
    String(repeating: "q", count: ApplicationCommand.maximumBytes + 1),
    "Gi=31;" + String(repeating: "q", count: 256)
  ] {
    let bytes = Array(body.utf8)
    let command = ApplicationCommand(bytes.span)
    #expect(command.count == min(bytes.count, ApplicationCommand.maximumBytes))
    #expect(command.truncated == (bytes.count > ApplicationCommand.maximumBytes))
    expectEverySplit(
      Array(("\u{1b}_" + body + "\u{1b}\\\u{1b}[?1;2cq").utf8),
      events: [.terminalReply(.applicationCommand), .terminalReply(.primaryAttributes), .key(.scalar("q"))],
      commands: [command])
  }
  expectEverySplit(Array("\u{1b}_unfinished".utf8), events: [.invalid(.incompleteSequence)])
  expectEverySplit(Array("\u{1b}_\u{1b}\\q".utf8), events: [.invalid(.unknownSequence), .key(.scalar("q"))])
  expectEverySplit(
    Array("\u{1b}_bad\tresponse\u{1b}\\q".utf8), events: [.invalid(.unknownSequence), .key(.scalar("q"))])
}

private func expectEverySplit(_ bytes: [UInt8], events: [InputEvent], commands: [ApplicationCommand] = []) {
  for split in 0...bytes.count {
    for capacity in [1, 4] {
      let decoded = decodeChunks(bytes, boundaries: [split, bytes.count], outputCapacity: capacity)
      #expect(decoded.events == events && decoded.commands == commands)
    }
  }
  let decoded = decodeChunks(bytes, boundaries: Array(0...bytes.count), outputCapacity: 1)
  #expect(decoded.events == events && decoded.commands == commands)
}

@Test func decoderFramesPasteAcrossEverySplitWithoutInterpretingItsContents() {
  for body in ["", "q\r\n\t\u{3}\u{1a}", "café 👨‍👩‍👧‍👦", "\u{1b}[A\u{1b}[200~\u{1b}[201x\u{1b}\u{1b}["] {
    expectEverySplit(
      Array(("\u{1b}[200~" + body + "\u{1b}[201~j").utf8),
      events: [.paste(.begin)] + body.utf8.map { .paste(.byte($0)) } + [.paste(.end), .key(.scalar("j"))])
  }
  expectEverySplit(
    Array("\u{1b}[200~q\u{1b}[201".utf8),
    events: [.paste(.begin), .paste(.byte(0x71)), .paste(.cancelled)])
  expectEverySplit(
    [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e, 0xff, 0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e],
    events: [.paste(.begin), .paste(.byte(0xff)), .paste(.end)])
}

private func decodeChunks(_ bytes: [UInt8], boundaries: [Int], outputCapacity: Int) -> (
  events: [InputEvent], commands: [ApplicationCommand]
) {
  precondition(outputCapacity > 0 && outputCapacity <= 4)
  var decoder = InputDecoder()
  var output = [InputEvent](repeating: .key(.escape), count: outputCapacity)
  var result: [InputEvent] = []
  var commands: [ApplicationCommand] = []
  var offset = 0
  for end in boundaries {
    repeat {
      let progress = decoder.decode(bytes.span.extracting(offset..<end), into: output.mutableSpan)
      #expect(progress.bytesConsumed <= end - offset && progress.eventsWritten <= outputCapacity)
      if offset < end && progress.bytesConsumed == 0 && progress.eventsWritten == 0 {
        Issue.record("Decoder made no progress with input and output capacity")
        return (result, commands)
      }
      offset += progress.bytesConsumed
      for index in 0..<progress.eventsWritten {
        result.append(output[index])
        if output[index] == .terminalReply(.applicationCommand) { commands.append(decoder.applicationCommand) }
      }
    } while offset < end
  }
  #expect(offset == bytes.count)
  if let event = decoder.flush() { result.append(event) }
  return (result, commands)
}
