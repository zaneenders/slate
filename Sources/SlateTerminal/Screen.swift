import BasicContainers
@_exported public import SlateUI

public enum ScreenError: Error, Equatable, Sendable {
  case invalidCapacity
  case viewportCapacityExceeded
  case layout(LayoutError)
  case output(IOError)

  init(_ error: SurfaceError) {
    switch error {
    case .invalidCapacity: self = .invalidCapacity
    case .viewportCapacityExceeded: self = .viewportCapacityExceeded
    case .layout(let error): self = .layout(error)
    }
  }
}

public struct FrameStatistics: Equatable, Sendable {
  public let changedCells: Int
  public let outputBytes: Int
}

/// Presents a UI surface with ANSI diffing. Owns two fixed-capacity cell grids,
/// bounded layout storage, and a 4 KiB writer. Rendering and output are synchronous.
/// Shares cell presentation with ScreenRegion; this owner clears the terminal
/// on invalidation and retains the last successful grid for diffing.
/// Compound Unicode requires grapheme-aware terminal widths. ScreenApplication
/// manages mode 2027; manual presenters can borrow output.graphemeClustering().
/// Select ASCII capabilities for output independent of terminal Unicode widths.
public struct Screen: ~Copyable, ~Sendable {
  public static let maximumColumns = Surface.maximumColumns
  public static let maximumRows = Surface.maximumRows
  public var maximumSize: TerminalSize { surface.maximumSize }
  public var nodeCapacity: Int { surface.nodeCapacity }
  public var capabilities: TerminalCapabilities { writer.capabilities }
  private var surface: Surface
  private var previous: RigidArray<Cell>
  private var writer: ANSIWriter
  private var previousSize = TerminalSize(columns: 0, rows: 0)
  private var valid = false

  public var storageBudgetBytes: Int {
    surface.storageBudgetBytes + previous.count * MemoryLayout<Cell>.stride
      + MemoryLayout<Self>.stride - MemoryLayout<Surface>.stride
  }

  public init(
    maximumSize: TerminalSize = TerminalSize(columns: 240, rows: 80),
    nodeCapacity: Int = LayoutLimits.maximumNodes,
    capabilities: TerminalCapabilities = .init()
  ) throws(ScreenError) {
    do throws(SurfaceError) {
      surface = try Surface(maximumSize: maximumSize, nodeCapacity: nodeCapacity)
    } catch { throw ScreenError(error) }
    previous = RigidArray(repeating: Cell(), count: maximumSize.columns * maximumSize.rows)
    writer = ANSIWriter(capabilities: capabilities)
  }

  /// Call after another writer changes the display, or when switching outputs.
  public mutating func invalidate() { valid = false }

  /// Returns an independent cell value from the last successfully presented frame.
  public borrowing func cell(x: Int, y: Int) -> Cell? {
    guard valid && x >= 0 && x < previousSize.columns && y >= 0 && y < previousSize.rows else { return nil }
    return previous[y * previousSize.columns + x]
  }

  @discardableResult
  public mutating func draw<Content: Block>(
    size: TerminalSize, to output: borrowing Output,
    @BlockBuilder content: () -> Content
  ) throws(ScreenError) -> FrameStatistics {
    do throws(SurfaceError) { try surface.render(size: size, content: content) } catch { throw ScreenError(error) }
    return try present(size, to: output)
  }

  /// Uses the managed layout and presenter with a synchronous custom paint pass.
  @discardableResult
  public mutating func draw<Content: Block>(
    size: TerminalSize, to output: borrowing Output,
    @BlockBuilder content: () -> Content, paint: (inout Frame) -> Void
  ) throws(ScreenError) -> FrameStatistics {
    do throws(SurfaceError) {
      try surface.render(size: size, content: content, paint: paint)
    } catch { throw ScreenError(error) }
    return try present(size, to: output)
  }

  @discardableResult
  public mutating func draw(
    size: TerminalSize, to output: borrowing Output,
    render: (inout Frame) -> Void
  ) throws(ScreenError) -> FrameStatistics {
    do throws(SurfaceError) { try surface.render(size: size, render: render) } catch { throw ScreenError(error) }
    return try present(size, to: output)
  }

  private mutating func present(_ size: TerminalSize, to output: borrowing Output) throws(ScreenError)
    -> FrameStatistics
  {
    let redraw = !valid || size != previousSize
    // Invalidate before I/O: any partial frame must be fully repainted next time.
    valid = false
    writer.reset()
    var changed = 0
    do throws(IOError) {
      let current = surface.renderedCells()
      if redraw { try writer.literal("\u{1b}[0m\u{1b}[2J", to: output) }
      let comparison = previous.span.extracting(first: redraw ? 0 : current.count)
      changed = try writer.cells(
        current, size: size, in: Rect(width: size.columns, height: size.rows),
        previous: comparison, to: output)
      if changed > 0 { try writer.literal("\u{1b}[0m", to: output) }
      try writer.flush(to: output)
    } catch {
      writer.reset()
      throw .output(error)
    }
    surface.recycleCells(exchangingWith: &previous)
    previousSize = size
    valid = true
    return FrameStatistics(changedCells: changed, outputBytes: writer.outputBytes)
  }
}
