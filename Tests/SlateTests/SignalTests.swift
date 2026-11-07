import CIOTestSupport
import Foundation
import Testing

@testable import SlateApplication

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
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
  // successful exit. Keep all parent-process signal ownership in this one test.
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
  expectEqual(try attributes(of: pty.slave), saved)
}

private struct SignalDuringQuitApplication: ScreenApplication {
  mutating func handle(_ key: InputKey) -> ScreenUpdate {
    // Swift Testing's worker can inherit a blocked SIGTERM. Deliver synchronously
    // to this thread while the managed owner is installed, then restore its mask.
    var set = sigset_t()
    var saved = sigset_t()
    precondition(unsafe sigemptyset(&set) == 0)
    precondition(unsafe sigaddset(&set, SIGTERM) == 0)
    precondition(unsafe pthread_sigmask(SIG_UNBLOCK, &set, &saved) == 0)
    defer { _ = unsafe pthread_sigmask(SIG_SETMASK, &saved, nil) }
    precondition(raise(SIGTERM) == 0)
    return .quit
  }
  func render(in size: TerminalSize) -> some Block { Text("x") }
}

@Test(arguments: [SIGINT, SIGTERM, SIGHUP])
func managedTerminationRestoresModesAndReportsSignal(_ number: Int32) throws {
  let child = try TerminalChild()
  try child.awaitOutput("\u{1b}[?2004h")
  #expect(try attributes(of: child.pty.slave).c_lflag & tcflag_t(ICANON) == 0)
  try #require(kill(child.pid, number) == 0)
  let (kind, value) = try child.awaitState()
  #expect(kind == 2 && value == 128 + number)
  expectEqual(try attributes(of: child.pty.slave), child.saved)
  try child.awaitOutput("\u{1b}[?2004l")
  #expect(child.output.contains("\u{1b}[?25h\u{1b}[?1049l"))
}

@Test(arguments: [false, true])
func managedSuspensionRestoresThenReentersAndPreservesField(_ keyboard: Bool) throws {
  let child = try TerminalChild()
  try child.awaitOutput("\u{1b}[?2004h")
  try child.send("\tHello")
  // End a partial paste after resume: its q must remain text.
  try child.send("\u{1b}[200~q")
  if keyboard {
    // Ctrl-Z inside paste is data, so finish first before requesting suspend.
    try child.send("\u{1b}[201~\u{1a}")
  } else {
    try #require(kill(child.pid, SIGTSTP) == 0)
  }
  let (kind, signal) = try child.awaitState()
  #expect(kind == 1 && signal == SIGTSTP)
  expectEqual(try attributes(of: child.pty.slave), child.saved)
  try child.awaitOutput("\u{1b}[?2004l")
  child.output = ""
  try #require(kill(child.pid, SIGCONT) == 0)
  try child.awaitOutput("\u{1b}[?2004h")
  #expect(try attributes(of: child.pty.slave).c_lflag & tcflag_t(ICANON) == 0)
  if !keyboard { try child.send("\u{1b}[201~") }
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
