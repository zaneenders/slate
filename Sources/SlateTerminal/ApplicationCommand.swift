/// A bounded APC terminal response, excluding ESC _ and its ESC \ terminator.
/// Protocol-specific interpretation belongs to optional terminal extensions.
/// Retains the first 160 bytes and consumes excess detail without storing it.
public struct ApplicationCommand: Equatable, Sendable {
  public static let maximumBytes = 160
  private var storage = InlineArray<160, UInt8>(repeating: 0)
  public private(set) var count = 0
  public private(set) var truncated = false

  public init() {}

  public init(_ bytes: Span<UInt8>) {
    for index in 0..<min(bytes.count, Self.maximumBytes) { append(bytes[index]) }
    truncated = bytes.count > Self.maximumBytes
  }

  public var bytes: Span<UInt8> { storage.span.extracting(first: count) }

  mutating func append(_ byte: UInt8) {
    if count < storage.count {
      storage[count] = byte
      count += 1
    } else {
      truncated = true
    }
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    guard lhs.count == rhs.count, lhs.truncated == rhs.truncated else { return false }
    for index in 0..<lhs.count where lhs.storage[index] != rhs.storage[index] { return false }
    return true
  }
}
