import SlateUI
import Testing

private enum HostCopyError: Error { case unavailable }

@Test func clipboardDeliversRawTextToTheHostAndDistinguishesEmptyCopies() throws {
  var clipboard = Clipboard()
  var calls = 0
  clipboard.flush { _ in calls += 1 }
  #expect(calls == 0)
  try clipboard.copy("old".utf8Span)
  try clipboard.copy("café".utf8Span)
  clipboard.flush { text in
    calls += 1
    #expect(String(copying: text) == "café")
  }
  try clipboard.copy("".utf8Span)
  clipboard.flush { text in
    calls += 1
    #expect(text.count == 0)
  }
  clipboard.flush { _ in calls += 1 }
  #expect(calls == 2)
}

@Test func clipboardPreservesPendingTextOnOverflowAndConsumesFailedDeliveries() throws {
  var clipboard = Clipboard()
  let maximum = String(repeating: "x", count: Clipboard.maximumTextBytes)
  let oversized = maximum + "x"
  try clipboard.copy(maximum.utf8Span)
  #expect(throws: ClipboardError.capacityExceeded) { try clipboard.copy(oversized.utf8Span) }
  #expect(throws: HostCopyError.unavailable) {
    try clipboard.flush { (text: UTF8Span) throws(HostCopyError) in
      #expect(text.count == Clipboard.maximumTextBytes)
      throw .unavailable
    }
  }
  var called = false
  clipboard.flush { _ in called = true }
  #expect(!called)
  try clipboard.copy("reused".utf8Span)
  clipboard.flush { text in #expect(String(copying: text) == "reused") }
}
