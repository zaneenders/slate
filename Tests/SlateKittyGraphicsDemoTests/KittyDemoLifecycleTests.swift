import CIOTestSupport
import Foundation
import Slate
import SlateTestSupport
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

@Test(arguments: ["\r", "\u{3}", "\u{1b}", "q", "\u{1b}[99;5u"])
func kittyDemoDeletesItsImageAndRestoresTerminalAfterExitKeys(_ key: String) throws {
  let child = try KittyDemoChild()
  try child.awaitOutput(",C=1,q=2\u{1b}\\\u{1b}8")
  #expect(try attributes(of: child.pty.slave).c_lflag & tcflag_t(ICANON | ISIG) == 0)
  try child.send(key)
  try child.expectExit(status: 0)
  try child.expectRestored()
}

@Test(arguments: terminalTerminationSignals)
func kittyDemoDeletesItsImageBeforeRestoringTerminalAfterSignals(_ number: Int32) throws {
  let child = try KittyDemoChild()
  try child.awaitOutput(",C=1,q=2\u{1b}\\\u{1b}8")
  try #require(kill(child.pid, number) == 0)
  try child.expectExit(status: 128 + number)
  try child.expectRestored()
}

@Test func kittyDemoRepositionsOnResizeWithoutUploadingAgain() throws {
  let child = try KittyDemoChild()
  try child.awaitOutput(",c=78,r=21,z=0,C=1,q=2\u{1b}\\\u{1b}8")
  var size = winsize(ws_row: 16, ws_col: 60, ws_xpixel: 0, ws_ypixel: 0)
  try #require(unsafe ioctl(child.pty.slave, UInt(TIOCSWINSZ), &size) == 0)
  try child.awaitOutput(",c=58,r=13,z=0,C=1,q=2\u{1b}\\\u{1b}8")
  try child.send("\r")
  try child.expectExit(status: 0)
  #expect(child.output.components(separatedBy: "\u{1b}_Ga=t,").count - 1 == 1)
  try child.expectRestored()
}

private enum KittyChildError: Error {
  case system(Int32)
  case timeout(String)
  case outputCapacity
}

private final class KittyDemoChild {
  let pty: PseudoTerminal
  let saved: termios
  let pid: Int32
  private var reaped = false
  private(set) var output = ""

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
    let executable = root.appendingPathComponent(".build/\(configuration)/kitty-graphics").path
    var spawned: Int32 = -1
    let slave = pty.slave
    let error = executable.withCString { unsafe cli_test_spawn_terminal($0, slave, &spawned) }
    guard error == 0 else { throw KittyChildError.system(error) }
    pid = spawned
  }

  func send(_ text: String) throws {
    let output = try Output(fileDescriptor: pty.master)
    try output.writeAll(text.utf8Span.span)
  }

  private func drain() throws {
    var readiness = pollfd(fd: pty.master, events: Int16(POLLIN), revents: 0)
    guard unsafe poll(&readiness, 1, 0) > 0 && readiness.revents & Int16(POLLIN) != 0 else { return }
    var bytes = InlineArray<4_096, UInt8>(repeating: 0)
    let input = try Input(fileDescriptor: pty.master)
    let count = try input.read(into: bytes.mutableSpan)
    guard output.utf8.count + count <= 256 * 1_024 else { throw KittyChildError.outputCapacity }
    output += bytes.span.extracting(first: count).withUnsafeBufferPointer {
      unsafe String(decoding: $0, as: UTF8.self)
    }
  }

  func awaitOutput(_ expected: String) throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
      try drain()
      if output.contains(expected) { return }
      usleep(1_000)
    }
    throw KittyChildError.timeout("output: \(expected)")
  }

  func expectExit(status: Int32) throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
      try drain()
      var value: Int32 = 0
      let kind = unsafe cli_test_wait_terminal(pid, &value)
      if kind == 2 || kind == 3 {
        reaped = true
        #expect(kind == 2 && value == status)
        try awaitOutput("\u{1b}[?1049l")
        return
      }
      if kind < 0 { throw KittyChildError.system(-kind) }
      usleep(1_000)
    }
    throw KittyChildError.timeout("child exit")
  }

  func expectRestored() throws {
    expectEqual(try attributes(of: pty.slave), saved)
    let deletion = try #require(output.range(of: "\u{1b}_Ga=d,d=I,i=1,q=2\u{1b}\\"))
    let restored = try #require(output.range(of: "\u{1b}[?25h\u{1b}[?1049l"))
    #expect(deletion.upperBound <= restored.lowerBound)
  }

  deinit {
    if !reaped {
      _ = kill(pid, SIGKILL)
      var status: Int32 = 0
      _ = unsafe waitpid(pid, &status, 0)
    }
  }
}
