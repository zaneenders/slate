import BasicContainers
public import SlateComposition

public enum TextViewportError<SourceFailure: Error>: Error {
  case invalidCapacity
  case invalidViewport
  case invalidSource
  case invalidUTF8(byteOffset: Int)
  case readBudgetExceeded
  case source(SourceFailure)
}

extension TextViewportError: Equatable where SourceFailure: Equatable {}

/// Storage-neutral, unwrapped text layout. Preparation may read a source;
/// painting performs no source access or I/O. Failed preparation preserves the
/// previous viewport. Two fixed cell grids and a 4 KiB read buffer are reused.
///
/// Work is bounded by maximumReadBytes and the configured cell count, plus the
/// source's documented line-lookup/read costs. Long clipped line tails are never
/// read: the next row uses the source's line index. Tabs use fixed tab stops;
/// Unicode uses Swift grapheme boundaries and Glyph's bounded terminal-width
/// policy. Unsupported/oversized clusters use replacements, matching Frame.text.
/// Source I/O latency and first-use runtime metadata are outside this guarantee.
public struct TextViewport: ~Copyable, ~Sendable {
  public let maximumSize: TerminalSize
  public let maximumReadBytes: Int
  public let tabWidth: Int
  public private(set) var size = TerminalSize(columns: 0, rows: 0)
  public private(set) var firstLine = 0
  public private(set) var firstColumn = 0
  public private(set) var lastReadByteCount = 0
  private var cells: RigidArray<Cell>
  private var scratch: RigidArray<Cell>
  private var input = InlineArray<4_096, UInt8>(repeating: 0)

  public init(
    maximumSize: TerminalSize = TerminalSize(columns: 160, rows: 60),
    maximumReadBytes: Int = 1_048_576, tabWidth: Int = 4
  ) throws(TextViewportError<Never>) {
    guard maximumSize.columns > 0 && maximumSize.columns <= Surface.maximumColumns,
      maximumSize.rows > 0 && maximumSize.rows <= Surface.maximumRows,
      (1...16_777_216).contains(maximumReadBytes), (1...16).contains(tabWidth)
    else { throw .invalidCapacity }
    self.maximumSize = maximumSize
    self.maximumReadBytes = maximumReadBytes
    self.tabWidth = tabWidth
    cells = RigidArray(repeating: Cell(), count: maximumSize.columns * maximumSize.rows)
    scratch = RigidArray(repeating: Cell(), count: maximumSize.columns * maximumSize.rows)
  }

  public var storageBudgetBytes: Int {
    2 * maximumSize.columns * maximumSize.rows * MemoryLayout<Cell>.stride + MemoryLayout<Self>.stride
  }

  public borrowing func cell(x: Int, y: Int) -> Cell? {
    guard (0..<size.columns).contains(x), (0..<size.rows).contains(y) else { return nil }
    return cells[y * size.columns + x]
  }

