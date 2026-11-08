import BasicContainers

/// One pending UTF-8 copy for the host to deliver. Latest copy wins; no clipboard
/// reads. Explicit copy requests may allocate storage proportional to their text.
/// Capacity is retained for reuse; synchronous delivery never grows storage.
public struct CopyBuffer: ~Copyable, Sendable {
  // TODO: Learn more about system copy/paste machinery, including native
  // clipboard ownership, terminal OSC 52 limits, and options for large copies.
  private var bytes = UniqueArray<UInt8>()
  private var pending = false

  public init() {}

  public mutating func copy(_ text: UTF8Span) {
    bytes.removeAll()
    bytes.append(copying: text.span)
    pending = true
  }

  /// Delivers one borrowed copy, including an empty copy, to the host callback.
  /// The attempt consumes the pending copy even if delivery fails. The callback
  /// runs synchronously and must finish before this storage is reused.
  public mutating func flush<Failure: Error>(
    _ deliver: (UTF8Span) throws(Failure) -> Void
  ) throws(Failure) {
    guard pending else { return }
    defer {
      bytes.removeAll()
      pending = false
    }
    try deliver(unsafe UTF8Span(unchecked: bytes.span))
  }
}
