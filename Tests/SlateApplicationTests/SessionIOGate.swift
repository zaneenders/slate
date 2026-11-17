import BasicContainers

/// Fault scripts are process-wide so the terminal worker can consume them.
@MainActor final class SessionIOGate {
  static let shared = SessionIOGate()
  private var occupied = false
  private var waiters = RigidArray<CheckedContinuation<Void, Never>?>(repeating: nil, count: 128)
  private var first = 0
  private var count = 0

  func acquire() async {
    if !occupied {
      occupied = true
      return
    }
    await withCheckedContinuation { continuation in
      precondition(count < waiters.count)
      waiters[(first + count) % waiters.count] = continuation
      count += 1
    }
  }

  func release() {
    precondition(occupied)
    if count == 0 {
      occupied = false
      return
    }
    let continuation = waiters[first]!
    waiters[first] = nil
    first = (first + 1) % waiters.count
    count -= 1
    continuation.resume()
  }
}
