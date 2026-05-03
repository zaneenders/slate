import BasicContainers

public typealias TerminalByteBuffer = RigidArray<UInt8>

// MARK: - CSI emission into `TerminalByteBuffer` (no intermediate `String`)

@inline(__always)
private func appendEscBracket(to buf: inout TerminalByteBuffer) {
  buf.append(0x1B)
  buf.append(0x5B)
}

/// Decimal encoding for non-negative `Int` (used for CUP rows/columns and RGB components).
private func appendPositiveIntDecimal(_ value: Int, to buf: inout TerminalByteBuffer) {
  precondition(value >= 0)
  if value >= 100 {
    buf.append(UInt8(truncatingIfNeeded: value / 100) &+ 0x30)
    buf.append(UInt8(truncatingIfNeeded: (value / 10) % 10) &+ 0x30)
    buf.append(UInt8(truncatingIfNeeded: value % 10) &+ 0x30)
  } else if value >= 10 {
    buf.append(UInt8(truncatingIfNeeded: value / 10) &+ 0x30)
    buf.append(UInt8(truncatingIfNeeded: value % 10) &+ 0x30)
  } else {
    buf.append(UInt8(truncatingIfNeeded: value) &+ 0x30)
  }
}

private func appendCup(row row1: Int, column col1: Int, to buf: inout TerminalByteBuffer) {
  precondition(row1 >= 1 && col1 >= 1)
  appendEscBracket(to: &buf)
  appendPositiveIntDecimal(row1, to: &buf)
  buf.append(0x3B)  // ;
  appendPositiveIntDecimal(col1, to: &buf)
  buf.append(0x48)  // H
}

/// `\u{001b}[48;2;…m\u{001b}[38;2;…m` truecolor pair (matches ``CSI/sgrTruecolor``).
private func appendTruecolorSGR(
  background bg: TerminalRGB, foreground fg: TerminalRGB, to buf: inout TerminalByteBuffer
) {
  appendEscBracket(to: &buf)
  buf.append(0x34)  // '4'
  buf.append(0x38)  // '8'
  buf.append(0x3B)
  buf.append(0x32)
  buf.append(0x3B)
  appendPositiveIntDecimal(Int(bg.r), to: &buf)
  buf.append(0x3B)
  appendPositiveIntDecimal(Int(bg.g), to: &buf)
  buf.append(0x3B)
  appendPositiveIntDecimal(Int(bg.b), to: &buf)
  buf.append(0x6D)

  appendEscBracket(to: &buf)
  buf.append(0x33)  // '3'
  buf.append(0x38)  // '8'
  buf.append(0x3B)
  buf.append(0x32)
  buf.append(0x3B)
  appendPositiveIntDecimal(Int(fg.r), to: &buf)
  buf.append(0x3B)
  appendPositiveIntDecimal(Int(fg.g), to: &buf)
  buf.append(0x3B)
  appendPositiveIntDecimal(Int(fg.b), to: &buf)
  buf.append(0x6D)
}

@inline(__always)
private func appendSGRBold(to buf: inout TerminalByteBuffer) {
  buf.append(0x1B)
  buf.append(0x5B)
  buf.append(0x31)
  buf.append(0x6D)
}

@inline(__always)
private func appendSGRNormalIntensity(to buf: inout TerminalByteBuffer) {
  buf.append(0x1B)
  buf.append(0x5B)
  buf.append(0x32)
  buf.append(0x32)
  buf.append(0x6D)
}

@inline(__always)
private func appendSGRReset(to buf: inout TerminalByteBuffer) {
  buf.append(0x1B)
  buf.append(0x5B)
  buf.append(0x30)
  buf.append(0x6D)
}

@inline(__always)
private func appendGlyphUTF8(_ ch: Character, to buf: inout TerminalByteBuffer) {
  if let ascii = ch.asciiValue {
    buf.append(ascii)
    return
  }
  for byte in ch.utf8 {
    buf.append(byte)
  }
}

