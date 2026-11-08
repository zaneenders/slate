import Slate

/// Shared paint/hit-test geometry. Work and storage are constant. Products fit
/// 64-bit Int: file bytes are bounded to 1 TiB, terminal dimensions to 65,535.
struct DocumentScrollbar {
  let column: Int
  let firstRow: Int
  let rowCount: Int
  let thumbFirstRow: Int
  let thumbRows: Int
  let maximumFirstByte: Int
  var travelRows: Int { rowCount - thumbRows }
  var canDrag: Bool { maximumFirstByte > 0 && travelRows > 0 }

  init?(layout: DocumentViewerLayout, byteCount: Int, visibleBytes: Int, firstByte: Int) {
    precondition((0...1_099_511_627_776).contains(byteCount) && visibleBytes >= 0)
    guard let column = layout.scrollbarColumn, layout.text.height > 0, layout.text.width > 0 else { return nil }
    self.column = column
    firstRow = layout.text.y
    rowCount = layout.text.height
    let visible = min(byteCount, visibleBytes)
    thumbRows = byteCount == 0 ? rowCount : max(1, rowCount * visible / byteCount)
    maximumFirstByte = max(0, byteCount - visible)
    let clampedByte = min(maximumFirstByte, max(0, firstByte))
    thumbFirstRow = firstRow + clampedByte * (rowCount - thumbRows) / max(1, maximumFirstByte)
  }

  func contains(column: Int, row: Int) -> Bool {
    column == self.column && (firstRow..<firstRow + rowCount).contains(row)
  }

  func thumbContains(row: Int) -> Bool { (thumbFirstRow..<thumbFirstRow + thumbRows).contains(row) }

  func byteOffset(pointerRow: Int, grabOffsetRows: Int) -> Int {
    guard canDrag else { return 0 }
    let top = min(travelRows, max(0, pointerRow - firstRow - grabOffsetRows))
    // Round up so painting's floor division places the thumb at this row.
    return (top * maximumFirstByte + travelRows - 1) / travelRows
  }
}
