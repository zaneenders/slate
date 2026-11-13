public import SlateUI

/// A single rectangular layer sharing a terminal with other writers.
/// Uses the same surface rendering and ANSI cell presentation as Screen. This
/// owner preserves the cursor and repaints every visible cell because another
/// writer may invalidate the rectangle between draws, so no diff grid is retained.
/// Owns one fixed cell grid, growable layout storage, and a 4 KiB
/// writer. Each draw repaints at most the configured cell capacity; moving first clears the
/// previous rectangle. Clearing uses default-background spaces.
/// It never clears the terminal or another region.
/// For compound Unicode, coordinate an output.graphemeClustering() scope with
/// other writers. ScreenApplication already manages this terminal mode.
/// Select ASCII capabilities to preserve cell positions without that mode.
///
/// Layout uses local coordinates and the requested size; output clips to the
/// current viewport. Cells outside that viewport are abandoned on clear/resize.
/// Call clear explicitly before relinquishing the layer; destruction does no I/O.
/// Startup, layout capacity growth, first-use Swift runtime metadata, and
/// caller-created String storage are outside the steady-state allocation guarantee.
/// Blocking output latency depends on the caller's descriptor; no tasks or additional retries are added.
public struct ScreenRegion: ~Copyable, ~Sendable {
  public var maximumSize: TerminalSize { surface.maximumSize }
  public var nodeCapacity: Int { surface.nodeCapacity }
  public var capabilities: TerminalCapabilities { writer.capabilities }
  /// Includes a partially painted region after an output error, so clear or a
  /// subsequent draw can repair it. No more than one region is retained.
  public private(set) var paintedRegion: Rect?
  private var surface: Surface
  private var writer: ANSIWriter

  /// Owned element storage plus the inline owner, excluding allocator metadata
  /// and caller-owned Strings retained only during a draw.
  public var storageBudgetBytes: Int {
    surface.storageBudgetBytes + MemoryLayout<Self>.stride - MemoryLayout<Surface>.stride
  }

  public init(
    maximumSize: TerminalSize,
    capabilities: TerminalCapabilities = .init()
  ) throws(ScreenError) {
    do throws(SurfaceError) {
      surface = try Surface(maximumSize: maximumSize)
    } catch { throw ScreenError(error) }
    writer = ANSIWriter(capabilities: capabilities)
  }

  /// Rejects size/layout exhaustion before any output or change of ownership.
  /// A failed write retains the attempted rectangle for bounded retry/clearing.
  /// The caller serializes this with other writers and redraws on invalidation.
  @discardableResult
  public mutating func draw<Content: Block>(
    in region: Rect, clippedTo viewport: TerminalSize, to output: borrowing Output,
    @BlockBuilder content: () -> Content
  ) throws(ScreenError) -> FrameStatistics {
    let size = TerminalSize(columns: region.width, rows: region.height)
    do throws(SurfaceError) { try surface.render(size: size, content: content) } catch { throw ScreenError(error) }
    let clipped = region.intersection(Rect(width: viewport.columns, height: viewport.rows))
    var cleared = FrameStatistics(changedCells: 0, outputBytes: 0)
    if paintedRegion != clipped { cleared = try clear(clippedTo: viewport, to: output) }
    guard !clipped.isEmpty else { return cleared }

    // Clearing flushes before ownership moves: even a partial new paint leaves
    // only one rectangle to repair, rather than accumulating failed moves.
    paintedRegion = clipped
    writer.reset()
    do throws(IOError) {
      let cells = surface.renderedCells()
      try writer.literal("\u{1b}7\u{1b}[0m", to: output)
      _ = try writer.cells(cells, size: size, in: clipped, to: output)
      try writer.literal("\u{1b}[0m\u{1b}8", to: output)
      try writer.flush(to: output)
    } catch {
      restoreAfterFailure(to: output)
      throw .output(error)
    }
    return FrameStatistics(
      changedCells: cleared.changedCells + clipped.width * clipped.height,
      outputBytes: cleared.outputBytes + writer.outputBytes)
  }

  /// Clears only the retained rectangle's intersection with the current viewport.
  /// Failure retains ownership; repeated successful clears produce no output.
  @discardableResult
  public mutating func clear(clippedTo viewport: TerminalSize, to output: borrowing Output) throws(ScreenError)
    -> FrameStatistics
  {
    guard let previous = paintedRegion else { return FrameStatistics(changedCells: 0, outputBytes: 0) }
    let clipped = previous.intersection(Rect(width: viewport.columns, height: viewport.rows))
    writer.reset()
    if !clipped.isEmpty {
      do throws(IOError) {
        try writer.literal("\u{1b}7\u{1b}[0m", to: output)
        for row in clipped.y..<clipped.bottom {
          try writer.cursor(x: clipped.x, y: row, to: output)
          for _ in 0..<clipped.width { try writer.glyph(.space, to: output) }
        }
        try writer.literal("\u{1b}[0m\u{1b}8", to: output)
        try writer.flush(to: output)
      } catch {
        restoreAfterFailure(to: output)
        throw .output(error)
      }
    }
    paintedRegion = nil
    return FrameStatistics(changedCells: clipped.width * clipped.height, outputBytes: writer.outputBytes)
  }

  private mutating func restoreAfterFailure(to output: borrowing Output) {
    writer.reset()
    // One best-effort attempt, using the same bounded syscall retry policy.
    try? writeStatic("\u{1b}[0m\u{1b}8", to: output.descriptor)
  }
}
