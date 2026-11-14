import SystemPackage

// I/O reuses caller-owned buffers. Allocation checks cover release builds after
// runtime warm-up; initialization of Swift metadata is outside that guarantee.

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
public struct Input: ~Copyable, ~Sendable {
  private let descriptor: FileDescriptor

  public init(fileDescriptor: Int32 = 0) throws(IOError) {
    do { descriptor = try duplicateDescriptor(fileDescriptor) } catch {
      throw .duplicateDescriptor(errno: error.rawValue)
    }
  }

  /// Reads at most `buffer.count` bytes. Only the returned prefix is modified.
  /// With a nonempty buffer, zero indicates EOF for files and pipes. Terminals
  /// can also return zero for a VMIN = 0 poll/timeout or canonical EOF character;
  /// subsequent reads may still receive input.
  /// An empty buffer returns zero without I/O. EINTR and EAGAIN/EWOULDBLOCK
  /// are returned as errors; the caller decides when to read again.
  public borrowing func read(into buffer: consuming MutableSpan<UInt8>) throws(IOError) -> Int {
    try readBytes(from: descriptor, into: consume buffer)
  }

  deinit {
    // Do not retry close after EINTR: the descriptor may already be closed.
    try? descriptor.close()
  }
}

/// Owns a close-on-exec duplicate; accepts terminals, files, and pipes.
/// Private duplicates use descriptors >= 3, preserving closed standard streams.
/// Duplicates share file offsets and status flags. This type does not change
/// SIGPIPE handling; the process must handle or ignore it to receive EPIPE.
public struct Output: ~Copyable, ~Sendable {
  let descriptor: FileDescriptor

  public init(fileDescriptor: Int32 = 1) throws(IOError) {
    do { descriptor = try duplicateDescriptor(fileDescriptor) } catch {
      throw .duplicateDescriptor(errno: error.rawValue)
    }
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
    try? descriptor.close()
  }
}

package func writeStatic(_ text: StaticString, to output: borrowing Output) throws(IOError) {
  try writeStatic(text, to: output.descriptor)
}

func writeBytes(to descriptor: FileDescriptor, _ bytes: Span<UInt8>) throws(IOError) {
  try bytes.withUnsafeBufferPointer { buffer throws(IOError) in
    var offset = 0
    var retries = SystemCallRetryBudget()
    let storage = UnsafeRawBufferPointer(buffer)
    while offset < buffer.count {
      switch unsafe writeAttempt(to: descriptor, UnsafeRawBufferPointer(rebasing: storage[offset...])) {
      case .success(let count):
        guard count > 0 else { throw .write(errno: Errno.ioError.rawValue, bytesWritten: offset) }
        offset += count
        retries = SystemCallRetryBudget()
      case .failure(let error):
        if retries.retry(after: error.rawValue) { continue }
        throw .write(errno: error.rawValue, bytesWritten: offset)
      }
    }
  }
}

// Keep System's untyped throw and its downcast in one small optimization unit.
// Only a concrete Result crosses back to the write loop, avoiding error boxes.
@inline(never)
private func writeAttempt(to descriptor: FileDescriptor, _ bytes: UnsafeRawBufferPointer) -> Result<Int, Errno> {
  do { return .success(try unsafe descriptor.write(bytes, retryOnInterrupt: false)) } catch let error as Errno {
    return .failure(error)
  } catch {
    preconditionFailure("FileDescriptor.write only throws Errno")
  }
}

func writeStatic(_ text: StaticString, to descriptor: FileDescriptor) throws(IOError) {
  let error = text.withUTF8Buffer { buffer -> IOError? in
    do throws(IOError) {
      try writeBytes(to: descriptor, unsafe Span(_unsafeElements: buffer))
      return nil
    } catch { return error }
  }
  if let error { throw error }
}

/// Tolerates short signal bursts while bounding work without syscall progress.
/// Each budget permits eight EINTR retries; the ninth interruption is returned
/// to the caller. Blocking syscall duration is controlled by the caller's
/// descriptor settings, independently of this budget.
package struct SystemCallRetryBudget {
  package init() {}
  private var retriesRemaining = 8

  package mutating func retry(after error: Int32) -> Bool {
    guard error == EINTR && retriesRemaining > 0 else { return false }
    retriesRemaining -= 1
    return true
  }
}

func duplicateDescriptor(_ descriptor: Int32) throws(Errno) -> FileDescriptor {
  // Reserve stdin, stdout, and stderr even when the caller has closed them.
  // System's dup/dup3 interfaces do not provide this minimum-descriptor option.
  let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
  guard duplicate >= 0 else { throw Errno(rawValue: errno) }
  return FileDescriptor(rawValue: duplicate)
}

func readBytes(
  from descriptor: FileDescriptor, into buffer: consuming MutableSpan<UInt8>
) throws(IOError) -> Int {
  guard !buffer.isEmpty else { return 0 }
  // Translate inside the borrow so its throwing closure has a concrete error
  // type; an any Error crossing this scope would require an error box.
  return try buffer.withUnsafeMutableBufferPointer { bytes throws(IOError) in
    do {
      return try unsafe descriptor.read(into: UnsafeMutableRawBufferPointer(bytes), retryOnInterrupt: false)
    } catch let error as Errno {
      throw .read(errno: error.rawValue)
    } catch {
      preconditionFailure("FileDescriptor.read only throws Errno")
    }
  }
}
