import CIOTestSupport
import Foundation
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

@Suite(.serialized)
struct SignalOwnershipTests {
  #if os(Linux)
  @Test func readInterruptionChecksTerminationBeforePollingOrDeliveringInput() throws {
    let pty = try PseudoTerminal()
    var size = winsize(ws_row: 1, ws_col: 1, ws_xpixel: 0, ws_ypixel: 0)
    try #require(unsafe ioctl(pty.slave, UInt(TIOCSWINSZ), &size) == 0)
    let output = try Output(fileDescriptor: pty.master)
    try output.writeAll("q".utf8Span.span)
    var set = sigset_t()
    var saved = sigset_t()
    try #require(unsafe sigemptyset(&set) == 0)
    try #require(unsafe sigaddset(&set, SIGTERM) == 0)
    try #require(unsafe pthread_sigmask(SIG_UNBLOCK, &set, &saved) == 0)
    defer { _ = unsafe pthread_sigmask(SIG_SETMASK, &saved, nil) }
    let polls: InlineArray<2, Int32> = [1, -EIO]
    polls.span.withUnsafeBufferPointer { unsafe cli_test_poll_script($0.baseAddress, $0.count) }
    cli_test_read_signal(SIGTERM)
    defer { cli_test_reset_io() }
    var application = SignalDuringQuitApplication()
    #expect(throws: ScreenApplicationError.interrupted(signal: SIGTERM)) {
      try application.run(inputFileDescriptor: pty.slave, outputFileDescriptor: pty.slave, signalHandling: .managed)
    }
    #expect(application.handledKeys == 0)
    // The second scripted poll must still be pending after termination.
    var readiness = pollfd(fd: pty.slave, events: Int16(POLLIN), revents: 0)
    #expect(unsafe poll(&readiness, 1, 0) == -1)
    #expect(errno == EIO)
  }
  #endif

  @Test func signalOwnerRejectsOverlapAndRestoresAfterScopeExit() throws {
    do {
      let owner = try SignalSession(.managed)
      let enabled = owner.enabled
      #expect(enabled)
      #expect(throws: ScreenApplicationError.signalSetup(errno: EBUSY)) { _ = try SignalSession(.managed) }
    }
    do {
      let next = try SignalSession(.managed)
      #expect(next.termination() == 0)
    }
    // A termination signal delivered in the quit callback must not become a
    // successful exit. Parent-process signal ownership is serialized by this suite.
    let pty = try PseudoTerminal()
    let saved = try attributes(of: pty.slave)
    var size = winsize(ws_row: 1, ws_col: 1, ws_xpixel: 0, ws_ypixel: 0)
    try #require(unsafe ioctl(pty.slave, UInt(TIOCSWINSZ), &size) == 0)
    let output = try Output(fileDescriptor: pty.master)
    try output.writeAll("q".utf8Span.span)
    var application = SignalDuringQuitApplication()
    #expect(throws: ScreenApplicationError.interrupted(signal: SIGTERM)) {
      try application.run(inputFileDescriptor: pty.slave, outputFileDescriptor: pty.slave, signalHandling: .managed)
    }
    #expect(application.handledKeys == 1)
    expectEqual(try attributes(of: pty.slave), saved)
  }

  // Serialize parent-process signal changes; the other tests use child processes.
  @Test func signalStateCoalescesBurstsAndRestoresDispositions() throws {
    var originalContinue = try readSignalAction(SIGCONT)
    defer { _ = unsafe sigaction(SIGCONT, &originalContinue, nil) }
    var ignoredContinue = sigaction()
    #if canImport(Darwin)
    unsafe ignoredContinue.__sigaction_u.__sa_handler = SIG_IGN
    #elseif canImport(Musl)
    unsafe ignoredContinue.__sa_handler.sa_handler = SIG_IGN
    #else
    unsafe ignoredContinue.__sigaction_handler.sa_handler = SIG_IGN
    #endif
    ignoredContinue.sa_flags = SA_RESTART
    try #require(unsafe sigemptyset(&ignoredContinue.sa_mask) == 0)
    try #require(unsafe sigaddset(&ignoredContinue.sa_mask, SIGUSR1) == 0)
    try #require(unsafe sigaction(SIGCONT, &ignoredContinue, nil) == 0)

    let numbers: InlineArray<6, Int32> = [SIGINT, SIGTERM, SIGHUP, SIGTSTP, SIGCONT, SIGPIPE]
    var saved = InlineArray<6, sigaction>(repeating: sigaction())
    for index in numbers.indices { saved[index] = try readSignalAction(numbers[index]) }
    do {
      let owner = try SignalSession(.managed)
      let unchanged = try SignalSession(.unchanged)
      #expect(unchanged.enabled == false)
      expectSignalAction(try readSignalAction(SIGPIPE), saved[5])
      #expect(throws: ScreenApplicationError.signalSetup(errno: EBUSY)) { _ = try SignalSession(.managed) }

      // Call the installed callback synchronously to make coalescing
      // deterministic. Child-process tests cover kernel delivery.
      let installed = try readSignalAction(SIGTERM)
      #if canImport(Darwin)
      let handler = try #require(unsafe installed.__sigaction_u.__sa_handler)
      #elseif canImport(Musl)
      let handler = try #require(unsafe installed.__sa_handler.sa_handler)
      #else
      let handler = try #require(unsafe installed.__sigaction_handler.sa_handler)
      #endif

      // More signals than a buffered design could retain still occupy one flag.
      for _ in 0..<4_096 { handler(SIGTSTP) }
      #expect(unchanged.shouldSuspend() == false)
      #expect(owner.shouldSuspend() == true)
      #expect(owner.shouldSuspend() == false)
      handler(SIGTSTP)
      handler(SIGCONT)
      #expect(owner.shouldSuspend() == false)
      for number in [SIGINT, SIGTERM, SIGHUP] {
        handler(number)
        #expect(owner.termination() == number)
        #expect(unchanged.termination() == 0)
      }
      #expect(owner.shouldSuspend() == false)
      #expect(owner.termination() == SIGHUP)
      // A latched termination must prevent an actual stop.
      try owner.suspend()
    }
    for index in numbers.indices { expectSignalAction(try readSignalAction(numbers[index]), saved[index]) }
    do {
      let next = try SignalSession(.managed)
      #expect(next.termination() == 0)
      #expect(next.shouldSuspend() == false)
    }
    do {
      let owner = try SignalSession(.managed)
      #expect(owner.enabled == true)
      throw ScreenApplicationError.disconnected
    } catch ScreenApplicationError.disconnected {}
    for index in numbers.indices { expectSignalAction(try readSignalAction(numbers[index]), saved[index]) }
  }
}

