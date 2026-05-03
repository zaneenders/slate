/// Interactive terminal session backed by raw mode + alternate screen.
///
/// Single owning handle. Owns front/back screen buffers, output buffer, and TTY state.
///
/// ```swift
/// var term = try Terminal()
///
/// Task {
///     for await event in term.events() {
///         if event.code == .character("q") { /* quit */ }
///     }
/// }
///
/// while running {
///     term.refreshSize()
///     term.clear()
///     term.draw(Cell(char: "H", attrs: .default), at: 2, y: 2)
///     term.present()
///     try? await Task.sleep(for: .milliseconds(16))
/// }
/// ```
@safe
public struct Terminal: ~Copyable {
  public enum InstallationError: Error {
    case notInteractiveTerminal
  }

  public private(set) var cols: Int
  public private(set) var rows: Int

  private var front: ScreenBuffer
  private var back: ScreenBuffer
  private var output: OutputBuffer
  private var clearCell: Cell

  // MARK: - Lifecycle

  public init() throws {
    guard ttyEnterRawOrExit() else {
      throw InstallationError.notInteractiveTerminal
    }

    var installationComplete = false
    defer {
      if !installationComplete {
        ttyRestoreSaved()
      }
    }

    // Emit alternate screen enter + hide cursor + clear.
    var setup = OutputBuffer(capacity: 64)
    setup.emitBytes([0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x68])  // altOn
    setup.emitBytes([0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x6C])  // curHide
    setup.emitBytes([0x1B, 0x5B, 0x32, 0x4A])  // clear screen
    setup.emitCUP(row: 1, column: 1)  // home
    setup.writeToStdout()

    let size = WinSize.query()
    cols = size.cols
    rows = size.rows

    clearCell = .default
    front = ScreenBuffer(cols: cols, rows: rows, filling: clearCell)
    back = ScreenBuffer(cols: cols, rows: rows, filling: clearCell)
    output = OutputBuffer(capacity: Terminal.outputCapacity(cols: cols, rows: rows))

    installationComplete = true
  }

  deinit {
    // Best-effort restore when the user doesn't explicitly tear down.
    // If `ttyRestoreSaved()` was already called this is a no-op because the
    // global restore state has been consumed.
    var tail = OutputBuffer(capacity: 64)
    tail.emitBytes([0x1B, 0x5B, 0x30, 0x6D])  // sgr0
    tail.emitBytes([0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x68])  // curShow
    tail.emitBytes([0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x6C])  // altOff
    tail.writeToStdout()
    ttyRestoreSaved()
  }

  // MARK: - Dimensions

  /// Reread window size and resize buffers if needed.
  public mutating func refreshSize() {
    let size = WinSize.query()
    if size.cols != cols || size.rows != rows {
      cols = size.cols
      rows = size.rows
      front = ScreenBuffer(cols: cols, rows: rows, filling: clearCell)
      back = ScreenBuffer(cols: cols, rows: rows, filling: clearCell)
      output = OutputBuffer(capacity: Terminal.outputCapacity(cols: cols, rows: rows))
    }
  }

  // MARK: - Drawing

  /// Fill the entire back buffer with `cell`.
  public mutating func clear(to cell: Cell = .default) {
    clearCell = cell
    back.clear(to: cell)
  }

  /// Draw a single cell into the back buffer (clipped to bounds).
  public mutating func draw(_ cell: Cell, at column: Int, row: Int) {
    guard column >= 0 && column < cols && row >= 0 && row < rows else { return }
    back.setCell(column: column, row: row, to: cell)
  }

  /// Draw a horizontal string into the back buffer (clipped to bounds, one `Character` per cell).
  public mutating func drawText(
    _ string: String,
    at column: Int,
    row: Int,
    attrs: Attributes = .default
  ) {
    guard row >= 0 && row < rows && column < cols else { return }
    var x = column
    for ch in string {
      guard x >= 0 && x < cols else { break }
      if let scalar = ch.unicodeScalars.first {
        back.setCell(column: x, row: row, to: Cell(char: scalar, attrs: attrs))
      }
      x &+= 1
    }
  }

  // MARK: - Presentation

  /// Diff back against front, emit ANSI, copy changed cells to front, and flush with a single
  /// `write()` syscall.
  public mutating func present() {
    output.removeAll()
    output.emitSyncOn()

    var previousAttrs: Attributes?

    for row in 0..<rows {
      // Find first changed column
      var startX = cols
      for col in 0..<cols {
        if back.cell(column: col, row: row) != front.cell(column: col, row: row) {
          startX = col
          break
        }
      }
      if startX == cols { continue }  // row unchanged

      // Find last changed column
      var endX = startX
      for col in (startX..<cols).reversed() {
        if back.cell(column: col, row: row) != front.cell(column: col, row: row) {
          endX = col &+ 1
          break
        }
      }

      // One CUP per changed row
      output.emitCUP(row: row &+ 1, column: startX &+ 1)

      // Walk left-to-right, emitting SGR only when attributes change
      for col in startX..<endX {
        let cell = back.cell(column: col, row: row)
        output.emitSGR(cell.attrs, previous: previousAttrs)
        previousAttrs = cell.attrs
        output.emitScalar(cell.char)
      }

      // Copy changed span to front buffer
      for col in startX..<endX {
        let cell = back.cell(column: col, row: row)
        front.setCell(column: col, row: row, to: cell)
      }
    }

    output.emitSGRReset()
    output.emitSyncOff()
    output.writeToStdout()
  }

  // MARK: - Input

  /// Returns an ``AsyncStream`` of ``KeyEvent`` parsed from stdin.
  ///
  /// The stream owns a background task that polls stdin and yields events.
  /// It is safe to call from any isolation because it does not capture `self`.
  public func events() -> AsyncStream<KeyEvent> {
    let stream = EventStream()
    return stream.start()
  }

  // MARK: - Helpers

  private static func outputCapacity(cols: Int, rows: Int) -> Int {
    max(4096, rows &* cols &* 70 &+ rows &* 16 &+ 256)
  }
}

// MARK: - OutputBuffer convenience

extension OutputBuffer {
  fileprivate mutating func emitBytes(_ seq: [UInt8]) {
    for b in seq { append(b) }
  }
}
