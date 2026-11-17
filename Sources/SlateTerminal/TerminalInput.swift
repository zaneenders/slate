public enum TerminalInputError: Error, Equatable, Sendable {
  /// An expired APC response did not terminate within 250 ms or 4,096 bytes.
  /// The owner is permanently failed; its remaining bytes must never be replayed.
  case responseRecoveryExceeded
  case finished
}

/// Shared input batching and deadlines. Storage is inline: sixteen events, no
/// retained input view, queue growth, allocation, or callbacks. Each supplied
/// batch is at most 64 bytes and must be drained before supplying another.
/// An incomplete APC expires after 250 ms. Recovery discards through ST with
/// another 250 ms and 4,096 bytes; exhaustion permanently fails this owner.
public struct TerminalInput: ~Copyable, Sendable {
  public static let maximumResponseRecoveryBytes = 4_096
  private var decoder = InputDecoder()
  private var events = InlineArray<16, InputEvent>(repeating: .key(.escape))
  private var eventIndex = 0
  private var eventCount = 0
  private var escapeDeadline: ContinuousClock.Instant?
  private var responseDeadline: ContinuousClock.Instant?
  private var recoveryDeadline: ContinuousClock.Instant?
  private var recoveryBytes = 0
  private var failure: TerminalInputError?
  private var finished = false

  package var hasPendingDeadline: Bool {
    escapeDeadline != nil || responseDeadline != nil || recoveryDeadline != nil
  }

  public init() {}

  /// Read immediately after receiving .terminalReply(.applicationCommand),
  /// before the next next/expire/finish call. The returned value owns its bytes.
  public var applicationCommand: ApplicationCommand { decoder.applicationCommand }

  /// The caller retains its byte buffer and cursor until this returns nil.
  /// Returning an independent event ends the borrow before event handling.
  /// Deadlines are checked before decoding, including when expire was not called.
  /// A framing failure is sticky: create a new owner only for a new input stream.
  public mutating func next(
    in bytes: Span<UInt8>, offset: inout Int, at now: ContinuousClock.Instant
  ) throws(TerminalInputError) -> InputEvent? {
    precondition(bytes.count <= 64 && offset >= 0 && offset <= bytes.count)
    try checkResponseDeadline(at: now)
    while eventIndex == eventCount {
      guard offset < bytes.count else { return nil }
      // During recovery, stop exactly at ST, then decode the remaining suffix
      // normally. A discarded payload never shares a decode call with keys.
      let end = recoveryDeadline == nil ? bytes.count : offset + 1
      let progress = decoder.decode(bytes.extracting(offset..<end), into: events.mutableSpan)
      precondition(progress.bytesConsumed > 0 || progress.eventsWritten > 0)
      offset += progress.bytesConsumed
      eventIndex = 0
      eventCount = progress.eventsWritten
      escapeDeadline = decoder.hasPendingEscape ? now.advanced(by: .milliseconds(50)) : nil
      if decoder.hasPendingTerminalResponse {
        if recoveryDeadline != nil {
          recoveryBytes += progress.bytesConsumed
          if recoveryBytes == Self.maximumResponseRecoveryBytes { try failRecovery() }
        } else if responseDeadline == nil {
          responseDeadline = now.advanced(by: .milliseconds(250))
        }
      } else {
        responseDeadline = nil
        recoveryDeadline = nil
        recoveryBytes = 0
      }
    }
    let event = events[eventIndex]
    eventIndex += 1
    return event
  }

  /// Call after draining the current batch. Response timeout starts bounded
  /// discard rather than resetting to keyboard input. Lone Escape expires once.
  public mutating func expire(at now: ContinuousClock.Instant) throws(TerminalInputError) -> InputEvent? {
    precondition(eventIndex == eventCount)
    try checkResponseDeadline(at: now)
    guard let deadline = escapeDeadline, now >= deadline else { return nil }
    escapeDeadline = nil
    return decoder.expireEscape()
  }

  /// EOF only. Finishes pending input once and closes this owner. Timeouts must
  /// use expire; finishing never makes a response tail available as keystrokes.
  public mutating func finish() -> InputEvent? {
    precondition(eventIndex == eventCount)
    guard !finished else { return nil }
    finished = true
    return decoder.finish()
  }

  /// Preserve framing when resuming input. Only lone Escape gets a fresh
  /// deadline; suspension does not renew a response's recovery allowance.
  public mutating func resume(at now: ContinuousClock.Instant) {
    precondition(eventIndex == eventCount)
    escapeDeadline = decoder.hasPendingEscape ? now.advanced(by: .milliseconds(50)) : nil
  }

  private mutating func checkResponseDeadline(at now: ContinuousClock.Instant) throws(TerminalInputError) {
    if let failure { throw failure }
    guard !finished else { throw .finished }
    if recoveryDeadline == nil, let deadline = responseDeadline, now >= deadline {
      decoder.discardTerminalResponse()
      recoveryDeadline = deadline.advanced(by: .milliseconds(250))
    }
    if let deadline = recoveryDeadline, now >= deadline { try failRecovery() }
  }

  private mutating func failRecovery() throws(TerminalInputError) {
    failure = .responseRecoveryExceeded
    eventIndex = eventCount
    throw .responseRecoveryExceeded
  }
}