private struct EmittedGraphicStyle: Equatable {
  var bold: Bool
  var foreground: TerminalRGB
  var background: TerminalRGB
}

/// Row-major `cols × rows` cell buffer: build scenes in memory, then ``encode(into:)`` once per frame.
/// Uses ``RigidArray`` like ``TerminalByteBuffer``, with capacity fixed to `cols × rows`.
public struct TerminalCellGrid: ~Copyable, Sendable {
  public private(set) var cols: Int
  public private(set) var rows: Int
  private var cells: RigidArray<TerminalCell>

  public init(cols: Int, rows: Int, filling fill: TerminalCell) {
    precondition(cols >= 1 && rows >= 1)
    self.cols = cols
    self.rows = rows
    self.cells = RigidArray(repeating: fill, count: cols &* rows)
  }

  @inline(__always)
  private func index(column x: Int, row y: Int) -> Int {
    y &* cols &+ x
  }

  public subscript(column x: Int, row y: Int) -> TerminalCell {
    get {
      precondition(x >= 0 && x < cols && y >= 0 && y < rows)
      return cells[index(column: x, row: y)]
    }
    set {
      precondition(x >= 0 && x < cols && y >= 0 && y < rows)
      cells[index(column: x, row: y)] = newValue
    }
  }

  /// Overwrite a rectangle (**zero-based** column, row; width × height) with copies of `cell`.
  public mutating func blit(
    column column0: Int,
    row row0: Int,
    width: Int,
    height: Int,
    repeating cell: TerminalCell
  ) {
    precondition(width >= 0 && height >= 0)
    let c1 = min(column0 &+ width, cols)
    let r1 = min(row0 &+ height, rows)
    var r = max(0, row0)
    while r < r1 {
      let rowBase = r &* cols
      var c = max(0, column0)
      while c < c1 {
        cells[rowBase &+ c] = cell
        c &+= 1
      }
      r &+= 1
    }
  }

  /// Overwrite a horizontal run starting at (**column0**, **row0**), one grid cell per `Character`.
  public mutating func blitText(
    column column0: Int,
    row row0: Int,
    string: String,
    foreground: TerminalRGB,
    background: TerminalRGB,
    flags: TerminalCellFlags = []
  ) {
    guard row0 >= 0, row0 < rows, column0 >= 0, column0 < cols else { return }
    var x = column0
    for ch in string {
      guard x < cols else { break }
      self[column: x, row: row0] = TerminalCell(
        glyph: ch, foreground: foreground, background: background, flags: flags)
      x &+= 1
    }
  }

  /// Emits CUP per row, truecolor SGR + UTF‑8 glyph per cell, trailing ``CSI/sgr0``.
  ///
  /// Skips redundant intensity / truecolor sequences when they match the previous cell (style persists in the terminal).
  internal func encode(into buf: inout TerminalByteBuffer) {
    buf.removeAll()
    var hasPrevious = false
    var previous = EmittedGraphicStyle(bold: false, foreground: .black, background: .black)
    var flatIdx = 0
    var y = 0
    while y < rows {
      appendCup(row: y &+ 1, column: 1, to: &buf)
      var x = 0
      while x < cols {
        let cell = cells[flatIdx]
        let bold = cell.flags.contains(.bold)
        let fg = cell.foreground
        let bg = cell.background

        if !hasPrevious || previous.bold != bold {
          if bold {
            appendSGRBold(to: &buf)
          } else {
            appendSGRNormalIntensity(to: &buf)
          }
        }

        if !hasPrevious || previous.foreground != fg || previous.background != bg {
          appendTruecolorSGR(background: bg, foreground: fg, to: &buf)
        }

        previous = EmittedGraphicStyle(bold: bold, foreground: fg, background: bg)
        hasPrevious = true
        appendGlyphUTF8(cell.glyph, to: &buf)
        flatIdx &+= 1
        x &+= 1
      }
      y &+= 1
    }
    appendSGRReset(to: &buf)
  }
}
