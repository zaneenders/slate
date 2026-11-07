import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

struct PseudoTerminal: ~Copyable {
  let master: Int32
  let slave: Int32

  init() throws {
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

func attributes(of descriptor: Int32) throws -> termios {
  var attributes = termios()
  guard unsafe tcgetattr(descriptor, &attributes) == 0 else {
    throw TestError.system(errno)
  }
  return attributes
}

func expectEqual(_ actual: termios, _ expected: termios) {
  var actual = actual
  var expected = expected
  #expect(actual.c_iflag == expected.c_iflag)
  #expect(actual.c_oflag == expected.c_oflag)
  #expect(actual.c_cflag == expected.c_cflag)
  #expect(actual.c_lflag == expected.c_lflag)
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
