import BasicContainers

/// Batched ANSI escape output with SGR state tracking.
///
/// Tracks the terminal's believed **SGR state** so back-to-back cells with identical
/// attributes do not re-emit `SGR`.  Does **not** track cursor position per-cell; the
/// renderer emits at most one `CUP` per row.
@safe
public struct OutputBuffer: ~Copyable {
  private var bytes: RigidArray<UInt8>

  /// Pre-allocated capacity; typically `max(4096, cols * rows * 70)`.
  public init(capacity: Int) {
    self.bytes = RigidArray(capacity: capacity)
  }

  public mutating func removeAll() {
    bytes.removeAll()
  }

  public mutating func append(_ byte: UInt8) {
    bytes.append(byte)
  }

  // MARK: - Cursor

  public mutating func emitCUP(row: Int, column: Int) {
    precondition(row >= 1 && column >= 1)
    append(0x1B)  // ESC
    append(0x5B)  // [
    appendPositiveInt(row)
    append(0x3B)  // ;
    appendPositiveInt(column)
    append(0x48)  // H
  }

  // MARK: - SGR

  public mutating func emitSGR(_ attrs: Attributes, previous: Attributes?) {
    let prev = previous ?? Attributes(foreground: .default, background: .default)

    if attrs.style.contains(.bold) != prev.style.contains(.bold) {
      if attrs.style.contains(.bold) {
        emitBytes([0x1B, 0x5B, 0x31, 0x6D])
      } else {
        emitBytes([0x1B, 0x5B, 0x32, 0x32, 0x6D])
      }
    }

    if attrs.style.contains(.italic) != prev.style.contains(.italic) {
      if attrs.style.contains(.italic) {
        emitBytes([0x1B, 0x5B, 0x33, 0x6D])
      } else {
        emitBytes([0x1B, 0x5B, 0x32, 0x33, 0x6D])
      }
    }

    if attrs.style.contains(.underline) != prev.style.contains(.underline) {
      if attrs.style.contains(.underline) {
        emitBytes([0x1B, 0x5B, 0x34, 0x6D])
      } else {
        emitBytes([0x1B, 0x5B, 0x32, 0x34, 0x6D])
      }
    }

    if attrs.style.contains(.strikethrough) != prev.style.contains(.strikethrough) {
      if attrs.style.contains(.strikethrough) {
        emitBytes([0x1B, 0x5B, 0x39, 0x6D])
      } else {
        emitBytes([0x1B, 0x5B, 0x32, 0x39, 0x6D])
      }
    }

    if attrs.foreground != prev.foreground {
      emitBytes([0x1B, 0x5B, 0x33, 0x38, 0x3B, 0x32, 0x3B])
      appendPositiveInt(Int(attrs.foreground.r))
      append(0x3B)
      appendPositiveInt(Int(attrs.foreground.g))
      append(0x3B)
      appendPositiveInt(Int(attrs.foreground.b))
      append(0x6D)
    }

    if attrs.background != prev.background {
      emitBytes([0x1B, 0x5B, 0x34, 0x38, 0x3B, 0x32, 0x3B])
      appendPositiveInt(Int(attrs.background.r))
      append(0x3B)
      appendPositiveInt(Int(attrs.background.g))
      append(0x3B)
      appendPositiveInt(Int(attrs.background.b))
      append(0x6D)
    }
  }

  public mutating func emitSGRReset() {
    emitBytes([0x1B, 0x5B, 0x30, 0x6D])
  }

  // MARK: - Synchronized output

  public mutating func emitSyncOn() {
    emitBytes([0x1B, 0x5B, 0x3F, 0x32, 0x30, 0x32, 0x36, 0x68])
  }

  public mutating func emitSyncOff() {
    emitBytes([0x1B, 0x5B, 0x3F, 0x32, 0x30, 0x32, 0x36, 0x6C])
  }

  // MARK: - UTF-8

  public mutating func emitScalar(_ scalar: Unicode.Scalar) {
    let encoded = Unicode.UTF8.encode(scalar)!
    for byte in encoded {
      append(byte)
    }
  }

  // MARK: - Flush

  public func writeToStdout() {
    guard bytes.count > 0 else { return }
    var buf = [UInt8]()
    buf.reserveCapacity(bytes.count)
    for i in 0..<bytes.count {
      buf.append(bytes[i])
    }
    unsafe buf.withUnsafeBufferPointer { ptr in
      unsafe ttyWriteStdoutAll(UnsafeRawBufferPointer(start: ptr.baseAddress, count: ptr.count))
    }
  }

  // MARK: - Helpers

  private mutating func emitBytes(_ seq: [UInt8]) {
    for b in seq { append(b) }
  }

  private mutating func appendPositiveInt(_ value: Int) {
    if value < 10 {
      append(UInt8(truncatingIfNeeded: value) &+ 0x30)
      return
    }
    appendPositiveInt(value / 10)
    append(UInt8(truncatingIfNeeded: value % 10) &+ 0x30)
  }
}
