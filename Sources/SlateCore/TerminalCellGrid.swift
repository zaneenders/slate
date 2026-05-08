import BasicContainers

public typealias TerminalByteBuffer = RigidArray<UInt8>

// MARK: - Pre-computed CSI encoding tables

/// Pre-computed UTF-8 decimal byte sequences for values 0–255.
/// Replaces repeated division/modulo in `appendPositiveIntDecimal`.
private let decimalByteTable: [[UInt8]] = (0...255).map { Array(String($0).utf8) }

/// Pre-encoded CSI fragments as `[[UInt8]]` — bulk-copied instead of byte-by-byte.
private let escBracketBytes: [UInt8] = [0x1B, 0x5B]           // ESC[
private let sgrBoldBytes: [UInt8] = [0x1B, 0x5B, 0x31, 0x6D]  // ESC[1m
private let sgrNormalIntensityBytes: [UInt8] = [0x1B, 0x5B, 0x32, 0x32, 0x6D]  // ESC[22m
private let sgrResetBytes: [UInt8] = [0x1B, 0x5B, 0x30, 0x6D]  // ESC[0m
private let sgr48_2_Bytes: [UInt8] = [0x1B, 0x5B, 0x34, 0x38, 0x3B, 0x32, 0x3B]  // ESC[48;2;
private let sgr38_2_Bytes: [UInt8] = [0x1B, 0x5B, 0x33, 0x38, 0x3B, 0x32, 0x3B]  // ESC[38;2;
private let cupSuffixBytes: [UInt8] = [0x48]  // H
private let sgrSuffixBytes: [UInt8] = [0x6D]  // m

// MARK: - CSI emission into `TerminalByteBuffer` (bulk-copy)

/// Appends a decimal-encoded integer (0–255) using a pre-computed lookup table.
@inline(__always)
private func appendDecimalByte(_ value: UInt8, to buf: inout TerminalByteBuffer) {
  buf.append(copying: decimalByteTable[Int(value)])
}

/// Appends a decimal-encoded CUP row/column (1-based, positive Int).
/// Uses the lookup table for values 0–255; falls back to per-byte for larger values.
@inline(__always)
private func appendCupCoord(_ value: Int, to buf: inout TerminalByteBuffer) {
  precondition(value >= 1)
  if value <= 255 {
    buf.append(copying: decimalByteTable[value])
  } else {
    // Large terminal — rare, but handle gracefully with per-byte emission.
    var v = value
    var digits: [UInt8] = []
    while v > 0 {
      digits.append(UInt8(v % 10) &+ 0x30)
      v /= 10
    }
    for b in digits.reversed() { buf.append(b) }
  }
}

@inline(__always)
private func appendCup(row row1: Int, column col1: Int, to buf: inout TerminalByteBuffer) {
  precondition(row1 >= 1 && col1 >= 1)
  buf.append(copying: escBracketBytes)
  appendCupCoord(row1, to: &buf)
  buf.append(0x3B)  // ;
  appendCupCoord(col1, to: &buf)
  buf.append(copying: cupSuffixBytes)
}

/// Emits `ESC[48;2;R;G;Bm ESC[38;2;R;G;Bm` truecolor pair using bulk copies.
@inline(__always)
private func appendTruecolorSGR(
  background bg: TerminalRGB, foreground fg: TerminalRGB, to buf: inout TerminalByteBuffer
) {
  // Background: ESC[48;2;R;G;Bm
  buf.append(copying: sgr48_2_Bytes)
  appendDecimalByte(bg.r, to: &buf)
  buf.append(0x3B)
  appendDecimalByte(bg.g, to: &buf)
  buf.append(0x3B)
  appendDecimalByte(bg.b, to: &buf)
  buf.append(copying: sgrSuffixBytes)

  // Foreground: ESC[38;2;R;G;Bm
  buf.append(copying: sgr38_2_Bytes)
  appendDecimalByte(fg.r, to: &buf)
  buf.append(0x3B)
  appendDecimalByte(fg.g, to: &buf)
  buf.append(0x3B)
  appendDecimalByte(fg.b, to: &buf)
  buf.append(copying: sgrSuffixBytes)
}

@inline(__always)
private func appendSGRBold(to buf: inout TerminalByteBuffer) {
  buf.append(copying: sgrBoldBytes)
}

@inline(__always)
private func appendSGRNormalIntensity(to buf: inout TerminalByteBuffer) {
  buf.append(copying: sgrNormalIntensityBytes)
}

