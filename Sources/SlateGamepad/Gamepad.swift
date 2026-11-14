/// Device availability is separate from input: a missing controller never
/// prevents keyboard use. Linux errors are retried at the next discovery scan.
public enum GamepadStatus: Equatable, Sendable {
  case disconnected
  case connected
  case permissionDenied
  case unavailable(errno: Int32)
}

/// Single-owner, synchronous controller reader. No tasks, event queue, or terminal
/// input access. Call on the main thread on macOS to service GameController.
/// The first supported controller is retained until disconnect; others wait.
/// macOS permits one active reader per process and restores its process-wide
/// background monitoring policy when that reader is destroyed.
public struct Gamepad: ~Copyable, ~Sendable {
  private var backend = PlatformGamepad()
  private var navigation = GamepadNavigation()
  public var status: GamepadStatus { backend.status }

  public init() {}

  /// Sample once per application tick (recommended 16 ms). Sampling can miss a
  /// complete press/release between polls. Late polls emit no catch-up repeats.
  public mutating func poll(at now: ContinuousClock.Instant) -> GamepadActions {
    navigation.update(backend.sample(at: now), at: now)
  }
}
