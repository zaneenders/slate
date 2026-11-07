import BasicContainers

public enum ClipboardError: Error, Equatable, Sendable { case capacityExceeded }

/// One pending UTF-8 copy for the host to deliver. Latest successful copy wins;
/// rejection preserves the pending text. No clipboard reads. Owns one 64 KiB
/// startup buffer; copying and synchronous delivery never grow its storage.
public struct Clipboard: ~Copyable {
  public static let maximumTextBytes = 65_536
  private var bytes = RigidArray(repeating: UInt8(0), count: maximumTextBytes)
  private var count = 0
  private var pending = false

  public init() {}

  public mutating func copy(_ text: UTF8Span) throws(ClipboardError) {
    guard text.count <= Self.maximumTextBytes else { throw .capacityExceeded }
    let source = text.span
    for index in 0..<source.count { bytes[index] = source[index] }
    count = source.count
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
      count = 0
      pending = false
    }
    try deliver(unsafe UTF8Span(unchecked: bytes.span.extracting(first: count)))
  }
}
