/// One inline timer, with no queue, task, callback allocation, or catch-up loop.
/// Store an interval origin rather than adding an arbitrary public Duration to
/// an Instant: even extremely large positive intervals cannot overflow a deadline.
struct TickSchedule {
  private var interval: Duration?
  private var origin: ContinuousClock.Instant?

  mutating func synchronize(interval: Duration?, at now: ContinuousClock.Instant)
    throws(ScreenApplicationError)
  {
    if let interval, interval <= .zero { throw .invalidTickInterval }
    guard interval != self.interval else { return }
    self.interval = interval
    origin = interval == nil ? nil : now
  }

  /// Preserve the existing 50 ms resize/Escape polling bound. Round fractional
  /// milliseconds up so a positive remainder cannot cause a busy poll loop.
  func timeoutMilliseconds(at now: ContinuousClock.Instant) -> Int32 {
    guard let interval, let origin else { return 50 }
    let elapsed = max(.zero, origin.duration(to: now))
    guard elapsed < interval else { return 0 }
    let remaining = interval - elapsed
    guard remaining < .milliseconds(50) else { return 50 }
    let attoseconds = remaining.components.attoseconds
    let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
    return Int32((attoseconds + attosecondsPerMillisecond - 1) / attosecondsPerMillisecond)
  }

  mutating func next(at now: ContinuousClock.Instant) -> Duration? {
    guard let interval, let origin else { return nil }
    let elapsed = origin.duration(to: now)
    guard elapsed >= interval else { return nil }
    self.origin = now
    return elapsed
  }
}
