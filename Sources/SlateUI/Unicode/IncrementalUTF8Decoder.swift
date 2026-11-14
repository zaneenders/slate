/// One partial scalar in eight inline bytes, shared by terminal input, viewport
/// reads, and file validation. Callers own byte offsets and recovery policy.
/// Invalid input resets the scalar; a rejected continuation is not consumed by
/// callers that need to reconsider it as a fresh terminal byte.
public struct IncrementalUTF8Decoder: ~Copyable, Sendable {
  public enum Progress: Equatable, Sendable {
    case pending
    case scalar(Unicode.Scalar)
    case invalid
  }

  @usableFromInline var value: UInt32
  @usableFromInline var remaining: UInt8
  @usableFromInline var lower: UInt8
  @usableFromInline var upper: UInt8

  @inlinable public init() {
    value = 0
    remaining = 0
    lower = 0x80
    upper = 0xbf
  }
  @inlinable public var isComplete: Bool { remaining == 0 }

  // ABI visibility on the decoder storage lets Swift serialize the body
  // across targets without unsafe package-wide CMO flags. Keep byte dispatch
  // inline so file validation can discard unused scalar values.
  @inlinable @inline(__always) public mutating func append(_ byte: UInt8) -> Progress {
    if remaining > 0 {
      guard byte >= lower && byte <= upper else {
        reset()
        return .invalid
      }
      value = value << 6 | UInt32(byte & 0x3f)
      remaining -= 1
      lower = 0x80
      upper = 0xbf
      guard remaining == 0 else { return .pending }
      // Lead and continuation bounds establish the Unicode scalar invariant.
      return .scalar(Unicode.Scalar(value)!)
    }
    if byte < 0x80 { return .scalar(Unicode.Scalar(byte)) }
    switch byte {
    case 0xc2...0xdf:
      value = UInt32(byte & 0x1f)
      remaining = 1
    case 0xe0...0xef:
      value = UInt32(byte & 0x0f)
      remaining = 2
    case 0xf0...0xf4:
      value = UInt32(byte & 0x07)
      remaining = 3
    default: return .invalid
    }
    lower = byte == 0xe0 ? 0xa0 : byte == 0xf0 ? 0x90 : 0x80
    upper = byte == 0xed ? 0x9f : byte == 0xf4 ? 0x8f : 0xbf
    return .pending
  }

  @inlinable public mutating func reset() { remaining = 0 }
}
