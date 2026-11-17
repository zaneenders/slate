import BasicContainers
import Synchronization

/// A single-consumer source. Queue storage is fixed at construction; payload allocation belongs to its producer.
public final class ScreenSource<Value: Sendable>: Sendable {
  public enum Policy: Sendable {
    case latest
    case ordered(capacity: Int)
  }
  public enum Publication: Equatable, Sendable { case accepted, replaced, full, closed }
  private struct State: ~Copyable {
    var values: RigidArray<Value?>
    var first = 0
    var count = 0
    var closed = false
    var continuation: CheckedContinuation<Value?, Never>?
  }
  private let state: Mutex<State>
  private let replaces: Bool

  public init(policy: Policy) {
    let capacity: Int
    switch policy {
    case .latest:
      capacity = 1
      replaces = true
    case .ordered(let maximum):
      precondition(maximum > 0 && maximum <= 65_536)
      capacity = maximum
      replaces = false
    }
    state = Mutex(State(values: RigidArray(repeating: nil, count: capacity)))
  }

  @discardableResult
  public func publish(_ value: Value) -> Publication {
    let result = state.withLock { state -> (Publication, CheckedContinuation<Value?, Never>?) in
      guard !state.closed else { return (.closed, nil) }
      if let continuation = state.continuation {
        state.continuation = nil
        return (.accepted, continuation)
      }
      if state.count == state.values.count {
        guard replaces else { return (.full, nil) }
        state.values[state.first] = value
        return (.replaced, nil)
      }
      state.values[(state.first + state.count) % state.values.count] = value
      state.count += 1
      return (.accepted, nil)
    }
    result.1?.resume(returning: value)
    return result.0
  }

  public func next() async -> Value? {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let ready = state.withLock { state -> (Bool, Value?) in
          if state.count > 0 {
            let value = state.values[state.first]
            state.values[state.first] = nil
            state.first = (state.first + 1) % state.values.count
            state.count -= 1
            return (true, value)
          }
          if state.closed || Task.isCancelled { return (true, nil) }
          precondition(state.continuation == nil, "A source has one consumer")
          state.continuation = continuation
          return (false, nil)
        }
        if ready.0 { continuation.resume(returning: ready.1) }
      }
    } onCancel: {
      self.finish()
    }
  }

  /// Discards unread values, rejects future publications, and resumes a waiting consumer with nil.
  public func finish() {
    let continuation = state.withLock {
      $0.closed = true
      for index in $0.values.indices { $0.values[index] = nil }
      $0.count = 0
      let continuation = $0.continuation
      $0.continuation = nil
      return continuation
    }
    continuation?.resume(returning: nil)
  }
}