  public mutating func prepare<Source: TextDocumentSource & ~Copyable>(
    from source: inout Source, firstLine: Int = 0, firstColumn: Int = 0,
    size: TerminalSize, style: Style = Style()
  ) throws(TextViewportError<Source.ReadError>) {
    guard source.byteCount >= 0, source.lineCount > 0 else { throw .invalidSource }
    guard size.columns <= maximumSize.columns, size.rows <= maximumSize.rows,
      (0..<source.lineCount).contains(firstLine), (0...1_048_576).contains(firstColumn)
    else { throw .invalidViewport }
    do throws(Source.ReadError) { try source.validateSnapshot() } catch { throw .source(error) }
    let documentBytes = source.byteCount
    let documentLines = source.lineCount
    guard documentBytes >= 0, documentLines > 0 else { throw .invalidSource }
    guard firstLine < documentLines else { throw .invalidViewport }
    for index in 0..<(size.columns * size.rows) { scratch[index] = Cell(style: style) }
    var readBytes = 0
    if size.columns > 0 {
      let rowCount = min(size.rows, documentLines - firstLine)
      for row in 0..<rowCount {
        let range: Range<Int>
        do throws(Source.ReadError) { range = try source.lineContentRange(at: firstLine + row) } catch {
          throw .source(error)
        }
        guard range.lowerBound >= 0, range.upperBound <= documentBytes else { throw .invalidSource }
        var offset = range.lowerBound
        var column = 0
        var decoder = IncrementalUTF8Decoder()
        var clusters = UnicodeGraphemeBuffer()
        var scalarStart = offset
        while offset < range.upperBound && column < firstColumn + size.columns {
          let remainingBudget = maximumReadBytes - readBytes
          guard remainingBudget > 0 else { throw .readBudgetExceeded }
          let remainingColumns = firstColumn + size.columns - column
          let requested = min(min(input.count, range.upperBound - offset), min(remainingBudget, remainingColumns * 4))
          let count: Int
          do throws(Source.ReadError) {
            var storage = input.mutableSpan
            count = try source.readUTF8(from: offset, into: storage._mutatingExtracting(first: requested))
          } catch { throw .source(error) }
          guard count > 0 && count <= requested else { throw .invalidSource }
          readBytes += count
          for index in 0..<count {
            if decoder.isComplete { scalarStart = offset + index }
            let scalar: Unicode.Scalar
            switch decoder.append(input[index]) {
            case .pending: continue
            case .invalid: throw .invalidUTF8(byteOffset: scalarStart)
            case .scalar(let decoded): scalar = decoded
            }
            if let cluster = clusters.append(scalar, at: scalarStart) {
              stage(cluster, row: row, column: &column, firstColumn: firstColumn, columns: size.columns, style: style)
            }
            if column >= firstColumn + size.columns { break }
          }
          offset += count
        }
        if offset == range.upperBound && column < firstColumn + size.columns && !decoder.isComplete {
          throw .invalidUTF8(byteOffset: scalarStart)
        }
        if column < firstColumn + size.columns, let cluster = clusters.take() {
          stage(cluster, row: row, column: &column, firstColumn: firstColumn, columns: size.columns, style: style)
        }
      }
    }
    do throws(Source.ReadError) { try source.validateSnapshot() } catch { throw .source(error) }
    guard source.byteCount == documentBytes, source.lineCount == documentLines else { throw .invalidSource }
    swap(&cells, &scratch)
    self.size = size
    self.firstLine = firstLine
    self.firstColumn = firstColumn
    lastReadByteCount = readBytes
  }

  private mutating func stage(
    _ cluster: UnicodeGrapheme, row: Int, column: inout Int, firstColumn: Int, columns: Int, style: Style
  ) {
    let tab = cluster.firstScalar == "\t"
    let width = tab ? tabWidth - column % tabWidth : cluster.glyph.columnWidth
    let start = max(column, firstColumn)
    let end = min(column + width, firstColumn + columns)
    if tab {
      for visible in start..<max(start, end) { scratch[row * columns + visible - firstColumn] = Cell(style: style) }
    } else if column >= firstColumn && column + width <= firstColumn + columns {
      let index = row * columns + column - firstColumn
      scratch[index] = Cell(cluster.glyph, style: style)
      if width == 2 { scratch[index + 1] = .continuation(style: style) }
    }
    column += width
  }

  /// Paints the prepared top-left viewport at this origin, clipped to the area
  /// and frame. The source is never called, so disk reads cannot occur here.
  public borrowing func paint(in area: Rect, frame: inout Frame) {
    let clipped = area.intersection(frame.area)
    let width = min(size.columns, max(0, clipped.right - area.x))
    let height = min(size.rows, max(0, clipped.bottom - area.y))
    guard width > 0 && height > 0 else { return }
    for row in 0..<height {
      for column in 0..<width {
        let cell = cells[row * size.columns + column]
        frame[area.x + column, area.y + row] =
          cell.glyph.columnWidth == 2 && column + 1 == width ? Cell(style: cell.style) : cell
      }
    }
  }
}
