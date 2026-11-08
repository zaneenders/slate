import SlateUI
import Testing

private enum HostCopyError: Error { case unavailable }

@Test func copyBufferDeliversRawTextToTheHostAndDistinguishesEmptyCopies() {
  var copyBuffer = CopyBuffer()
  var calls = 0
  copyBuffer.flush { _ in calls += 1 }
  #expect(calls == 0)
  copyBuffer.copy("old".utf8Span)
  copyBuffer.copy("café".utf8Span)
  copyBuffer.flush { text in
    calls += 1
    #expect(String(copying: text) == "café")
  }
  copyBuffer.copy("".utf8Span)
  copyBuffer.flush { text in
    calls += 1
    #expect(text.count == 0)
  }
  copyBuffer.flush { _ in calls += 1 }
  #expect(calls == 2)
}

@Test func copyBufferGrowsBeyond64KiBAndReplacesPendingCopies() {
  var copyBuffer = CopyBuffer()
  for count in [65_535, 65_536, 65_537, 131_073, 2, 131_073] {
    let text = String(repeating: "x", count: count - 2) + "é"
    copyBuffer.copy("old".utf8Span)
    copyBuffer.copy(text.utf8Span)
    copyBuffer.flush { delivered in #expect(String(copying: delivered) == text) }
  }
  copyBuffer.copy(String(repeating: "x", count: 131_073).utf8Span)
  copyBuffer.copy("".utf8Span)
  var delivered = false
  copyBuffer.flush { text in
    delivered = true
    #expect(text.count == 0)
  }
  #expect(delivered)
}

@Test func copyBufferConsumesFailedDeliveriesAndCanBeReused() {
  var copyBuffer = CopyBuffer()
  let text = String(repeating: "x", count: 131_073)
  copyBuffer.copy(text.utf8Span)
  #expect(throws: HostCopyError.unavailable) {
    try copyBuffer.flush { (delivered: UTF8Span) throws(HostCopyError) in
      #expect(String(copying: delivered) == text)
      throw .unavailable
    }
  }
  var called = false
  copyBuffer.flush { _ in called = true }
  #expect(!called)
  copyBuffer.copy("reused".utf8Span)
  copyBuffer.flush { text in #expect(String(copying: text) == "reused") }
}