@inline(__always)
private func appendSGRReset(to buf: inout TerminalByteBuffer) {
  buf.append(copying: sgrResetBytes)
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

// MARK: - Inline bitset for dirty-row tracking

/// Compact bitset for up to 512 rows (8 × UInt64 = 64 bytes).
/// 8× smaller and faster than `RigidArray<Bool>`, no extra dependency.
private struct RowBitset: ~Copyable, Sendable {
  private var words: [UInt64]

  init(repeating value: Bool, count: Int) {
    precondition(count >= 0 && count <= 512)
    let wordCount = (count &+ 63) / 64
    words = Array(repeating: value ? ~0 : 0, count: wordCount)
  }

  @inline(__always)
  subscript(_ index: Int) -> Bool {
    get {
      let w = index / 64
      let b = UInt64(index % 64)
      return (words[w] &>> b) & 1 == 1
    }
    set {
      let w = index / 64
      let b = UInt64(index % 64)
      if newValue {
        words[w] |= (1 &<< b)
      } else {
        words[w] &= ~(1 &<< b)
      }
    }
  }

  /// Set all bits to `true`.
  @inline(__always)
  mutating func setAll() {
    for i in words.indices { words[i] = ~0 }
  }
}

// MARK: - TerminalCellGrid

/// Row-major `cols × rows` cell buffer: build scenes in memory, then ``encode(into:)`` once per frame.
///
/// Dirty-row tracking ensures that only rows modified since the last encode are emitted
/// to the terminal. Reuse the same grid across frames for maximum performance:
///
/// ```swift
/// var grid = TerminalCellGrid(cols: 80, rows: 24, filling: .defaultCell)
/// while running {
///     grid.reset(filling: .defaultCell)   // marks all rows dirty
///     // ... paint only the rows that changed this frame ...
///     grid.encode(into: &buffer)          // emits only dirty rows, then clears flags
/// }
/// ```
///
/// Uses ``RigidArray`` like ``TerminalByteBuffer``, with capacity fixed to `cols × rows`.
public struct TerminalCellGrid: ~Copyable, Sendable {
  public private(set) var cols: Int
  public private(set) var rows: Int
  private var cells: RigidArray<TerminalCell>

  /// Bit-per-row dirty tracking. Rows are marked dirty by mutating operations
  /// (`blit`, `blitSpans`, `blitText`, `reset`, subscript setter) and cleared
  /// by ``encode(into:)``.
  private var dirtyRows: RowBitset

  public init(cols: Int, rows: Int, filling fill: TerminalCell) {
    precondition(cols >= 1 && rows >= 1)
    self.cols = cols
    self.rows = rows
    self.cells = RigidArray(repeating: fill, count: cols &* rows)
    // All rows start dirty so the first encode emits a full frame.
    self.dirtyRows = RowBitset(repeating: true, count: rows)
  }

  /// Re-create the grid for a new size. All rows are marked dirty.
  public mutating func resize(cols newCols: Int, rows newRows: Int, filling fill: TerminalCell) {
    precondition(newCols >= 1 && newRows >= 1)
    self.cols = newCols
    self.rows = newRows
    self.cells = RigidArray(repeating: fill, count: newCols &* newRows)
    self.dirtyRows = RowBitset(repeating: true, count: newRows)
  }

  // MARK: - Dirty-row helpers

  @inline(__always)
  private mutating func markDirty(row y: Int) {
    precondition(y >= 0 && y < rows)
    dirtyRows[y] = true
  }

  /// Marks all rows in the half-open range `[y0, y1)` as dirty.
  @inline(__always)
  private mutating func markDirty(rowRange y0: Int, _ y1: Int) {
    let start = max(0, y0)
    let end = min(rows, y1)
    var r = start
    while r < end {
      dirtyRows[r] = true
      r &+= 1
    }
  }

  // MARK: - Indexing

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
      markDirty(row: y)
    }
  }

  // MARK: - Blit operations

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
    let r0 = max(0, row0)
    var r = r0
    while r < r1 {
      let rowBase = r &* cols
      var c = max(0, column0)
      while c < c1 {
        cells[rowBase &+ c] = cell
        c &+= 1
      }
      r &+= 1
    }
    if r1 > r0 { markDirty(rowRange: r0, r1) }
  }

  /// Overwrite a horizontal run at (`column0`, `row`) with a sequence of styled spans.
  /// `maxWidth` caps the total columns written; the run is clipped to grid bounds.
  public mutating func blitSpans(
    column column0: Int,
    row: Int,
    maxWidth: Int,
    _ spans: [TerminalStyledSpan]
  ) {
    guard row >= 0, row < rows, column0 >= 0, column0 < cols, maxWidth > 0 else { return }
    let endCol = min(column0 &+ maxWidth, cols)
    let rowBase = row &* cols
    var x = column0
    for span in spans {
      guard x < endCol else { break }
      let fg = span.foreground
      let bg = span.background
      let flags = span.flags
      for ch in span.text {
        guard x < endCol else { break }
        cells[rowBase &+ x] = TerminalCell(glyph: ch, foreground: fg, background: bg, flags: flags)
        x &+= 1
      }
    }
    markDirty(row: row)
  }

  /// Fills every cell in the grid with `fill` without reallocating — use to reset between frames.
  /// Marks all rows dirty.
  public mutating func reset(filling fill: TerminalCell) {
    blit(column: 0, row: 0, width: cols, height: rows, repeating: fill)
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
    // `self[column:row:]` setter already marks the row dirty per-character,
    // but we also ensure it once here for the empty-string / no-op case.
    markDirty(row: row0)
  }

  // MARK: - Encoding

  /// Emits CUP per dirty row, truecolor SGR + UTF‑8 glyph per cell, trailing ``CSI/sgr0``.
  ///
  /// Rows that have not been modified since the last call to `encode(into:)` are
  /// **skipped entirely** — no CUP is emitted, and the terminal retains its
  /// previous content for those rows. Dirty flags are cleared after each row
  /// is emitted.
  ///
  /// Call ``reset(filling:)`` before painting a frame to ensure all relevant rows
  /// are dirty, or mark rows dirty explicitly via the blit operations.
  ///
  /// Skips redundant intensity / truecolor sequences when they match the previous
  /// cell (style persists in the terminal).
  internal mutating func encode(into buf: inout TerminalByteBuffer) {
    buf.removeAll()
    var hasPrevious = false
    var previous = EmittedGraphicStyle(bold: false, foreground: .black, background: .black)
    var flatIdx = 0
    var y = 0
    while y < rows {
      if !dirtyRows[y] {
        // Clean row: skip entirely. Terminal still shows previous content.
        flatIdx &+= cols
        y &+= 1
        continue
      }

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

      dirtyRows[y] = false  // Clear dirty flag for this row
      y &+= 1
    }
    appendSGRReset(to: &buf)
  }
}
