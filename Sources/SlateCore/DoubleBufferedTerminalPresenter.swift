/// MainActor presentation (encode + write, double-buffered)
@MainActor
internal final class DoubleBufferedTerminalPresenter {
  private var bufferA = TerminalByteBuffer(capacity: 64)
  private var bufferB = TerminalByteBuffer(capacity: 64)
  private var encodeUsesA = true
  private var capacityReserved = 0

  init() {}

  func ensureEncodedByteCapacity(for cols: Int, rows: Int) {
    let cap = slateRedrawEncodeCapacity(cols: cols, rows: rows)
    guard cap != capacityReserved else { return }
    capacityReserved = cap
    bufferA = TerminalByteBuffer(capacity: cap)
    bufferB = TerminalByteBuffer(capacity: cap)
    encodeUsesA = true
  }

  /// Encode into whichever buffer is “back”; then one raw write so the tty never receives a partial frame.
  func presentFrame(encodeIntoBack: (inout TerminalByteBuffer) -> Void) {
    if encodeUsesA {
      encodeIntoBack(&bufferA)
      unsafe ttyWriteRaw(bufferA.span.bytes)
    } else {
      encodeIntoBack(&bufferB)
      unsafe ttyWriteRaw(bufferB.span.bytes)
    }
    encodeUsesA.toggle()
  }
}

/// Bytes needed per redraw: truecolor fore/background SGR per cell, row cursor prefix, trailing reset.
private func slateRedrawEncodeCapacity(cols: Int, rows: Int) -> Int {
  precondition(cols >= 1 && rows >= 1)
  return rows &* cols &* 54 &+ rows &* 32 &+ 640
}
