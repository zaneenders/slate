package import BasicContainers

public enum SurfaceError: Error, Equatable, Sendable {
  case invalidCapacity
  case viewportCapacityExceeded
  case layout(LayoutError)
}

/// A cell surface independent of presentation, terminal modes, and byte encoding.
/// Owns one fixed grid and bounded layout storage, all allocated at startup.
/// Optimized successful rendering reuses that storage without allocation;
/// capacity/layout rejection preserves the last frame. Error propagation,
/// caller-created Strings/drawing work, and first-use runtime metadata are outside
/// that guarantee. Frame views must end before the next render.
public struct Surface: ~Copyable, ~Sendable {
  public static let maximumColumns = 512
  public static let maximumRows = 256
  public let maximumSize: TerminalSize
  public let nodeCapacity: Int
  public private(set) var size = TerminalSize(columns: 0, rows: 0)
  private var cells: RigidArray<Cell>
  private var layout: LayoutTree

  /// Includes the inline owner and element storage, excluding allocator metadata
  /// and caller-owned text retained only during rendering.
  public var storageBudgetBytes: Int {
    maximumSize.columns * maximumSize.rows * MemoryLayout<Cell>.stride
      + nodeCapacity * (MemoryLayout<LayoutNode>.stride + MemoryLayout<BlockDrawing?>.stride)
      + MemoryLayout<Self>.stride
  }

  public init(
    maximumSize: TerminalSize = TerminalSize(columns: 240, rows: 80),
    nodeCapacity: Int = LayoutLimits.maximumNodes
  ) throws(SurfaceError) {
    guard maximumSize.columns > 0 && maximumSize.columns <= Self.maximumColumns,
      maximumSize.rows > 0 && maximumSize.rows <= Self.maximumRows,
      nodeCapacity > 0 && nodeCapacity <= LayoutLimits.maximumNodes
    else { throw .invalidCapacity }
    self.maximumSize = maximumSize
    self.nodeCapacity = nodeCapacity
    cells = RigidArray(repeating: Cell(), count: maximumSize.columns * maximumSize.rows)
    layout = LayoutTree(capacity: nodeCapacity)
  }

  /// A scoped, row-major view for any synchronous presentation backend. A new
  /// surface is empty; the view cannot outlive or mutate its owner. Consume it
  /// synchronously before rendering again; do not retain it across an await.
  @_lifetime(borrow self)
  public borrowing func renderedCells() -> Span<Cell> {
    cells.span.extracting(first: size.columns * size.rows)
  }

  public borrowing func cell(x: Int, y: Int) -> Cell? {
    guard x >= 0 && x < size.columns && y >= 0 && y < size.rows else { return nil }
    return cells[y * size.columns + x]
  }

  public mutating func render<Content: Block>(
    size: TerminalSize, @BlockBuilder content: () -> Content
  ) throws(SurfaceError) {
    try render(size: size, content: content, paint: { _ in })
  }

  /// Composes blocks, then lends the same frame to synchronous custom drawing.
  /// The paint callback is not called when layout or viewport validation fails.
  public mutating func render<Content: Block>(
    size: TerminalSize, @BlockBuilder content: () -> Content, paint: (inout Frame) -> Void
  ) throws(SurfaceError) {
    try validate(size)
    defer { layout.reset() }
    do throws(LayoutError) {
      try layout.build(in: Rect(width: size.columns, height: size.rows), content: content)
    } catch { throw .layout(error) }
    clear(size)
    do {
      var storage = cells.mutableSpan
      var frame = Frame(cells: storage._mutatingExtracting(first: size.columns * size.rows), size: size)
      layout.paint(into: &frame)
      paint(&frame)
    }
    self.size = size
  }

  public mutating func render(
    size: TerminalSize, render: (inout Frame) -> Void
  ) throws(SurfaceError) {
    try validate(size)
    clear(size)
    do {
      var storage = cells.mutableSpan
      var frame = Frame(cells: storage._mutatingExtracting(first: size.columns * size.rows), size: size)
      render(&frame)
    }
    self.size = size
  }

  private borrowing func validate(_ size: TerminalSize) throws(SurfaceError) {
    guard size.columns <= maximumSize.columns && size.rows <= maximumSize.rows else {
      throw .viewportCapacityExceeded
    }
  }

  private mutating func clear(_ size: TerminalSize) {
    for index in 0..<(size.columns * size.rows) { cells[index] = Cell() }
  }

  /// Transfers the rendered grid to a presenter and takes its same-capacity
  /// spare grid. Discards this surface's frame without copying cell storage.
  /// Exclusive access prevents recycling while a rendered view is live.
  package mutating func recycleCells(exchangingWith spare: inout RigidArray<Cell>) {
    precondition(spare.count == cells.count)
    swap(&cells, &spare)
    size = TerminalSize(columns: 0, rows: 0)
  }
}
