import CIOTestSupport
import Testing

@testable import SlateApplication

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

@Test func applicationDrawsInitiallyAndCoalescesOnlyRequestedUpdates() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var runner = try ScreenRunner(configuration: .init())
  var application = ProbeApplication()
  let size = TerminalSize(columns: 4, rows: 2)
  let now = ContinuousClock().now
  try runner.draw(application: &application, actualSize: size, to: output)
  #expect(application.probe.sizes == [size])
  #expect(!(try capture.take()).isEmpty)

  let ignored: InlineArray<2, UInt8> = [0x78, 0xff]
  #expect(runner.receive(ignored.span, at: now, application: &application))
  try runner.draw(application: &application, actualSize: size, to: output)
  try runner.draw(application: &application, actualSize: size, to: output)
  #expect(application.probe.sizes.count == 1)
  #expect(try capture.take().isEmpty)
  #expect(application.probe.keys == [.scalar("x")])

  let redraws: InlineArray<3, UInt8> = [0x72, 0x78, 0x72]
  #expect(runner.receive(redraws.span, at: now, application: &application))
  try runner.draw(application: &application, actualSize: size, to: output)
  #expect(application.probe.sizes.count == 2)
}

@Test func applicationDeliversMaximumInputBatchAndRecoveryAcrossEventCapacity() throws {
  var runner = try ScreenRunner(configuration: .init())
  var application = ProbeApplication()
  let now = ContinuousClock().now
  let incomplete: InlineArray<1, UInt8> = [0xc2]
  #expect(runner.receive(incomplete.span, at: now, application: &application))
  // 65 decoder events (one invalid prefix plus 64 keys) must reuse 16 slots.
  let bytes = InlineArray<64, UInt8>(repeating: 0x61)
  #expect(runner.receive(bytes.span, at: now, application: &application))
  #expect(application.probe.keys == Array(repeating: .scalar("a"), count: 64))
}

@Test func applicationEscapeDeadlineDeliversExactlyOnceAndCanQuit() throws {
  var runner = try ScreenRunner(configuration: .init())
  var application = ProbeApplication()
  let now = ContinuousClock().now
  let escape: InlineArray<1, UInt8> = [0x1b]
  #expect(runner.receive(escape.span, at: now, application: &application))
  #expect(runner.expireEscape(at: now.advanced(by: .milliseconds(49)), application: &application))
  #expect(application.probe.keys.isEmpty)
  // Empty input must not postpone the original deadline.
  #expect(runner.receive(Span(), at: now.advanced(by: .milliseconds(49)), application: &application))
  #expect(runner.expireEscape(at: now.advanced(by: .milliseconds(50)), application: &application))
  #expect(runner.expireEscape(at: now.advanced(by: .seconds(1)), application: &application))
  #expect(application.probe.keys == [.escape])

  application.quitKey = .escape
  #expect(runner.receive(escape.span, at: now, application: &application))
  #expect(!runner.expireEscape(at: now.advanced(by: .milliseconds(50)), application: &application))
  #expect(application.probe.keys == [.escape, .escape])
}

@Test func applicationRunRestoresTerminalOnQuitAndLeavesOriginalDescriptorsOpen() throws {
  let pty = try PseudoTerminal()
  try setApplicationTerminalSize(pty.slave)
  let saved = try attributes(of: pty.slave)
  try queueApplicationInput([0x71], to: pty.master)
  var application = ProbeApplication()
  try application.run(inputFileDescriptor: pty.slave, outputFileDescriptor: pty.slave)
  #expect(application.probe.keys == [.scalar("q")])
  #expect(application.probe.sizes == [TerminalSize(columns: 4, rows: 2)])
  expectEqual(try attributes(of: pty.slave), saved)
  #expect(fcntl(pty.master, F_GETFD) >= 0)
  try expectApplicationScreenRestored(pty.master)
}

