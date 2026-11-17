public import Observation

/// An observation owned by a session. Explicit refreshes replace dependencies through the same consumer.
@MainActor public final class ScreenObservation: Observable {
  private let registrar = ObservationRegistrar()
  private var value: UInt64 = 0
  private var revision: UInt64 {
    registrar.access(self, keyPath: \.revision)
    return value
  }
  init() {}
  public func refresh() {
    registrar.withMutation(of: self, keyPath: \.revision) { value &+= 1 }
  }
  func track() { _ = revision }
}
