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

  /// Wraps `Mutex` in a class so both `init` and the detached task can hold a reference
  /// to the same recycled-buffer slot without running into `~Copyable` consume restrictions.
  private final class RecycledBox: Sendable {
    private let mutex = Mutex<ContiguousArray<UInt8>?>(nil)

    func reserveCapacity(_ n: Int) {
      mutex.withLock { slot in
        if slot == nil {
          var buf = ContiguousArray<UInt8>()
          buf.reserveCapacity(n)
          slot = buf
        } else {
          slot!.reserveCapacity(n)
        }
      }
    }

    /// Returns the parked buffer (setting the slot to nil) or an empty array if none is parked.
    func checkout() -> ContiguousArray<UInt8> {
      mutex.withLock { slot in
        guard slot != nil else { return ContiguousArray<UInt8>() }
        let b = slot!
        slot = nil
        return b
      }
    }

    /// Parks `buf` if the slot is empty; otherwise discards it (it will be freed).
    func park(_ buf: ContiguousArray<UInt8>) {
      mutex.withLock { slot in
        if slot == nil { slot = buf }
      }
    }
  }

  private let streamContinuation: AsyncStream<ContiguousArray<UInt8>>.Continuation
  private let task: Task<Void, Never>
  private let completionBox: CompletionStateBox
  /// One-slot recycled write buffer. After the writer task drains a frame it clears the
  /// buffer (keeping capacity) and parks it here so the next `submit` call can refill it
  /// without allocating. At most one additional buffer is ever allocated: if `submit` is
  /// called while the writer is still draining the previous frame (recycled slot is empty),
  /// a fresh buffer is allocated once and then joins the rotation.
  private let recycled: RecycledBox

  init() {
    let recycledBox = RecycledBox()
    let (stream, cont) = AsyncStream<ContiguousArray<UInt8>>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    self.streamContinuation = cont
    let box = CompletionStateBox()
    self.completionBox = box
    self.recycled = recycledBox

    self.task = Task.detached(priority: .userInitiated) {
      for await var bytes in stream {
        AsyncFrameWriter.writeAllToStdout(bytes)
        // Clear without releasing the backing allocation so the next submit
        // can refill it in-place (no heap activity in steady state).
        bytes.removeAll(keepingCapacity: true)
        recycledBox.park(bytes)
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

  /// Pre-allocates write-buffer capacity so the very first frame submission does not
  /// allocate. Called from `DoubleBufferedTerminalPresenter.ensureEncodedByteCapacity`.
  func reserveCapacity(_ n: Int) {
    recycled.reserveCapacity(n)
  }

  /// Copies encoded frame bytes into a recycled (or on first call, freshly allocated)
  /// write buffer and hands it to the writer task. Returns immediately. Safe from any
  /// isolation. If a previous frame is still pending in the stream it is superseded
  /// (latest wins) and its buffer is immediately recycled — no allocation occurs.
  func submit(_ source: borrowing TerminalByteBuffer) {
    // Check out the recycled buffer, falling back to a one-time allocation.
    var buf = recycled.checkout()

    // Refill without reallocating (capacity is reserved after the first frame).
    buf.removeAll(keepingCapacity: true)
    let raw = unsafe source.span.bytes
    #if compiler(>=6.4)
    raw.withUnsafeBytes { src in
      guard src.count > 0, let base = src.baseAddress else { return }
      unsafe buf.append(
        contentsOf: unsafe UnsafeBufferPointer<UInt8>(
          start: base.assumingMemoryBound(to: UInt8.self),
          count: src.count))
    }
    #else
    unsafe raw.withUnsafeBytes { src in
      guard src.count > 0, let base = src.baseAddress else { return }
      unsafe buf.append(
        contentsOf: unsafe UnsafeBufferPointer<UInt8>(
          start: base.assumingMemoryBound(to: UInt8.self),
          count: src.count))
    }
    #endif

    // Yield to the stream. If a pending frame is superseded (latest-wins drop), recycle
    // its buffer immediately so no capacity is wasted between frames.
    let result = streamContinuation.yield(buf)
    if case .dropped(var dropped) = result {
      dropped.removeAll(keepingCapacity: true)
      recycled.park(dropped)
    }
  }

  /// Closes the writer's input stream so the background task drains its last pending frame
  /// and exits. Pair with ``waitForCompletion()`` before writing further bytes to stdout.
  func stop() {
    streamContinuation.finish()
  }

  /// Suspends until the writer task has finished draining. Safe to call once.
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

  private static func writeAllToStdout(_ bytes: ContiguousArray<UInt8>) {
    unsafe bytes.withUnsafeBufferPointer { buf in
      unsafe ttyWriteStdoutAll(UnsafeRawBufferPointer(start: buf.baseAddress, count: buf.count))
    }
  }
}
