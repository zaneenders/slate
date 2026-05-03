import Foundation

/// Decouples blocking `write(2)` syscalls on the controlling tty from the actor that built
/// the frame.
///
/// Slate's encoder can run on any isolation; writing a full ~300 KB truecolor frame to a tty
/// can block for tens-to-hundreds of milliseconds while the terminal drains its kernel pipe
/// buffer. If that blocking happens on the same isolation domain as stdin handling, keystrokes
/// during that window can be queued behind it — perceived as input lag if stdin handling shares that isolation.
///
/// `AsyncFrameWriter` owns a single off-actor `Task` that performs the actual `write(2)` loop.
/// The caller copies the encoded bytes once (a fast memcpy) and submits them via
/// ``submit(_:)``. Blocking `write` uses ``ttyWriteStdoutAll(_:)``. Submission is non-blocking: at most **one** frame is held pending; if the
/// writer is busy with a previous frame when a new one arrives, the new frame replaces the
/// pending one and the older frame is dropped (intermediate frames during a typing burst /
/// streaming SSE run are visually irrelevant — only the latest state matters).
///
/// Lifecycle: ``stop()`` finishes the underlying stream so the writer task drains any
/// pending frame and exits; ``waitForCompletion()`` blocks the caller until the task is
/// fully done so callers (notably `Slate.deinit`) can guarantee restoration sequences are
/// written *after* the last frame has been flushed.
internal final class AsyncFrameWriter: Sendable {
  private let continuation: AsyncStream<[UInt8]>.Continuation
  private let task: Task<Void, Never>
  private let doneSemaphore: DispatchSemaphore

  init() {
    let (stream, cont) = AsyncStream<[UInt8]>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    self.continuation = cont
    let semaphore = DispatchSemaphore(value: 0)
    self.doneSemaphore = semaphore
    self.task = Task.detached(priority: .userInitiated) {
      for await bytes in stream {
        AsyncFrameWriter.writeAllToStdout(bytes: bytes)
      }
      semaphore.signal()
    }
  }

  /// Hands an already-encoded frame off to the writer. Returns immediately. Safe from any
  /// isolation. If a previous frame is still being written, this frame replaces the pending
  /// one (latest wins).
  func submit(_ bytes: [UInt8]) {
    continuation.yield(bytes)
  }

  /// Closes the input side of the writer; the background task drains any final pending
  /// frame and then exits. Safe to call multiple times.
  func stop() {
    continuation.finish()
  }

  /// Blocks the calling thread until the writer task has finished draining. Pair with
  /// ``stop()`` from teardown sites that need to ensure no further bytes are emitted to
  /// stdout (e.g. before writing tty-restore CSI sequences synchronously). `DispatchSemaphore`
  /// is idempotent for our purposes here: subsequent `wait()` calls after the first one
  /// completes will block forever, so callers are expected to call it at most once.
  func waitForCompletion() {
    doneSemaphore.wait()
  }

  private static func writeAllToStdout(bytes: [UInt8]) {
    unsafe bytes.withUnsafeBufferPointer { buf in
      unsafe ttyWriteStdoutAll(UnsafeRawBufferPointer(start: buf.baseAddress, count: buf.count))
    }
  }
}
