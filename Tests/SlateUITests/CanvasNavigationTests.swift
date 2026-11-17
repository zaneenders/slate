import SlateUI
import Testing

@Test func canvasRegionsUseClippedLocalCoordinatesAndInheritBlockGroups() throws {
  let focus = FocusState<Int>(capacity: 8, initial: 1)
  let drawing = RegionDrawing(focus: focus)
  var surface = try Surface(maximumSize: .init(columns: 40, rows: 12), layoutBudget: .init())
  try surface.render(size: surface.maximumSize) {
    Overlay {
      Canvas(drawing).frame(width: .fixed(16), height: .fixed(8))
        .navigationGroup(in: focus).position(column: 4, row: 2)
      Text("sibling").focusTarget(4, in: focus, enabled: true).position(column: 30, row: 2)
    }
  }
  #expect(focus.bounds(for: 1) == Rect(x: 6, y: 3, width: 4, height: 2))
  #expect(focus.bounds(for: 2) == Rect(x: 12, y: 3, width: 8, height: 2))
  #expect(focus.bounds(for: 3) == Rect(x: 6, y: 7, width: 4, height: 2))
  #expect(focus.bounds(for: 5) == nil)
  #expect(focus.move(.right) && focus.focusedID == 2)
  #expect(focus.move(.right) && focus.focusedID == 4)
  #expect(drawing.paints == 1)
}

@Test func canvasFocusRespectsOverlayPaintOrderAcrossBlockAndCustomTargets() throws {
  let focus = FocusState<Int>(capacity: 8, initial: 1)
  let drawing = RegionDrawing(focus: focus)
  var surface = try Surface(maximumSize: .init(columns: 20, rows: 10), layoutBudget: .init())
  try surface.render(size: surface.maximumSize) {
    Overlay {
      Canvas(drawing)
      Text("front").frame(width: .fixed(5), height: .fixed(2))
        .focusTarget(6, in: focus, enabled: true).position(column: 2, row: 1)
    }
  }
  #expect(focus.focus(column: 2, row: 1) && focus.focusedID == 6)
  try surface.render(size: surface.maximumSize) {
    Overlay {
      Text("back").frame(width: .fixed(5), height: .fixed(2))
        .focusTarget(6, in: focus, enabled: true).position(column: 2, row: 1)
      Canvas(drawing)
    }
  }
  #expect(focus.focus(column: 2, row: 1) && focus.focusedID == 1)
}

@Test func canvasRegionExhaustionRejectsBeforePaintingAndRetainsCommittedMaps() throws {
  let focus = FocusState<Int>(capacity: 1, initial: 9)
  let drawing = RegionDrawing(focus: focus)
  var surface = try Surface(maximumSize: .init(columns: 20, rows: 10), layoutBudget: .init())
  try surface.render(size: surface.maximumSize) {
    Text("old").focusTarget(9, in: focus, enabled: true)
  }
  let previous = focus.bounds(for: 9)
  #expect(throws: SurfaceError.layout(.focusCapacityExceeded)) {
    try surface.render(size: surface.maximumSize) { Canvas(drawing) }
  }
  #expect(drawing.paints == 0 && focus.focusedID == 9 && focus.bounds(for: 9) == previous)
  #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "o")
  try surface.render(size: surface.maximumSize) {
    Text("new").focusTarget(9, in: focus, enabled: true)
  }
  #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "n")
}

@Test func canvasRejectsTooManyMapOwnersAndCrossSurfaceReuseBeforePainting() throws {
  let drawing = ManyMapsDrawing()
  var small = try Surface(
    maximumSize: .init(columns: 20, rows: 10), layoutBudget: .init(nodeCapacity: 2, maximumBlockVisits: 4))
  #expect(throws: SurfaceError.layout(.hitMapCapacityExceeded)) {
    try small.render(size: small.maximumSize) { Canvas(drawing) }
  }
  #expect(drawing.paints == 0)
  var first = try Surface(maximumSize: .init(columns: 20, rows: 10), layoutBudget: .init())
  try first.render(size: first.maximumSize) { Canvas(drawing) }
  #expect(drawing.paints == 1)
  var second = try Surface(maximumSize: .init(columns: 20, rows: 10), layoutBudget: .init())
  #expect(throws: SurfaceError.layout(.focusStateInUse)) {
    try second.render(size: second.maximumSize) { Canvas(drawing) }
  }
  #expect(drawing.paints == 1)
}

