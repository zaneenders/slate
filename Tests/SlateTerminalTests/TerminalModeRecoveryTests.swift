import CIOTestSupport
import SlateTestSupport
import Testing

@testable import SlateTerminal

#if os(Linux)
import Glibc

@Test(arguments: [TerminalMode.keyboard, .grapheme, .mouse, .paste, .alternate])
private func terminalModeSetupFailureRestoresOnlyCompletedState(mode: TerminalMode) throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let enable = mode.sequences.enable.withUTF8Buffer { Array($0) }
  let restore = mode.sequences.restore.withUTF8Buffer { Array($0) }
  defer { cli_test_reset_io() }
  for prefix in 0..<enable.count {
    let steps: InlineArray<2, Int32> = [Int32(prefix), -EAGAIN]
    steps.span.extracting((prefix == 0 ? 1 : 0)..<2).withUnsafeBufferPointer {
      unsafe cli_test_write_script($0.baseAddress, $0.count)
    }
    #expect(throws: IOError.write(errno: EAGAIN, bytesWritten: prefix)) {
      let session = try TerminalModeSession(output: output, mode: mode)
      try session.restore()
    }
    // Keyboard setup is one five-byte command: a failed push must never pop.
    // Other modes save/enable their first owned state with eight bytes.
    let recovery: [UInt8] = prefix == 0 ? [] : prefix < 8 ? [0x18] : restore
    #expect(try capture.take() == Array(enable.prefix(prefix)) + recovery)
  }
}
#endif
