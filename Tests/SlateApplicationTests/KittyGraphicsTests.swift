import SlateTestSupport
import Testing

@testable import SlateApplication

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

@Test func managedKittyProbeUsesTheSessionReaderAndRestoresTerminalModes() throws {
  let pty = try PseudoTerminal()
  var size = winsize(ws_row: 2, ws_col: 4, ws_xpixel: 0, ws_ypixel: 0)
  try #require(unsafe ioctl(pty.slave, UInt(TIOCSWINSZ), &size) == 0)
  let saved = try attributes(of: pty.slave)
  let terminalInput = try Output(fileDescriptor: pty.master)
  try terminalInput.writeAll("\u{1b}_Gi=31;OK\u{1b}\\\u{1b}[?1;2cq".utf8Span.span)
  var application = KittyReplyApplication()
  try application.run(inputFileDescriptor: pty.slave, outputFileDescriptor: pty.slave)
  #expect(application.received == ["31:OK", "attributes", "q"])
  expectEqual(try attributes(of: pty.slave), saved)
  let input = try Input(fileDescriptor: pty.master)
  var bytes = InlineArray<4_096, UInt8>(repeating: 0)
  let count = try input.read(into: bytes.mutableSpan)
  let text = bytes.span.extracting(first: count).withUnsafeBufferPointer { unsafe String(decoding: $0, as: UTF8.self) }
  #expect(text.contains("\u{1b}_Ga=q,t=d,f=24,s=1,v=1,i=31;AAAA\u{1b}\\\u{1b}[c"))
  #expect(text.contains("\u{1b}[?1049l"))
}

@Test func managedKittyProbeRejectsZeroQueryIDBeforeTerminalSetup() {
  #expect(ScreenApplicationConfiguration().kittyGraphicsQueryID == nil)
  #expect(throws: ScreenError.invalidCapacity) {
    _ = try ScreenRunner(configuration: .init(kittyGraphicsQueryID: 0))
  }
}

@Test func kittyRepliesReachApplicationsInOrderAtEveryInputSplit() throws {
  let bytes = Array("a\u{1b}_Gi=31;OK\u{1b}\\b\u{1b}_Gp=2,i=9;ENOENT:missing\u{1b}\\\u{1b}[?1;2cqz".utf8)
  for split in 0...bytes.count {
    var runner = try ScreenRunner(configuration: .init())
    var application = KittyReplyApplication()
    let now = ContinuousClock().now
    var running = true
    // Every read keeps the runner's existing 64-byte batch bound.
    for range in [0..<split, split..<bytes.count] {
      var offset = range.lowerBound
      while running && offset < range.upperBound {
        let end = min(range.upperBound, offset + 64)
        running = try runner.receive(bytes.span.extracting(offset..<end), at: now, application: &application)
        offset = end
      }
    }
    #expect(!running)
    #expect(application.received == ["a", "31:OK", "b", "9:ENOENT:missing", "attributes", "q"])
    #expect(application.replies.map(\.placementID) == [nil, 2])
    // Replies retain their message after the input decoder has been reused.
    #expect(String(copying: application.replies[0].message) == "OK")
  }
}

@Test func unrelatedAndMalformedAPCsUseGenericEventsWithoutBecomingKeysOrKittyReplies() throws {
  var runner = try ScreenRunner(configuration: .init())
  var application = KittyReplyApplication()
  let bytes = "\u{1b}_unrelated\u{1b}\\\u{1b}_Gi=4294967296;OK\u{1b}\\q".utf8Span.span
  #expect(try !runner.receive(bytes, at: .now, application: &application))
  #expect(application.received == ["q"])
  #expect(application.replies.isEmpty)
  #expect(
    application.commands == [
      ApplicationCommand("unrelated".utf8Span.span), ApplicationCommand("Gi=4294967296;OK".utf8Span.span)
    ])
}

@Test func kittyReplyHandlerCanRequestRedrawOrQuitWithoutConsumingFollowingKeys() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let size = TerminalSize(columns: 1, rows: 1)
  var runner = try ScreenRunner(configuration: .init())
  var application = KittyReplyApplication()
  try runner.draw(application: &application, actualSize: size, to: output)
  _ = try capture.take()
  application.replyUpdate = .redraw
  #expect(try runner.receive("\u{1b}_Gi=1;OK\u{1b}\\".utf8Span.span, at: .now, application: &application))
  try runner.draw(application: &application, actualSize: size, to: output)
  #expect(application.frames == 2)
  application.replyUpdate = .quit
  #expect(try !runner.receive("\u{1b}_Gi=2;OK\u{1b}\\z".utf8Span.span, at: .now, application: &application))
  #expect(application.received == ["1:OK", "2:OK"])
}

private struct KittyReplyApplication: ScreenApplication {
  static var configuration: ScreenApplicationConfiguration { .init(kittyGraphicsQueryID: 31) }
  var received: [String] = []
  var replies: [KittyGraphicsReply] = []
  var commands: [ApplicationCommand] = []
  var replyUpdate = ScreenUpdate.none
  private let probe = KittyFrameProbe()
  var frames: Int { probe.frames }

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .applicationCommand(let command): commands.append(command)
    case .kittyGraphicsReply(let reply):
      replies.append(reply)
      received.append("\(reply.imageID):" + String(copying: reply.message))
      return replyUpdate
    case .primaryDeviceAttributes: received.append("attributes")
    case .key(.character(let scalar), _):
      received.append(String(scalar))
      if scalar == "q" { return .quit }
    default: Issue.record("Unexpected event")
    }
    return .none
  }

  func render(in size: TerminalSize) -> some Block {
    probe.frames += 1
    return Text("x")
  }
}

private final class KittyFrameProbe { var frames = 0 }
