import BasicContainers

/// Row-major grid of `Cell` backed by raw memory.
///
/// `~Copyable` so you cannot duplicate a multi-kilobyte screen buffer by accident.
@safe
public struct ScreenBuffer: ~Copyable {
  private var cells: RigidArray<Cell>

  public let cols: Int
  public let rows: Int

  public init(cols: Int, rows: Int, filling cell: Cell) {
    precondition(cols >= 1 && rows >= 1)
    self.cols = cols
    self.rows = rows
    self.cells = RigidArray(repeating: cell, count: cols &* rows)
  }

  @inline(__always)
  private func offset(column: Int, row: Int) -> Int {
    row &* cols &+ column
  }

  public func cell(column: Int, row: Int) -> Cell {
    precondition(column >= 0 && column < cols && row >= 0 && row < rows)
    return cells[offset(column: column, row: row)]
  }

  public mutating func setCell(column: Int, row: Int, to value: Cell) {
    precondition(column >= 0 && column < cols && row >= 0 && row < rows)
    cells[offset(column: column, row: row)] = value
  }

  public mutating func clear(to cell: Cell) {
    let count = cols &* rows
    for i in 0..<count {
      cells[i] = cell
    }
  }
}
