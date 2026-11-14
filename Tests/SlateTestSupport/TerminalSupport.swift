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
