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

@Test func terminalClipboardEncodesEmptyPaddingUnicodeAndMaximumCopiesExactly() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var clipboard = Clipboard()
  for text in ["", "a", "ab", "abc", "café", String(repeating: "x", count: Clipboard.maximumTextBytes)] {
    try clipboard.copy(text.utf8Span)
    try clipboard.flush(to: output)
    let encoded = Data(text.utf8).base64EncodedString()
    #expect(try capture.take() == Array("\u{1b}]52;c;\(encoded)\u{1b}\\".utf8))
    try clipboard.flush(to: output)
    #expect(try capture.take().isEmpty)
  }
}

#if os(Linux)
@Test func terminalClipboardReportsTotalProgressAndCancelsAPartialMultiBufferWrite() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var clipboard = Clipboard()
  try clipboard.copy(String(repeating: "x", count: 8_192).utf8Span)
  let steps: InlineArray<3, Int32> = [4_096, 5, -EAGAIN]
  steps.span.withUnsafeBufferPointer { unsafe cli_test_write_script($0.baseAddress, $0.count) }
  defer { cli_test_reset_io() }
  var progress = 0
  do {
    try clipboard.flush(to: output)
    Issue.record("Expected scripted output failure")
  } catch {
    guard case .write(let number, let bytesWritten) = error else {
      Issue.record("Unexpected error: \(error)")
      return
    }
    #expect(number == EAGAIN)
    progress = bytesWritten
  }
  let bytes = try capture.take()
  #expect(bytes.suffix(3) == Array("\u{18}\u{1b}\\".utf8))
  #expect(progress > 4_096 && progress == bytes.count - 3)
  try clipboard.flush(to: output)
  #expect(try capture.take().isEmpty)
}
#endif
