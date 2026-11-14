import SlateUI

// Shared by cell presentation and terminal extensions; each owner retains its writer.
package struct ANSIWriter: ~Copyable {
  let capabilities: TerminalCapabilities
  private var bytes = InlineArray<4_096, UInt8>(repeating: 0)
  private var count = 0
  package private(set) var outputBytes = 0

  package init(capabilities: TerminalCapabilities = .init()) { self.capabilities = capabilities }

  mutating func reset() {
    count = 0
    outputBytes = 0
  }

  package mutating func flush(to output: borrowing Output) throws(IOError) {
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

  package mutating func literal(_ text: StaticString, to output: borrowing Output) throws(IOError) {
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

  /// Encodes full-width parameters independently of the bounded cell coordinates.
  package mutating func unsignedNumber(_ value: UInt32, to output: borrowing Output) throws(IOError) {
    var divisor: UInt32 = 1_000_000_000
    while divisor > 1 && value < divisor { divisor /= 10 }
    var remainder = value
    while divisor > 0 {
      try byte(UInt8(remainder / divisor) + 0x30, to: output)
      remainder %= divisor
      divisor /= 10
    }
  }

  package mutating func signedNumber(_ value: Int32, to output: borrowing Output) throws(IOError) {
    if value < 0 { try byte(0x2d, to: output) }
    try unsignedNumber(value.magnitude, to: output)
  }

  package mutating func cursor(x: Int, y: Int, to output: borrowing Output) throws(IOError) {
    try literal("\u{1b}[", to: output)
    try number(y + 1, to: output)
    try byte(0x3b, to: output)
    try number(x + 1, to: output)
    try byte(0x48, to: output)
  }

  mutating func style(
    _ requested: Style, previous: Style? = nil, to output: borrowing Output
  ) throws(IOError) {
    let style = resolved(requested)
    let previous = previous.map { resolved($0) }
    // Color-only transitions preserve active text attributes. A full reset
    // handles unknown previous state and changes to text attributes.
    // Uses the existing buffer; at most two palette parameters replace a reset
    // plus all attributes and both colors. Default colors use SGR 39 and 49.
    if let previous,
      style.bold == previous.bold && style.dim == previous.dim
        && style.underlined == previous.underlined && style.inverse == previous.inverse
    {
      let foregroundChanged = style.foreground != previous.foreground
      let backgroundChanged = style.background != previous.background
      guard foregroundChanged || backgroundChanged else { return }
      try literal("\u{1b}[", to: output)
      if foregroundChanged {
        try color(style.foreground, foreground: true, to: output)
      }
      if backgroundChanged {
        if foregroundChanged { try byte(0x3b, to: output) }
        try color(style.background, foreground: false, to: output)
      }
      try byte(0x6d, to: output)
      return
    }
    try literal("\u{1b}[0", to: output)
    if style.bold { try literal(";1", to: output) }
    if style.dim { try literal(";2", to: output) }
    if style.underlined { try literal(";4", to: output) }
    if style.inverse { try literal(";7", to: output) }
    if style.foreground != .default {
      try byte(0x3b, to: output)
      try color(style.foreground, foreground: true, to: output)
    }
    if style.background != .default {
      try byte(0x3b, to: output)
      try color(style.background, foreground: false, to: output)
    }
    try byte(0x6d, to: output)
  }

  private func resolved(_ requested: Style) -> Style {
    var style = requested
    style.foreground = capabilities.resolve(requested.foreground)
    style.background = capabilities.resolve(requested.background)
    return style
  }

  private mutating func color(_ color: Color, foreground: Bool, to output: borrowing Output) throws(IOError) {
    switch color {
    case .default: try number(foreground ? 39 : 49, to: output)
    case .indexed(let value):
      if capabilities.color == .ansi16 {
        precondition(value < 16)
        try number((foreground ? 30 : 40) + Int(value % 8) + (value < 8 ? 0 : 60), to: output)
      } else {
        try literal(foreground ? "38;5;" : "48;5;", to: output)
        try number(Int(value), to: output)
      }
    case .rgb(let red, let green, let blue):
      try literal(foreground ? "38;2;" : "48;2;", to: output)
      try number(Int(red), to: output)
      try byte(0x3b, to: output)
      try number(Int(green), to: output)
      try byte(0x3b, to: output)
      try number(Int(blue), to: output)
    }
  }

  mutating func glyph(_ glyph: Glyph, to output: borrowing Output) throws(IOError) {
    if capabilities.unicode == .ascii && (glyph.byteCount != 1 || glyph.scalar.value > 0x7f) {
      try byte(0x3f, to: output)
      if glyph.columnWidth == 2 { try byte(0x20, to: output) }
      return
    }
    let source = glyph.utf8().span
    for index in 0..<source.count { try byte(source[index], to: output) }
  }

  package mutating func base64(_ source: Span<UInt8>, to output: borrowing Output) throws(IOError) {
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