private func readSignalAction(_ number: Int32) throws -> sigaction {
  var result = sigaction()
  try #require(unsafe sigaction(number, nil, &result) == 0)
  return result
}

private func expectSignalAction(_ actual: sigaction, _ expected: sigaction) {
  #if canImport(Darwin)
  let actualHandler = unsafe actual.__sigaction_u.__sa_handler
  let expectedHandler = unsafe expected.__sigaction_u.__sa_handler
  #elseif canImport(Musl)
  let actualHandler = unsafe actual.__sa_handler.sa_handler
  let expectedHandler = unsafe expected.__sa_handler.sa_handler
  #else
  let actualHandler = unsafe actual.__sigaction_handler.sa_handler
  let expectedHandler = unsafe expected.__sigaction_handler.sa_handler
  #endif
  #expect(unsafe unsafeBitCast(actualHandler, to: UInt.self) == unsafeBitCast(expectedHandler, to: UInt.self))
  #expect(actual.sa_flags == expected.sa_flags)
  var actualMask = actual.sa_mask
  var expectedMask = expected.sa_mask
  for number in 1..<NSIG {
    #expect(unsafe sigismember(&actualMask, number) == sigismember(&expectedMask, number))
  }
}

private struct SignalDuringQuitApplication: ScreenApplication {
  private(set) var handledKeys = 0
  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .key(_, let modifiers): return handle(modifiers: modifiers)
    default: return .none
    }
  }

  private mutating func handle(modifiers: KeyModifiers) -> ScreenUpdate {
    handledKeys += 1
    guard modifiers.isEmpty else { return .none }
    // Make the quit-callback latch deterministic on Swift Testing workers.
    // Child-process tests below cover actual kernel signal delivery.
    var action = sigaction()
    precondition(unsafe sigaction(SIGTERM, nil, &action) == 0)
    #if canImport(Darwin)
    let handler = unsafe action.__sigaction_u.__sa_handler
    #elseif canImport(Musl)
    let handler = unsafe action.__sa_handler.sa_handler
    #else
    let handler = unsafe action.__sigaction_handler.sa_handler
    #endif
    handler!(SIGTERM)
    return .quit
  }
  func render(in size: TerminalSize) -> some Block { Text("x") }
}

@Test(arguments: [SIGINT, SIGTERM, SIGHUP])
func managedTerminationRestoresModesAndReportsSignal(_ number: Int32) throws {
  let child = try TerminalChild()
  try child.awaitOutput("\u{1b}[>1u")
  #expect(try attributes(of: child.pty.slave).c_lflag & tcflag_t(ICANON) == 0)
  try #require(kill(child.pid, number) == 0)
  let (kind, value) = try child.awaitState()
  #expect(kind == 2 && value == 128 + number)
  expectEqual(try attributes(of: child.pty.slave), child.saved)
  try child.awaitOutput("\u{1b}[?2004l")
  #expect(child.output.contains("\u{1b}[?2027r"))
  #expect(child.output.contains("\u{1b}[<u"))
  #expect(child.output.contains("\u{1b}[?25h\u{1b}[?1049l"))
}

