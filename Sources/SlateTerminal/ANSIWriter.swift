import SlateUI

// Shared by full-screen and region presentation; each owner retains its writer.
struct ANSIWriter: ~Copyable {
  private var bytes = InlineArray<4_096, UInt8>(repeating: 0)
  private var count = 0
  private(set) var outputBytes = 0

  mutating func reset() {
    count = 0
    outputBytes = 0
  }

  mutating func flush(to output: borrowing Output) throws(IOError) {
    guard count > 0 else { return }
    try output.writeAll(bytes.span.extracting(first: count))
    outputBytes += count
    count = 0
  }

  private mutating func byte(_ byte: UInt8, to output: borrowing Output) throws(IOError) {
    if count == bytes.count { try flush(to: output) }
    bytes[count] = byte
    count += 1
  }

  mutating func literal(_ text: StaticString, to output: borrowing Output) throws(IOError) {
    let error = text.withUTF8Buffer { buffer -> IOError? in
      do throws(IOError) {
        let span = unsafe Span(_unsafeElements: buffer)
        for index in 0..<span.count { try self.byte(span[index], to: output) }
        return nil
      } catch { return error }
    }
    if let error { throw error }
  }

  private mutating func number(_ value: Int, to output: borrowing Output) throws(IOError) {
    precondition(value >= 0 && value <= 65_535)
    var divisor = 10_000
    while divisor > 1 && value < divisor { divisor /= 10 }
    var remainder = value
    while divisor > 0 {
      try byte(UInt8(remainder / divisor) + 0x30, to: output)
      remainder %= divisor
      divisor /= 10
    }
  }

  mutating func cursor(x: Int, y: Int, to output: borrowing Output) throws(IOError) {
    try literal("\u{1b}[", to: output)
    try number(y + 1, to: output)
    try byte(0x3b, to: output)
    try number(x + 1, to: output)
    try byte(0x48, to: output)
  }

  mutating func style(_ style: Style, to output: borrowing Output) throws(IOError) {
    try literal("\u{1b}[0", to: output)
    if style.bold { try literal(";1", to: output) }
    if style.dim { try literal(";2", to: output) }
    if style.underlined { try literal(";4", to: output) }
    if style.inverse { try literal(";7", to: output) }
    if case .indexed(let value) = style.foreground {
      try literal(";38;5;", to: output)
      try number(Int(value), to: output)
    }
    if case .indexed(let value) = style.background {
      try literal(";48;5;", to: output)
      try number(Int(value), to: output)
    }
    try byte(0x6d, to: output)
  }

  mutating func glyph(_ glyph: Glyph, to output: borrowing Output) throws(IOError) {
    let value = glyph.scalar.value
    if value < 0x80 {
      try byte(UInt8(value), to: output)
    } else {
      // The only non-ASCII glyphs admitted by Glyph are three-byte box drawing.
      try byte(0xe0 | UInt8(value >> 12), to: output)
      try byte(0x80 | UInt8((value >> 6) & 0x3f), to: output)
      try byte(0x80 | UInt8(value & 0x3f), to: output)
    }
  }

  mutating func base64(_ source: Span<UInt8>, to output: borrowing Output) throws(IOError) {
    var index = 0
    while index < source.count {
      // Each group emits four bytes together, preserving the fixed buffer bound.
      if bytes.count - count < 4 { try flush(to: output) }
      let remaining = source.count - index
      let a = source[index]
      let b = remaining > 1 ? source[index + 1] : 0
      let c = remaining > 2 ? source[index + 2] : 0
      bytes[count] = base64Digit(a >> 2)
      bytes[count + 1] = base64Digit(((a & 3) << 4) | (b >> 4))
      bytes[count + 2] = remaining > 1 ? base64Digit(((b & 15) << 2) | (c >> 6)) : 0x3d
      bytes[count + 3] = remaining > 2 ? base64Digit(c & 63) : 0x3d
      count += 4
      index += min(3, remaining)
    }
  }
}

private func base64Digit(_ value: UInt8) -> UInt8 {
  precondition(value < 64)
  switch value {
  case 0..<26: return 65 + value
  case 26..<52: return 97 + value - 26
  case 52..<62: return 48 + value - 52
  case 62: return 43
  default: return 47
  }
}
