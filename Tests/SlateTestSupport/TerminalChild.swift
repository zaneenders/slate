import CIOTestSupport
import Foundation
import SlateTerminal
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

package enum TerminalChildError: Error {
  case timeout(String)
  case system(Int32)
  case outputCapacity
}

package final class TerminalChild {
  package let pty: PseudoTerminal
  package let saved: termios
  package let pid: Int32
  private var reaped = false
  package private(set) var output = ""

  package init(executable: String = "SlateSignalFixture") throws {
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
    let executable = root.appendingPathComponent(".build/\(configuration)/\(executable)").path
    var spawned: Int32 = -1
    let slave = pty.slave
    let error = executable.withCString { unsafe cli_test_spawn_terminal($0, slave, &spawned) }
    guard error == 0 else { throw TerminalChildError.system(error) }
    pid = spawned
  }

  package func send(_ text: String) throws {
    let output = try Output(fileDescriptor: pty.master)
    try output.writeAll(text.utf8Span.span)
  }

  private func drain() throws {
    var buffer = InlineArray<4_096, UInt8>(repeating: 0)
    var readiness = pollfd(fd: pty.master, events: Int16(POLLIN), revents: 0)
    let ready = unsafe poll(&readiness, 1, 0)
    guard ready > 0 && readiness.revents & Int16(POLLIN) != 0 else { return }
    let input = try Input(fileDescriptor: pty.master)
    let count = try input.read(into: buffer.mutableSpan)
    guard output.utf8.count + count <= 256 * 1_024 else { throw TerminalChildError.outputCapacity }
    output += buffer.span.extracting(first: count).withUnsafeBufferPointer {
      unsafe String(decoding: $0, as: UTF8.self)
    }
  }

  package func awaitOutput(_ expected: String) throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
      try drain()
      if output.contains(expected) { return }
      usleep(1_000)
    }
    throw TerminalChildError.timeout("output: \(expected)")
  }

  package func awaitState() throws -> (Int32, Int32) {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
      try drain()
      var value: Int32 = 0
      let kind = unsafe cli_test_wait_terminal(pid, &value)
      if kind > 0 {
        if kind == 2 || kind == 3 { reaped = true }
        return (kind, value)
      }
      if kind < 0 { throw TerminalChildError.system(-kind) }
      usleep(1_000)
    }
    throw TerminalChildError.timeout("child state")
  }

  package func expectExit(status: Int32) throws {
    let (kind, value) = try awaitState()
    #expect(kind == 2 && value == status)
    try awaitOutput("\u{1b}[?1049l")
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
