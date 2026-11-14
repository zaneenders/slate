import CIOTestSupport
import Dispatch
import Foundation
import SlateTestSupport
import Synchronization
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
      #expect(signalHandlerAddress(try readSignalAction(SIGPIPE)) == signalHandlerAddress(ignoredContinue))
      #expect(signalHandlerAddress(try readSignalAction(SIGTSTP)) == signalHandlerAddress(ignoredContinue))
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
      for _ in 0..<4_096 { handler(SIGINT) }
      #expect(owner.termination() == SIGINT)
      for number in [SIGTERM, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2] {
        handler(number)
        #expect(owner.termination() == SIGINT)
        #expect(unchanged.termination() == 0)
      }
      #expect(owner.termination() == SIGINT)
    }
    for index in numbers.indices { expectSignalAction(try readSignalAction(numbers[index]), saved[index]) }
    do {
      let next = try SignalSession(.managed)
      #expect(next.termination() == 0)
    }
    do {
      let owner = try SignalSession(.managed)
      #expect(owner.enabled == true)
      throw ScreenApplicationError.disconnected
    } catch ScreenApplicationError.disconnected {}
    for index in numbers.indices { expectSignalAction(try readSignalAction(numbers[index]), saved[index]) }
  }

  @Test func signalsStayMaskedDuringSetupAndTeardownAndKeepTheFirstCause() throws {
    // Darwin cannot target a dispatch worker with pthread_kill; raise then
    // falls back to process delivery. Use an ordinary thread for thread-mask
    // assertions, and report its observations back on the test's own task.
    let result = Mutex<Result<[SignalMaskObservation], any Error>?>(nil)
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      let observations = Result { try observeSignalMaskDelivery() }
      result.withLock { $0 = observations }
      finished.signal()
    }
    finished.wait()
    let observations = try result.withLock { try $0!.get() }
    for observation in observations {
      #expect(observation.actual == observation.expected, "\(observation.operation)")
    }
  }

  @Test func managedSignalDispositionsRestoreWithoutReplacingRuntimeCrashOrChildHandlers() throws {
    let numbers = [
      SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGALRM, SIGUSR1, SIGUSR2, SIGVTALRM, SIGPROF,
      SIGXCPU, SIGXFSZ, SIGIO, SIGTSTP, SIGTTIN, SIGTTOU, SIGPIPE, SIGCONT, SIGWINCH,
      SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGSYS, SIGTRAP, SIGCHLD
    ]
    let saved = try numbers.map { try readSignalAction($0) }
    do {
      let owner = try SignalSession(.managed)
      for index in numbers.indices
      where [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGSYS, SIGTRAP, SIGCHLD]
        .contains(numbers[index])
      {
        expectSignalAction(try readSignalAction(numbers[index]), saved[index])
      }
      let enabled = owner.enabled
      #expect(enabled)
    }
    for index in numbers.indices { expectSignalAction(try readSignalAction(numbers[index]), saved[index]) }
  }
}

private struct SignalMaskObservation: Sendable {
  let operation: String
  let actual: Int32
  let expected: Int32
}

private func observeSignalMaskDelivery() throws -> [SignalMaskObservation] {
  var observations: [SignalMaskObservation] = []
  var original = try readSignalMask()
  defer { _ = unsafe pthread_sigmask(SIG_SETMASK, &original, nil) }
  var requested = original
  guard unsafe sigaddset(&requested, SIGALRM) == 0,
    unsafe sigdelset(&requested, SIGTERM) == 0,
    unsafe sigdelset(&requested, SIGUSR1) == 0
  else { throw ChildError.system(errno) }
  let maskError = unsafe pthread_sigmask(SIG_SETMASK, &requested, nil)
  guard maskError == 0 else { throw ChildError.system(maskError) }
  do {
    let owner = try SignalSession(.managed)
    var mask = try readSignalMask()
    for number in [SIGTERM, SIGUSR1, SIGTTIN, SIGTTOU, SIGCHLD] {
      observations.append(
        .init(
          operation: "setup blocks signal \(number)", actual: unsafe sigismember(&mask, number), expected: 1))
    }
    for number in [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGSYS, SIGTRAP] {
      observations.append(
        .init(
          operation: "setup preserves fault signal \(number)", actual: unsafe sigismember(&mask, number),
          expected: unsafe sigismember(&requested, number)))
    }
    guard raise(SIGTERM) == 0 else { throw ChildError.system(errno) }
    observations.append(.init(operation: "setup defers delivery", actual: owner.termination(), expected: 0))
    try owner.resumeDelivery()
    observations.append(.init(operation: "resume delivers termination", actual: owner.termination(), expected: SIGTERM))
    appendMaskObservations(try readSignalMask(), requested, into: &observations)
    owner.protectTeardown()
    guard raise(SIGUSR1) == 0 else { throw ChildError.system(errno) }
    observations.append(.init(operation: "teardown defers delivery", actual: owner.termination(), expected: SIGTERM))
    try owner.resumeDelivery()
    observations.append(.init(operation: "resume retains first cause", actual: owner.termination(), expected: SIGTERM))
  }
  appendMaskObservations(try readSignalMask(), requested, into: &observations)
  do { _ = try SignalSession(.unchanged) }
  appendMaskObservations(try readSignalMask(), requested, into: &observations)
  return observations
}

private func appendMaskObservations(
  _ actual: sigset_t, _ expected: sigset_t, into observations: inout [SignalMaskObservation]
) {
  var actual = actual
  var expected = expected
  for number in 1..<NSIG {
    observations.append(
      .init(
        operation: "restored mask for signal \(number)", actual: unsafe sigismember(&actual, number),
        expected: unsafe sigismember(&expected, number)))
  }
}