@Test func canvasGroupDepthExhaustionIsBoundedAndRestoresTheGroupStack() throws {
  let focus = FocusState<Int>(capacity: 64, initial: 1)
  let drawing = DeepGroupsDrawing(focus: focus)
  var surface = try Surface(maximumSize: .init(columns: 20, rows: 10), layoutBudget: .init())
  try surface.render(size: surface.maximumSize) {
    Text("old").focusTarget(1, in: focus, enabled: true)
  }
  #expect(throws: SurfaceError.layout(.depthExceeded)) {
    try surface.render(size: surface.maximumSize) { Canvas(drawing) }
  }
  #expect(focus.focusedID == 1 && surface.cell(x: 0, y: 0)?.glyph.scalar == "o")
  drawing.depth = 2
  try surface.render(size: surface.maximumSize) { Canvas(drawing) }
  #expect(focus.contains(1))
}

private final class DeepGroupsDrawing: CanvasDrawing {
  let focus: FocusState<Int>
  var depth = LayoutLimits.maximumDepth + 1

  init(focus: FocusState<Int>) { self.focus = focus }

  func layout(in regions: inout CanvasLayout) throws(LayoutError) { try group(depth, in: &regions) }

  private func group(_ remaining: Int, in regions: inout CanvasLayout) throws(LayoutError) {
    if remaining == 0 {
      try regions.focusTarget(
        1, in: focus, bounds: regions.area, enabled: true, visibility: .visible, neighbors: .automatic)
    } else {
      try regions.navigationGroup(in: focus, bounds: regions.area) { local throws(LayoutError) in
        try group(remaining - 1, in: &local)
      }
    }
  }

  func paint(in frame: inout Frame) {}
}

private final class RegionDrawing: CanvasDrawing {
  let focus: FocusState<Int>
  var paints = 0

  init(focus: FocusState<Int>) { self.focus = focus }

  func layout(in regions: inout CanvasLayout) throws(LayoutError) {
    try regions.navigationGroup(in: focus, bounds: regions.area) { regions throws(LayoutError) in
      try regions.withRegion(Rect(x: 2, y: 1, width: 14, height: 7)) { local throws(LayoutError) in
        try local.focusTarget(
          1, in: focus, bounds: Rect(x: 0, y: 0, width: 4, height: 2), enabled: true,
          visibility: .visible, neighbors: .automatic)
        try local.focusTarget(
          2, in: focus, bounds: Rect(x: 6, y: 0, width: 12, height: 2), enabled: true,
          visibility: .visible, neighbors: .automatic)
        try local.focusTarget(
          3, in: focus, bounds: Rect(x: 0, y: 4, width: 4, height: 2), enabled: true,
          visibility: .visible, neighbors: .automatic)
        try local.focusTarget(
          5, in: focus, bounds: Rect(x: 65_530, y: 0, width: 5, height: 1), enabled: true,
          visibility: .visible, neighbors: .automatic)
      }
    }
  }

  func paint(in frame: inout Frame) {
    paints += 1
    frame.text("canvas", in: frame.area, style: Style())
  }
}

private final class ManyMapsDrawing: CanvasDrawing {
  let maps = [
    FocusState<Int>(capacity: 1, initial: 0), FocusState<Int>(capacity: 1, initial: 1),
    FocusState<Int>(capacity: 1, initial: 2)
  ]
  var paints = 0

  func layout(in regions: inout CanvasLayout) throws(LayoutError) {
    for index in maps.indices {
      try regions.focusTarget(
        index, in: maps[index], bounds: regions.area, enabled: true, visibility: .visible, neighbors: .automatic)
    }
  }

  func paint(in frame: inout Frame) { paints += 1 }
}
