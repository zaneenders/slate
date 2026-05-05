/// Encode each frame on the caller thread/actor, then **hand off** the bytes
/// to ``AsyncFrameWriter`` so the actual blocking `write(2)` to the tty happens off-actor.
///
/// Encoding produces a single contiguous byte stream into a ``RigidArray<UInt8>`` reused
/// across frames (double-buffered between A and B so two consecutive `presentFrame` calls do
/// not stomp each other while the writer is still draining). The bytes are then **copied**
/// out into a `[UInt8]` and submitted to the writer; this copy is a single ~`cols × rows × 54`
/// memcpy (≈300 KB at 143×38) which finishes in well under a millisecond on modern hardware.
/// In exchange the encoder never blocks on tty drain, so input handling stays responsive
/// during long terminal renders.
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
  }

  /// Encode into whichever buffer is "back", then submit a copy to the async writer. The tty
  /// never receives a partial frame because each submission is a single self-contained byte
  /// run.
  func presentFrame(encodeIntoBack: (inout TerminalByteBuffer) -> Void) {
    if encodeUsesA {
      encodeIntoBack(&bufferA)
      writer.submit(copyContiguousBytes(bufferA))
    } else {
      encodeIntoBack(&bufferB)
      writer.submit(copyContiguousBytes(bufferB))
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

  /// Materializes the encoded byte slice into an owned `[UInt8]` so the writer task can read
  /// it without keeping the presenter's reusable buffer alive — keeping the copy here also
  /// means the writer's API does not depend on slate's `RigidArray` types. The copy is a
  /// single bulk memory copy (one allocation + `memcpy`-equivalent), not a per-byte append
  /// loop, so a 300 KB frame finishes in well under a millisecond.
  private func copyContiguousBytes(_ buf: borrowing TerminalByteBuffer) -> [UInt8] {
    let raw = unsafe buf.span.bytes
    #if compiler(>=6.4)
    return raw.withUnsafeBytes { src in
      unsafe Array(unsafe src.bindMemory(to: UInt8.self))
    }
    #else
    return unsafe raw.withUnsafeBytes { src in
      unsafe Array(unsafe src.bindMemory(to: UInt8.self))
    }
    #endif
  }
}

/// Bytes needed per redraw: truecolor fore/background SGR per cell, row cursor prefix, trailing reset.
private func slateRedrawEncodeCapacity(cols: Int, rows: Int) -> Int {
  precondition(cols >= 1 && rows >= 1)
  return rows &* cols &* 54 &+ rows &* 32 &+ 640
}
