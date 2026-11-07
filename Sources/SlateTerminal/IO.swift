#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Slate I/O requires Darwin, Glibc, or Musl.")
#endif

public enum IOError: Error, Equatable, Sendable {
  case duplicateDescriptor(errno: Int32)
  case read(errno: Int32)
  /// The prefix was written before the error. Retrying must skip that prefix.
  case write(errno: Int32, bytesWritten: Int)
}

/// Owns a close-on-exec duplicate; the caller keeps the original descriptor.
/// Private duplicates use descriptors >= 3, preserving closed standard streams.
/// Duplicates share file offsets and status flags, including nonblocking mode.
public struct Input: ~Copyable {
  private let descriptor: Int32

  public init(fileDescriptor: Int32 = 0) throws(IOError) {
    let duplicate = duplicateDescriptor(fileDescriptor)
    guard duplicate != -1 else { throw .duplicateDescriptor(errno: errno) }
    descriptor = duplicate
  }

  /// Reads at most `buffer.count` bytes. Only the returned prefix is modified.
  /// With a nonempty buffer, zero indicates EOF for files and pipes. Terminals
  /// can also return zero for a VMIN = 0 poll/timeout or canonical EOF character;
  /// subsequent reads may still receive input.
  /// An empty buffer returns zero without I/O. EAGAIN/EWOULDBLOCK is an error.
  /// Retries EINTR up to eight times, then throws `.read(errno: EINTR)`.
  public borrowing func read(into buffer: consuming MutableSpan<UInt8>) throws(IOError) -> Int {
    try readBytes(from: descriptor, into: consume buffer)
  }

  deinit {
    // Do not retry close after EINTR: the descriptor may already be closed.
    _ = close(descriptor)
  }
}

/// Owns a close-on-exec duplicate; accepts terminals, files, and pipes.
/// Private duplicates use descriptors >= 3, preserving closed standard streams.
/// Duplicates share file offsets and status flags. This type does not change
/// SIGPIPE handling; the process must handle or ignore it to receive EPIPE.
public struct Output: ~Copyable {
  let descriptor: Int32

  public init(fileDescriptor: Int32 = 1) throws(IOError) {
    let duplicate = duplicateDescriptor(fileDescriptor)
    guard duplicate != -1 else { throw .duplicateDescriptor(errno: errno) }
    descriptor = duplicate
  }

  /// Writes all bytes, retrying interruptions and short writes. Empty spans
  /// succeed without I/O. Other failures include progress in `IOError.write`;
  /// this method does not wait for readiness after EAGAIN/EWOULDBLOCK.
  /// Retries EINTR up to eight times without progress, then throws with EINTR.
  /// Each successful write resets the retry budget.
  public borrowing func writeAll(_ bytes: Span<UInt8>) throws(IOError) {
    try writeBytes(to: descriptor, bytes)
  }

  deinit {
    _ = close(descriptor)
  }
}

func writeBytes(to descriptor: Int32, _ bytes: Span<UInt8>) throws(IOError) {
  try bytes.withUnsafeBufferPointer { buffer throws(IOError) in
    var offset = 0
    var retries = SystemCallRetryBudget()
    while offset < buffer.count {
      // A nonempty span has a valid base address. The pointer stays in this
      // synchronous closure and the span keeps its storage borrowed.
      let count = unsafe write(
        descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
      if count > 0 {
        offset += count
        retries = SystemCallRetryBudget()
      } else if count == 0 {
        throw .write(errno: EIO, bytesWritten: offset)
      } else {
        let error = errno
        if !retries.retry(after: error) {
          throw .write(errno: error, bytesWritten: offset)
        }
      }
    }
  }
}

func writeStatic(_ text: StaticString, to descriptor: Int32) throws(IOError) {
  let error = text.withUTF8Buffer { buffer -> IOError? in
    do throws(IOError) {
      try writeBytes(to: descriptor, unsafe Span(_unsafeElements: buffer))
      return nil
    } catch { return error }
  }
  if let error { throw error }
}

/// Tolerates short signal bursts while bounding work without syscall progress.
/// Eight retries allow at most nine attempts. Blocking syscall duration is
/// controlled by the caller's descriptor settings, independently of this budget.
package struct SystemCallRetryBudget {
  package init() {}
  private var retriesRemaining = 8

  package mutating func retry(after error: Int32) -> Bool {
    guard error == EINTR && retriesRemaining > 0 else { return false }
    retriesRemaining -= 1
    return true
  }
}

func duplicateDescriptor(_ descriptor: Int32) -> Int32 {
  var retries = SystemCallRetryBudget()
  while true {
    // Reserve stdin, stdout, and stderr even when the caller has closed them.
    let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
    if duplicate != -1 { return duplicate }
    if !retries.retry(after: errno) { return -1 }
  }
}

func readBytes(
  from descriptor: Int32, into buffer: consuming MutableSpan<UInt8>
) throws(IOError) -> Int {
  guard !buffer.isEmpty else { return 0 }
  return try buffer.withUnsafeMutableBufferPointer { bytes throws(IOError) in
    var retries = SystemCallRetryBudget()
    while true {
      let count = unsafe read(descriptor, bytes.baseAddress, bytes.count)
      if count >= 0 { return count }
      let error = errno
      if !retries.retry(after: error) { throw .read(errno: error) }
    }
  }
}
