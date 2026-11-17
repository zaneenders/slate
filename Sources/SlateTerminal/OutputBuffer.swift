package import BasicContainers
import Synchronization

/// Fixed startup storage for one output batch. Exhaustion rejects the entire write; typed error reporting may allocate.
public final class OutputBuffer: Sendable {
  private struct State: ~Copyable {
    var bytes: RigidArray<UInt8>
    var count: Int
  }
  public let capacity: Int
  private let state: Mutex<State>

  public init(capacity: Int) {
    precondition(capacity > 0 && capacity <= 64 * 1_048_576)
    self.capacity = capacity
    state = Mutex(State(bytes: RigidArray(repeating: 0, count: capacity), count: 0))
  }

  package func append(_ bytes: Span<UInt8>) throws(IOError) {
    try state.withLock { state throws(IOError) in
      guard bytes.count <= capacity - state.count else {
        throw .write(errno: ENOBUFS, bytesWritten: 0)
      }
      for index in bytes.indices { state.bytes[state.count + index] = bytes[index] }
      state.count += bytes.count
    }
  }

  package func take(into spare: inout RigidArray<UInt8>) -> Int {
    precondition(spare.count == capacity)
    return state.withLock {
      swap(&$0.bytes, &spare)
      let count = $0.count
      $0.count = 0
      return count
    }
  }

  package var isEmpty: Bool { state.withLock { $0.count == 0 } }

  public func reset() { state.withLock { $0.count = 0 } }
}

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
