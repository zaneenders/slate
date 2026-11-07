/// Shared input batching and deadlines. Storage is inline: sixteen events, no
/// retained input view, queue growth, allocation, or callbacks. Each supplied
/// batch is at most 64 bytes and must be drained before supplying another.
public struct TerminalInput: ~Copyable {
  private var decoder = InputDecoder()
  private var events = InlineArray<16, InputEvent>(repeating: .key(.escape))
  private var eventIndex = 0
  private var eventCount = 0
  private var escapeDeadline: ContinuousClock.Instant?
  private var responseDeadline: ContinuousClock.Instant?

  public init() {}

  /// Read immediately after receiving .terminalReply(.applicationCommand),
  /// before the next next/expire/flush call. The returned value owns its bytes.
  public var applicationCommand: ApplicationCommand { decoder.applicationCommand }

  /// The caller retains its byte buffer and cursor until this returns nil.
  /// Returning an independent event ends the borrow before event handling.
  public mutating func next(
    in bytes: Span<UInt8>, offset: inout Int, at now: ContinuousClock.Instant
  ) -> InputEvent? {
    precondition(bytes.count <= 64 && offset >= 0 && offset <= bytes.count)
    while eventIndex == eventCount {
      guard offset < bytes.count else { return nil }
      let progress = decoder.decode(bytes.extracting(offset...), into: events.mutableSpan)
      precondition(progress.bytesConsumed > 0 || progress.eventsWritten > 0)
      offset += progress.bytesConsumed
      eventIndex = 0
      eventCount = progress.eventsWritten
      escapeDeadline = decoder.hasPendingEscape ? now.advanced(by: .milliseconds(50)) : nil
      if decoder.hasPendingTerminalResponse {
        if responseDeadline == nil { responseDeadline = now.advanced(by: .milliseconds(250)) }
      } else {
        responseDeadline = nil
      }
    }
    let event = events[eventIndex]
    eventIndex += 1
    return event
  }

  /// Incomplete terminal responses expire from their first byte, even while
  /// more fragments arrive. They never become application keystrokes.
  public mutating func expire(at now: ContinuousClock.Instant) -> InputEvent? {
    if let deadline = responseDeadline, now >= deadline {
      _ = flush()
    }
    guard let deadline = escapeDeadline, now >= deadline else { return nil }
    precondition(decoder.hasPendingEscape)
    return flush()
  }

  public mutating func flush() -> InputEvent? {
    precondition(eventIndex == eventCount)
    escapeDeadline = nil
    responseDeadline = nil
    return decoder.flush()
  }

  /// Preserve incomplete paste framing when a managed session resumes.
  public mutating func resume(at now: ContinuousClock.Instant) {
    precondition(eventIndex == eventCount)
    escapeDeadline = decoder.hasPendingEscape ? now.advanced(by: .milliseconds(50)) : nil
    responseDeadline = decoder.hasPendingTerminalResponse ? now.advanced(by: .milliseconds(250)) : nil
  }
}