@Test func applicationRunRejectsNonterminalOutputBeforeChangingInput() throws {
  let pty = try PseudoTerminal()
  let saved = try attributes(of: pty.slave)
  let capture = try ScreenCapture()
  var application = ProbeApplication()
  do {
    try application.run(inputFileDescriptor: pty.slave, outputFileDescriptor: capture.descriptor)
    Issue.record("Nonterminal output was accepted")
  } catch { #expect(error == .terminal(.readSize(errno: ENOTTY))) }
  expectEqual(try attributes(of: pty.slave), saved)
  #expect(try capture.take().isEmpty)
}

@Test func applicationLayoutExhaustionUnwindsBothTerminalScopes() throws {
  let pty = try PseudoTerminal()
  try setApplicationTerminalSize(pty.slave)
  let saved = try attributes(of: pty.slave)
  var application = LimitedApplication()
  do {
    try application.run(inputFileDescriptor: pty.slave, outputFileDescriptor: pty.slave)
    Issue.record("Node exhaustion was ignored")
  } catch { #expect(error == .screen(.layout(.nodeCapacityExceeded))) }
  expectEqual(try attributes(of: pty.slave), saved)
  try expectApplicationScreenRestored(pty.master)
}

#if os(Linux)

@Test func applicationPollExhaustionUnwindsBothTerminalScopes() throws {
  let pty = try PseudoTerminal()
  try setApplicationTerminalSize(pty.slave)
  let saved = try attributes(of: pty.slave)
  let steps = InlineArray<9, Int32>(repeating: -EINTR)
  steps.span.withUnsafeBufferPointer { unsafe cli_test_poll_script($0.baseAddress, $0.count) }
  defer { cli_test_reset_io() }
  var application = ProbeApplication()
  do {
    try application.run(inputFileDescriptor: pty.slave, outputFileDescriptor: pty.slave)
    Issue.record("Nine poll interruptions were accepted")
  } catch { #expect(error == .poll(errno: EINTR)) }
  expectEqual(try attributes(of: pty.slave), saved)
  #expect(application.probe.sizes.count == 1)
  try expectApplicationScreenRestored(pty.master)
}

@Test func applicationReadFailureUnwindsBothTerminalScopes() throws {
  let pty = try PseudoTerminal()
  try setApplicationTerminalSize(pty.slave)
  let saved = try attributes(of: pty.slave)
  try queueApplicationInput([0x71], to: pty.master)
  let steps: InlineArray<1, Int32> = [-EIO]
  steps.span.withUnsafeBufferPointer { unsafe cli_test_read_script($0.baseAddress, $0.count) }
  defer { cli_test_reset_io() }
  var application = ProbeApplication()
  do {
    try application.run(inputFileDescriptor: pty.slave, outputFileDescriptor: pty.slave)
    Issue.record("Input failure was ignored")
  } catch { #expect(error == .io(.read(errno: EIO))) }
  expectEqual(try attributes(of: pty.slave), saved)
  try expectApplicationScreenRestored(pty.master)
}

@Test(arguments: [0, 1, 2, 3, 4])
func applicationOutputFailureRestoresDuringSetupDrawOrExit(successfulWrites: Int) throws {
  let pty = try PseudoTerminal()
  try setApplicationTerminalSize(pty.slave)
  let saved = try attributes(of: pty.slave)
  if successfulWrites >= 3 { try queueApplicationInput([0x71], to: pty.master) }
  var steps = InlineArray<5, Int32>(repeating: 4_096)
  steps[successfulWrites] = -EIO
  steps.span.extracting(first: successfulWrites + 1).withUnsafeBufferPointer {
    unsafe cli_test_write_script($0.baseAddress, $0.count)
  }
  defer { cli_test_reset_io() }
  var application = ProbeApplication()
  do {
    try application.run(inputFileDescriptor: pty.slave, outputFileDescriptor: pty.slave)
    Issue.record("Output failure was ignored")
  } catch {
    let failure = IOError.write(errno: EIO, bytesWritten: 0)
    #expect(error == (successfulWrites == 2 ? .screen(.output(failure)) : .io(failure)))
  }
  expectEqual(try attributes(of: pty.slave), saved)
  try expectApplicationScreenRestored(pty.master)
}
#endif

@Test func applicationDeliversWholePastesAndRejectsOverflowWithoutLeakingKeys() throws {
  var runner = try ScreenRunner(configuration: .init())
  var application = ProbeApplication()
  let now = ContinuousClock().now
  for count in [0, 65_535, 65_536, 65_537] {
    let body = String(repeating: "q", count: count)
    let bytes = Array(("\u{1b}[200~" + body + "\u{1b}[201~j").utf8)
    for start in stride(from: 0, to: bytes.count, by: 64) {
      #expect(
        runner.receive(bytes.span.extracting(start..<min(start + 64, bytes.count)), at: now, application: &application))
    }
    #expect(application.probe.keys.last == .scalar("j"))
    if count <= 65_536 { #expect(application.probe.pastes.last == body) }
  }
  #expect(application.probe.pastes.count == 3)
  #expect(application.probe.pasteErrors == [.capacityExceeded])
  #expect(application.probe.keys == Array(repeating: .scalar("j"), count: 4))
  let bad: [UInt8] = Array("\u{1b}[200~".utf8) + [0xff] + Array("\u{1b}[201~".utf8)
  #expect(runner.receive(bad.span, at: now, application: &application))
  #expect(application.probe.pasteErrors.last == .invalidUTF8)
}

private final class ApplicationProbe {
  var keys: [InputKey] = []
  var sizes: [TerminalSize] = []
  var pastes: [String] = []
  var pasteErrors: [PasteError] = []
}

// Noncopyable application state verifies that the runner borrows the view and
// mutates the original owner instead of requiring a copied application value.
private struct ProbeApplication: ScreenApplication, ~Copyable {
  let probe = ApplicationProbe()
  var quitKey: InputKey = .scalar("q")

  mutating func paste(_ text: UTF8Span) -> ScreenUpdate {
    probe.pastes.append(String(copying: text))
    return .redraw
  }

  mutating func pasteRejected(_ error: PasteError) -> ScreenUpdate {
    probe.pasteErrors.append(error)
    return .redraw
  }

  mutating func handle(_ key: InputKey) -> ScreenUpdate {
    probe.keys.append(key)
    if key == quitKey { return .quit }
    return key == .scalar("r") ? .redraw : .none
  }

  func render(in size: TerminalSize) -> some Block {
    probe.sizes.append(size)
    return Text("App")
  }
}

private struct LimitedApplication: ScreenApplication {
  static var configuration: ScreenApplicationConfiguration { .init(nodeCapacity: 1) }
  mutating func handle(_ key: InputKey) -> ScreenUpdate { .quit }
  func render(in size: TerminalSize) -> some Block { Text("x") }
}

private func setApplicationTerminalSize(_ descriptor: Int32) throws {
  var size = winsize(ws_row: 2, ws_col: 4, ws_xpixel: 0, ws_ypixel: 0)
  try #require(unsafe ioctl(descriptor, UInt(TIOCSWINSZ), &size) == 0)
}

private func queueApplicationInput(_ bytes: [UInt8], to descriptor: Int32) throws {
  let output = try Output(fileDescriptor: descriptor)
  try bytes.withUnsafeBufferPointer { buffer throws(IOError) in
    try output.writeAll(unsafe Span(_unsafeElements: buffer))
  }
}

private func expectApplicationScreenRestored(_ master: Int32) throws {
  var bytes = InlineArray<4_096, UInt8>(repeating: 0)
  let input = try Input(fileDescriptor: master)
  var received = ""
  // PTYs can split writes into separate reads. Input queued before raw mode can
  // also be echoed; only the complete restoration sequence matters here.
  for _ in 0..<16 {
    var readiness = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
    try #require(unsafe poll(&readiness, 1, 100) == 1)
    let count = try input.read(into: bytes.mutableSpan)
    try #require(count > 0)
    received += bytes.span.extracting(first: count).withUnsafeBufferPointer {
      unsafe String(decoding: $0, as: UTF8.self)
    }
    if received.contains("\u{1b}[0m\u{1b}[?25h\u{1b}[?1049l") { return }
  }
  Issue.record("Alternate-screen restoration exceeded the output budget")
}

@Test func applicationIgnoresTerminalRepliesAndEmitsOnlyCellOutput() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var runner = try ScreenRunner(configuration: .init())
  var application = ProbeApplication()
  let size = TerminalSize(columns: 4, rows: 2)
  try runner.draw(application: &application, actualSize: size, to: output)
  let response = Array("\u{1b}_extension response\u{1b}\\\u{1b}[?1;2cr".utf8)
  #expect(runner.receive(response.span, at: .now, application: &application))
  try runner.draw(application: &application, actualSize: size, to: output)
  #expect(application.probe.keys == [.scalar("r")])
  let emitted = String(decoding: try capture.take(), as: UTF8.self)
  #expect(emitted.contains("App"))
  #expect(!emitted.contains("\u{1b}_") && !emitted.contains("\u{1b}[c"))
}