private func readSignalMask() throws -> sigset_t {
  var mask = sigset_t()
  let error = unsafe pthread_sigmask(SIG_SETMASK, nil, &mask)
  guard error == 0 else { throw ChildError.system(error) }
  return mask
}

private func readSignalAction(_ number: Int32) throws -> sigaction {
  var result = sigaction()
  try #require(unsafe sigaction(number, nil, &result) == 0)
  return result
}

private func signalHandlerAddress(_ action: sigaction) -> UInt {
  #if canImport(Darwin)
  let handler = unsafe action.__sigaction_u.__sa_handler
  #elseif canImport(Musl)
  let handler = unsafe action.__sa_handler.sa_handler
  #else
  let handler = unsafe action.__sigaction_handler.sa_handler
  #endif
  return unsafe unsafeBitCast(handler, to: UInt.self)
}

private func expectSignalAction(_ actual: sigaction, _ expected: sigaction) {
  #expect(signalHandlerAddress(actual) == signalHandlerAddress(expected))
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

@Test(arguments: terminalTerminationSignals)
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

@Test(arguments: [SIGTTIN, SIGTTOU, SIGPIPE, SIGCONT, SIGWINCH])
func managedIgnoredSignalsLeaveTheSessionUsable(_ number: Int32) throws {
  let child = try TerminalChild()
  try child.awaitOutput("\u{1b}[>1u")
  try #require(kill(child.pid, number) == 0)
  try child.send("q")
  let (kind, value) = try child.awaitState()
  #expect(kind == 2 && value == 0)
  expectEqual(try attributes(of: child.pty.slave), child.saved)
  try child.awaitOutput("\u{1b}[?25h\u{1b}[?1049l")
}

@Test(arguments: [false, true])
func signalBurstsDuringTeardownFinishCleanupAndPreserveTheInitialCause(_ hasInitialTermination: Bool) throws {
  let child = try TerminalChild()
  try child.awaitOutput("\u{1b}[>1u")
  try child.send(hasInitialTermination ? "@" : "!")
  let (kind, value) = try child.awaitState()
  #expect(kind == 2 && value == 128 + (hasInitialTermination ? SIGTERM : SIGUSR1))
  expectEqual(try attributes(of: child.pty.slave), child.saved)
  try child.awaitOutput("\u{1b}[?25h\u{1b}[?1049l")
  let cleaned = try #require(child.output.range(of: "teardown complete"))
  let restored = try #require(child.output.range(of: "\u{1b}[?25h\u{1b}[?1049l"))
  #expect(cleaned.upperBound <= restored.lowerBound)
}

@Test(arguments: [1, 5, 69, 133, 197])
func managedRawModeAllowsApplicationsToRebindCtrlZ(_ keyboard: Int) throws {
  let child = try TerminalChild()
  try child.awaitOutput("\u{1b}[>1u")
  #expect(try attributes(of: child.pty.slave).c_lflag & tcflag_t(ISIG) == 0)
  try child.send(keyboard == 1 ? "\u{1a}" : "\u{1b}[122;\(keyboard)u")
  let (kind, value) = try child.awaitState()
  #expect(kind == 2 && value == 0)
  expectEqual(try attributes(of: child.pty.slave), child.saved)
  try child.awaitOutput("\u{1b}[<u")
}

@Test(arguments: [1, 5, 69, 133, 197])
func managedSIGTSTPLeavesRawModeAndPasteFramingActive(_ keyboard: Int) throws {
  let child = try TerminalChild()
  try child.awaitOutput("\u{1b}[>1u")
  try child.send("\tHello")
  try child.awaitOutput("Hello")
  // An intercepted signal must not reset or reinterpret an in-progress paste.
  try child.send("\u{1b}[200~q")
  try #require(kill(child.pid, SIGTSTP) == 0)
  try child.send("\u{1b}[201~")
  try child.send(keyboard > 1 ? "\u{1b}[97;\(keyboard)u\u{1b}[99;\(keyboard)u" : "\u{1}\u{3}")
  try child.awaitOutput("\u{1b}]52;c;SGVsbG9x\u{1b}\\")
  #expect(try attributes(of: child.pty.slave).c_lflag & tcflag_t(ICANON | ISIG) == 0)
  #expect(!child.output.contains("\u{1b}[?2004l"))
  #expect(!child.output.contains("\u{1b}[?2027r"))
  #expect(!child.output.contains("\u{1b}[<u"))
  try child.send("\u{1} \u{1}Hello\u{1}q\u{1}Copied\u{1}\u{3}")
  try child.awaitOutput("\u{1b}]52;c;Q29waWVk\u{1b}\\")
  try child.send("\u{1b}[27uq")
  let exitState = try child.awaitState()
  #expect(exitState.0 == 2 && exitState.1 == 0)
  expectEqual(try attributes(of: child.pty.slave), child.saved)
}

@Test func managedSIGTSTPDoesNotInvokeTheApplicationCtrlZBinding() throws {
  let child = try TerminalChild()
  try child.awaitOutput("\u{1b}[>1u")
  try #require(kill(child.pid, SIGTSTP) == 0)
  try child.send("\tHello\u{1}\u{3}")
  try child.awaitOutput("\u{1b}]52;c;SGVsbG8=\u{1b}\\")
  // Only an actual Ctrl-Z keypress may invoke the fixture's quit binding.
  try child.send("\u{1a}")
  let (kind, value) = try child.awaitState()
  #expect(kind == 2 && value == 0)
  expectEqual(try attributes(of: child.pty.slave), child.saved)
  try child.awaitOutput("\u{1b}[<u")
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
