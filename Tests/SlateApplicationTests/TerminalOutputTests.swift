#if os(Linux)
import CIOTestSupport
import SlateApplication
import SlateTestSupport
import Testing

@Test @MainActor func terminalOutputCollectsEchoAndSplitUTF8ThroughRestoration() async throws {
  await SessionIOGate.shared.acquire()
  defer { SessionIOGate.shared.release() }
  let pty = try PseudoTerminal()
  let writer = try Output(fileDescriptor: pty.slave)
  let expected = "q\u{1b}[31mé\u{1b}[?1049l"
  try writer.writeAll(expected.utf8Span.span)
  // First return the echo alone, then split a UTF-8 scalar across reads.
  let steps: InlineArray<3, Int32> = [1, 6, 1]
  steps.span.withUnsafeBufferPointer { unsafe cli_test_read_script($0.baseAddress, $0.count) }
  defer { cli_test_reset_io() }
  #expect(try terminalOutput(from: pty.master) == expected)
}
#endif
