import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

/// Exercise standard asynchronous exit signals against the general application
/// fixture and the image demo, including Linux's power signal.
package var terminalTerminationSignals: [Int32] {
  var signals = [
    SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGALRM, SIGUSR1, SIGUSR2,
    SIGVTALRM, SIGPROF, SIGXCPU, SIGXFSZ, SIGIO
  ]
  #if os(Linux)
  signals.append(SIGPWR)
  #endif
  return signals
}

package struct PseudoTerminal: ~Copyable {
  package let master: Int32
  package let slave: Int32

  package init() throws {
    var master: Int32 = -1
    var slave: Int32 = -1
    guard unsafe openpty(&master, &slave, nil, nil, nil) == 0 else {
      throw TestError.system(errno)
    }
    self.master = master
    self.slave = slave
  }

  deinit {
    _ = close(slave)
    _ = close(master)
  }
}

private enum TestError: Error {
  case system(Int32)
  case outputCapacity
  case outputTimeout
}

/// Collects bounded PTY output through terminal restoration. Reads may split
/// writes arbitrarily, including an initial echo separated from application I/O.
package func terminalOutput(from descriptor: Int32) throws -> String {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(3))
  var result: [UInt8] = []
  var bytes = InlineArray<4_096, UInt8>(repeating: 0)
  while clock.now < deadline {
    var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    let ready = unsafe poll(&readiness, 1, 20)
    if ready < 0 {
      if errno == EINTR { continue }
      throw TestError.system(errno)
    }
    if ready == 0 { continue }
    guard readiness.revents & Int16(POLLIN) != 0 else { throw TestError.system(EIO) }
    let count: Int
    do {
      var storage = bytes.mutableSpan
      count = storage.withUnsafeMutableBufferPointer {
        unsafe read(descriptor, $0.baseAddress, $0.count)
      }
    }
    if count < 0 && errno == EINTR { continue }
    guard count > 0 else { throw TestError.system(count < 0 ? errno : EIO) }
    guard result.count + count <= 256 * 1_024 else { throw TestError.outputCapacity }
    for index in 0..<count { result.append(bytes[index]) }
    let text = String(decoding: result, as: UTF8.self)
    if text.contains("\u{1b}[?1049l") { return text }
  }
  throw TestError.outputTimeout
}

package func attributes(of descriptor: Int32) throws -> termios {
  var attributes = termios()
  guard unsafe tcgetattr(descriptor, &attributes) == 0 else {
    throw TestError.system(errno)
  }
  return attributes
}

package func expectEqual(_ actual: termios, _ expected: termios) {
  var actual = actual
  var expected = expected
  #expect(actual.c_iflag == expected.c_iflag)
  #expect(actual.c_oflag == expected.c_oflag)
  #expect(actual.c_cflag == expected.c_cflag)
  #if canImport(Darwin)
  // Restoring canonical mode sets this kernel state bit even when the supplied
  // attributes omit it. Compare configuration without requiring pending-input
  // state to survive a mode transition unchanged.
  #expect(actual.c_lflag & ~tcflag_t(PENDIN) == expected.c_lflag & ~tcflag_t(PENDIN))
  #else
  #expect(actual.c_lflag == expected.c_lflag)
  #endif
  let actualInputSpeed = unsafe cfgetispeed(&actual)
  let expectedInputSpeed = unsafe cfgetispeed(&expected)
  let actualOutputSpeed = unsafe cfgetospeed(&actual)
  let expectedOutputSpeed = unsafe cfgetospeed(&expected)
  #expect(actualInputSpeed == expectedInputSpeed)
  #expect(actualOutputSpeed == expectedOutputSpeed)
  withUnsafeBytes(of: actual.c_cc) { actualCharacters in
    withUnsafeBytes(of: expected.c_cc) { expectedCharacters in
      let equal = unsafe actualCharacters.elementsEqual(expectedCharacters)
      #expect(equal)
    }
  }
}