@Test(arguments: [0, 1, 2])
func managedSuspensionRestoresThenReentersAndPreservesField(_ keyboard: Int) throws {
  let child = try TerminalChild()
  try child.awaitOutput("\u{1b}[>1u")
  try child.send("\tHello")
  // End a partial paste after resume: its q must remain text.
  try child.send("\u{1b}[200~q")
  if keyboard != 0 {
    // Ctrl-Z inside paste is data, so finish first before requesting suspend.
    try child.send("\u{1b}[201~" + (keyboard == 1 ? "\u{1a}" : "\u{1b}[122;5u"))
  } else {
    try #require(kill(child.pid, SIGTSTP) == 0)
  }
  let (kind, signal) = try child.awaitState()
  #expect(kind == 1 && signal == SIGTSTP)
  expectEqual(try attributes(of: child.pty.slave), child.saved)
  try child.awaitOutput("\u{1b}[?2004l")
  #expect(child.output.contains("\u{1b}[?2027r"))
  #expect(child.output.contains("\u{1b}[<u"))
  child.output = ""
  try #require(kill(child.pid, SIGCONT) == 0)
  try child.awaitOutput("\u{1b}[>1u")
  #expect(try attributes(of: child.pty.slave).c_lflag & tcflag_t(ICANON) == 0)
  if keyboard == 0 { try child.send("\u{1b}[201~") }
  try child.send("\u{1}\u{3}")
  try child.awaitOutput("\u{1b}]52;c;SGVsbG9x\u{1b}\\")
  try child.send("\u{1} \u{1}Hello\u{1}q\u{1}Copied\u{1}\u{3}")
  try child.awaitOutput("\u{1b}]52;c;Q29waWVk\u{1b}\\")
  try child.send("\u{1b}")
  // Lone Escape needs its normal deadline before the quit key.
  usleep(80_000)
  try child.send("q")
  let exitState = try child.awaitState()
  #expect(exitState.0 == 2 && exitState.1 == 0)
  expectEqual(try attributes(of: child.pty.slave), child.saved)
}

private enum ChildError: Error {
  case timeout(String)
  case system(Int32)
  case outputCapacity
}

private final class TerminalChild {
  let pty: PseudoTerminal
  let saved: termios
  let pid: Int32
  var reaped = false
  var output = ""

  init() throws {
    pty = try PseudoTerminal()
    saved = try attributes(of: pty.slave)
    var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    try #require(unsafe ioctl(pty.slave, UInt(TIOCSWINSZ), &size) == 0)
    for descriptor in [pty.master, pty.slave] {
      try #require(fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0)
    }
    #if DEBUG
    let configuration = "debug"
    #else
    let configuration = "release"
    #endif
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let executable = root.appendingPathComponent(".build/\(configuration)/SlateSignalFixture").path
    var spawned: Int32 = -1
    let slave = pty.slave
    let error = executable.withCString { unsafe cli_test_spawn_terminal($0, slave, &spawned) }
    guard error == 0 else { throw ChildError.system(error) }
    pid = spawned
  }

  func send(_ text: String) throws {
    let output = try Output(fileDescriptor: pty.master)
    try output.writeAll(text.utf8Span.span)
  }

  func drain() throws {
    var buffer = InlineArray<4_096, UInt8>(repeating: 0)
    var readiness = pollfd(fd: pty.master, events: Int16(POLLIN), revents: 0)
    let ready = unsafe poll(&readiness, 1, 0)
    guard ready > 0 && readiness.revents & Int16(POLLIN) != 0 else { return }
    let input = try Input(fileDescriptor: pty.master)
    let count = try input.read(into: buffer.mutableSpan)
    guard output.utf8.count + count <= 256 * 1_024 else { throw ChildError.outputCapacity }
    output += buffer.span.extracting(first: count).withUnsafeBufferPointer {
      unsafe String(decoding: $0, as: UTF8.self)
    }
  }

  func awaitOutput(_ expected: String) throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while clock.now < deadline {
      try drain()
      if output.contains(expected) { return }
      usleep(1_000)
    }
    throw ChildError.timeout("output: \(expected)")
  }

  func awaitState() throws -> (Int32, Int32) {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while clock.now < deadline {
      try drain()
      var value: Int32 = 0
      let kind = unsafe cli_test_wait_terminal(pid, &value)
      if kind > 0 {
        if kind == 2 || kind == 3 { reaped = true }
        return (kind, value)
      }
      if kind < 0 { throw ChildError.system(-kind) }
      usleep(1_000)
    }
    throw ChildError.timeout("child state")
  }

  deinit {
    if !reaped {
      _ = kill(pid, SIGKILL)
      // A killed child cannot remain suspended. No Swift runs in the child here.
      var status: Int32 = 0
      _ = unsafe waitpid(pid, &status, 0)
    }
  }
}
