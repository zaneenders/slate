import SlateUI
import Testing

@Test(arguments: DecorativeModifier.allCases, [false, true])
private func decorativeModifiersPreserveFillInStacks(modifier: DecorativeModifier, horizontal: Bool) throws {
  var surface = try Surface(maximumSize: TerminalSize(columns: 12, rows: 8))
  let drawing = ModifierDrawing()
  for size in [surface.maximumSize, TerminalSize(columns: 8, rows: 6)] {
    try surface.render(size: size) {
      if horizontal {
        Row {
          modifier.apply(Canvas(drawing).frame(width: .fill, height: .fill))
          Text("R")
        }
      } else {
        Column {
          modifier.apply(Canvas(drawing).frame(width: .fill, height: .fill))
          Text("R")
        }
      }
    }
    let width = size.columns - (horizontal ? 1 : 0) - 2 * modifier.inset
    let height = size.rows - (horizontal ? 0 : 1) - 2 * modifier.inset
    #expect(drawing.area == Rect(width: width, height: height))
    #expect(surface.cell(x: modifier.inset, y: modifier.inset)?.glyph.scalar == "x")
    #expect(surface.cell(x: modifier.inset + width - 1, y: modifier.inset + height - 1)?.glyph.scalar == "x")
    #expect(surface.cell(x: horizontal ? size.columns - 1 : 0, y: horizontal ? 0 : size.rows - 1)?.glyph.scalar == "R")
  }
  #expect(drawing.calls == 2)
}

@Test(arguments: DecorativeModifier.allCases)
private func decorativeModifiersPreserveIndependentFillAxesInOverlays(modifier: DecorativeModifier) throws {
  let size = TerminalSize(columns: 12, rows: 9)
  var surface = try Surface(maximumSize: size)
  let hits = HitMap<Int>()
  let drawing = ModifierDrawing()
  for horizontal in [false, true] {
    try surface.render(size: size) {
      Overlay(alignment: .center) {
        modifier.apply(
          Canvas(drawing).frame(
            width: horizontal ? .fill : .fixed(3), height: horizontal ? .fixed(2) : .fill)
        ).hitRegion(1, in: hits)
      }
    }
    let width = horizontal ? size.columns : 3 + 2 * modifier.inset
    let height = horizontal ? 2 + 2 * modifier.inset : size.rows
    #expect(drawing.area == Rect(width: width - 2 * modifier.inset, height: height - 2 * modifier.inset))
    #expect(
      hits.bounds(for: 1)
        == Rect(x: (size.columns - width) / 2, y: (size.rows - height) / 2, width: width, height: height))
  }
}

@Test(arguments: DecorativeModifier.allCases)
private func decorativeModifiersKeepFitAndFixedContentAtNaturalSize(modifier: DecorativeModifier) throws {
  let size = TerminalSize(columns: 12, rows: 9)
  var surface = try Surface(maximumSize: size)
  let hits = HitMap<Int>()
  try surface.render(size: size) {
    Overlay(alignment: .center) {
      modifier.apply(Text("X")).hitRegion(1, in: hits)
    }
  }
  let fit = 1 + 2 * modifier.inset
  #expect(hits.bounds(for: 1) == Rect(x: (size.columns - fit) / 2, y: (size.rows - fit) / 2, width: fit, height: fit))

  let drawing = ModifierDrawing()
  try surface.render(size: size) {
    Overlay(alignment: .center) {
      modifier.apply(Canvas(drawing).frame(width: .fixed(3), height: .fixed(2))).hitRegion(1, in: hits)
    }
  }
  let width = 3 + 2 * modifier.inset
  let height = 2 + 2 * modifier.inset
  #expect(drawing.area == Rect(width: 3, height: 2))
  #expect(
    hits.bounds(for: 1)
      == Rect(x: (size.columns - width) / 2, y: (size.rows - height) / 2, width: width, height: height))
}

@Test func decorativeModifiersPreserveFillFromGroupedChildren() throws {
  let size = TerminalSize(columns: 8, rows: 3)
  var surface = try Surface(maximumSize: size)
  let drawing = ModifierDrawing()
  try surface.render(size: size) {
    Row {
      ModifierSiblings(drawing: drawing).background(.blue)
      Text("R")
    }
  }
  #expect(drawing.area == Rect(width: 7, height: 3))
  #expect(surface.cell(x: 6, y: 2)?.glyph.scalar == "x")
  #expect(surface.cell(x: 7, y: 0)?.glyph.scalar == "R")
}

private enum DecorativeModifier: CaseIterable, Sendable {
  case background, zeroPadding, padding, border, nested

  var inset: Int {
    switch self {
    case .background, .zeroPadding: 0
    case .padding, .border: 1
    case .nested: 2
    }
  }

  @BlockBuilder func apply<Content: Block>(_ content: Content) -> some Block {
    switch self {
    case .background: content.background(.blue)
    case .zeroPadding: content.padding(0)
    case .padding: content.padding(1)
    case .border: content.border()
    case .nested: content.padding(1).border().background(.blue)
    }
  }
}

private struct ModifierSiblings: Block {
  let drawing: ModifierDrawing
  var body: some Block {
    Text("label")
    Canvas(drawing)
  }
}

private final class ModifierDrawing: CanvasDrawing {
  private(set) var area: Rect?
  private(set) var calls = 0
  func paint(in frame: inout Frame) {
    area = frame.area
    calls += 1
    frame.fill(frame.area, with: Cell(Glyph("x")!))
  }
}
