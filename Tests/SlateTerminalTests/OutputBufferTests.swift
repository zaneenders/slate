import BasicContainers
import Testing

@testable import SlateTerminal

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Test func bufferedOutputRejectsOverflowAtomicallyAndReusesItsStorage() throws {
  let buffer = OutputBuffer(capacity: 8)
  let output = Output(buffer: buffer)
  var spare = RigidArray<UInt8>(repeating: 0, count: 8)
  for _ in 0..<100 {
    try output.writeAll("abcd".utf8Span.span)
    #expect(throws: IOError.write(errno: ENOBUFS, bytesWritten: 0)) { try output.writeAll("12345".utf8Span.span) }
    try output.writeAll("efgh".utf8Span.span)
    #expect(buffer.take(into: &spare) == 8)
    #expect(String(copying: try UTF8Span(validating: spare.span)) == "abcdefgh")
    #expect(buffer.isEmpty)
  }
  try output.writeAll("ab".utf8Span.span)
  buffer.reset()
  #expect(buffer.take(into: &spare) == 0)
}

@Test func bufferedOutputReportsUnsupportedTerminalQueriesAndModeChanges() throws {
  let output = Output(buffer: OutputBuffer(capacity: 128))
  #expect(throws: TerminalError.readSize(errno: ENOTTY)) { try output.terminalSize() }
  #expect(throws: IOError.write(errno: ENOTTY, bytesWritten: 0)) { _ = try output.alternateScreen() }
}
