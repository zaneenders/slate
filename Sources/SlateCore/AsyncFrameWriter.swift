import Foundation
import Synchronization

internal final class AsyncFrameWriter: Sendable {
  private enum CompletionState: Sendable {
    case pending
    case waiting(CheckedContinuation<Void, Never>)
    case finished
  }

  private final class CompletionStateBox: Sendable {
    private let mutex = Mutex<CompletionState>(.pending)

    func withLock<R: Sendable>(_ body: (inout sending CompletionState) -> sending R) -> R {
      mutex.withLock(body)
    }
  }

  private let streamContinuation: AsyncStream<[UInt8]>.Continuation
  private let task: Task<Void, Never>
  private let completionBox: CompletionStateBox

  init() {
    let (stream, cont) = AsyncStream<[UInt8]>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    self.streamContinuation = cont
    let box = CompletionStateBox()
    self.completionBox = box

    self.task = Task.detached(priority: .userInitiated) {
      for await bytes in stream {
        AsyncFrameWriter.writeAllToStdout(bytes: bytes)
      }
      box.withLock { s in
        switch s {
        case .pending:
          s = .finished
        case .waiting(let cont):
          s = .finished
          cont.resume()
        case .finished:
          break
        }
      }
    }
  }

  /// Hands an already-encoded frame off to the writer. Returns immediately. Safe from any
  /// isolation. If a previous frame is still being written, this frame replaces the pending
  /// one (latest wins).
  func submit(_ bytes: [UInt8]) {
    streamContinuation.yield(bytes)
  }

  /// Closes the input side of the writer; the background task drains any final pending
  /// frame and then exits. Safe to call multiple times.
  func stop() {
    streamContinuation.finish()
  }

  /// Suspends until the writer task has finished draining. Pair with ``stop()`` from
  /// teardown sites that need to ensure no further bytes are emitted to stdout (e.g.
  /// before writing tty-restore CSI sequences synchronously).
  func waitForCompletion() async {
    await withCheckedContinuation { cont in
      let alreadyDone = completionBox.withLock { s -> Bool in
        switch s {
        case .pending:
          s = .waiting(cont)
          return false
        case .finished:
          return true
        case .waiting:
          fatalError("AsyncFrameWriter.waitForCompletion() called concurrently")
        }
      }
      if alreadyDone {
        cont.resume()
      }
    }
  }

  private static func writeAllToStdout(bytes: [UInt8]) {
    unsafe bytes.withUnsafeBufferPointer { buf in
      unsafe ttyWriteStdoutAll(UnsafeRawBufferPointer(start: buf.baseAddress, count: buf.count))
    }
  }
}
