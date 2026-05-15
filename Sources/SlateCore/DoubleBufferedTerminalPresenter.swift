/// Encode each frame on the caller thread/actor, then **hand off** the bytes
/// to ``AsyncFrameWriter`` so the actual blocking `write(2)` to the tty happens off-actor.
///
/// Encoding produces a single contiguous byte stream into a ``RigidArray<UInt8>`` reused
/// across frames (double-buffered between A and B so two consecutive `presentFrame` calls do
/// not stomp each other while the writer is still draining). The encoded bytes are then
/// copied into a pre-allocated ``ContiguousArray<UInt8>`` that ``AsyncFrameWriter`` recycles
/// across frames — no heap allocation occurs in steady state. In exchange the encoder never
/// blocks on tty drain, so input handling stays responsive during long terminal renders.
internal final class DoubleBufferedTerminalPresenter {
  private var bufferA = TerminalByteBuffer(capacity: 64)
  private var bufferB = TerminalByteBuffer(capacity: 64)
  private var encodeUsesA = true
  private var capacityReserved = 0
  private let writer = AsyncFrameWriter()

  init() {}

  func ensureEncodedByteCapacity(for cols: Int, rows: Int) {
    let cap = slateRedrawEncodeCapacity(cols: cols, rows: rows)
    guard cap != capacityReserved else { return }
    capacityReserved = cap
    bufferA = TerminalByteBuffer(capacity: cap)
    bufferB = TerminalByteBuffer(capacity: cap)
    encodeUsesA = true
    // Pre-allocate the writer's recycled buffer so the first frame submission
    // doesn't allocate at render time.
    writer.reserveCapacity(cap)
  }

  /// Encode into whichever buffer is "back", then submit to the async writer. The tty
  /// never receives a partial frame because each submission is a single self-contained byte
  /// run. No heap allocation occurs after the first call to ``ensureEncodedByteCapacity``.
  func presentFrame(encodeIntoBack: (inout TerminalByteBuffer) -> Void) {
    if encodeUsesA {
      encodeIntoBack(&bufferA)
      writer.submit(bufferA)
    } else {
      encodeIntoBack(&bufferB)
      writer.submit(bufferB)
    }
    encodeUsesA.toggle()
  }

  /// Closes the writer's input stream so the background task drains its last pending frame
  /// and exits, then suspends until that drain completes. Callers that need to write further
  /// bytes synchronously to stdout afterwards (e.g. ``ttyRestoreSaved()``) **must** call
  /// this first to preserve ordering between final rendered frame and restore sequences.
  @MainActor
  func flushAndStopWriter() async {
    writer.stop()
    await writer.waitForCompletion()
  }
}

/// Bytes needed per redraw: truecolor fore/background SGR per cell, row cursor prefix, trailing reset.
private func slateRedrawEncodeCapacity(cols: Int, rows: Int) -> Int {
  precondition(cols >= 1 && rows >= 1)
  return rows &* cols &* 54 &+ rows &* 32 &+ 640
}
