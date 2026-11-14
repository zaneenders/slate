import SlateUI
import Testing

@Test func hitRegionsFollowResolvedLayoutAndReturnLocalCoordinates() throws {
  let hits = HitMap<HitTarget>(capacity: 4)
  let size = TerminalSize(columns: 20, rows: 10)
  var surface = try Surface(maximumSize: size)
  try surface.render(size: size) {
    Overlay {
      Text("Save").padding(1).border().hitRegion(.first, in: hits)
        .position(column: 5, row: 2)
    }
  }
  #expect(hits.bounds(for: .first) == Rect(x: 5, y: 2, width: 8, height: 5))
  let hit = hits.hitTest(column: 7, row: 3)
  #expect(hit?.id == .first && hit?.column == 2 && hit?.row == 1)
  #expect(hit?.clippedBounds == hit?.bounds)
  #expect(hits.hitTest(column: 13, row: 2) == nil)
  #expect(hits.hitTest(column: 5, row: 7) == nil)
  #expect(hits.hitTest(column: -1, row: 0) == nil)
  #expect(hits.hitTest(column: 0, row: 65_534) == nil)
}

@Test func hitModifiersPreserveTextFillAndFixedSizing() throws {
  let hits = HitMap<HitTarget>(capacity: 4)
  let size = TerminalSize(columns: 20, rows: 8)
  var plain = try Surface(maximumSize: size)
  var tagged = try Surface(maximumSize: size)
  try plain.render(size: size) {
    Column {
      Text("header")
      Row {
        Text("fixed").frame(width: .fixed(7), height: .fill)
        Text("fill").frame(width: .fill, height: .fill)
      }.frame(width: .fill, height: .fill)
      Text("footer")
    }
  }
  try tagged.render(size: size) {
    Column {
      Text("header").hitRegion(.first, in: hits)
      Row {
        Text("fixed").frame(width: .fixed(7), height: .fill).hitRegion(.second, in: hits)
        Text("fill").frame(width: .fill, height: .fill).hitRegion(.third, in: hits)
      }.frame(width: .fill, height: .fill).hitRegion(.parent, in: hits)
      Text("footer")
    }
  }
  for y in 0..<size.rows {
    for x in 0..<size.columns { #expect(plain.cell(x: x, y: y) == tagged.cell(x: x, y: y)) }
  }
  #expect(hits.bounds(for: .first) == Rect(width: 6, height: 1))
  #expect(hits.bounds(for: .second) == Rect(y: 1, width: 7, height: 6))
  #expect(hits.bounds(for: .third) == Rect(x: 7, y: 1, width: 13, height: 6))
  #expect(hits.hitTest(column: 8, row: 2)?.id == .third)
}

@Test func hitModifierPlacementControlsPaddingAndPositionSlots() throws {
  let hits = HitMap<HitTarget>()
  let size = TerminalSize(columns: 12, rows: 6)
  var surface = try Surface(maximumSize: size)
  try surface.render(size: size) {
    Text("X").hitRegion(.first, in: hits).padding(1).border()
      .hitRegion(.parent, in: hits).position(column: 3, row: 1)
      .hitRegion(.second, in: hits)
  }
  #expect(hits.bounds(for: .second) == Rect(width: 12, height: 6))
  #expect(hits.bounds(for: .parent) == Rect(x: 3, y: 1, width: 5, height: 5))
  #expect(hits.bounds(for: .first) == Rect(x: 5, y: 3, width: 1, height: 1))
  #expect(hits.hitTest(column: 5, row: 3)?.id == .first)
  #expect(hits.hitTest(column: 3, row: 1)?.id == .parent)
  #expect(hits.hitTest(column: 0, row: 0)?.id == .second)
}

@Test func hitTestingUsesOverlayOrderBlockersAndNestedTargets() throws {
  let hits = HitMap<HitTarget>()
  let size = TerminalSize(columns: 10, rows: 5)
  var surface = try Surface(maximumSize: size)
  try surface.render(size: size) {
    Overlay {
      Text("back").frame(width: .fill, height: .fill).hitRegion(.first, in: hits)
      Text("front").frame(width: .fixed(6), height: .fixed(3))
        .hitRegion(.second, in: hits)
      Text("decoration")
    }
  }
  #expect(hits.hitTest(column: 1, row: 1)?.id == .second)
  #expect(hits.hitTest(column: 9, row: 4)?.id == .first)
  try surface.render(size: size) {
    Overlay {
      Text("back").frame(width: .fill, height: .fill).hitRegion(.first, in: hits)
      Text("child").hitRegion(.third, in: hits)
        .frame(width: .fixed(6), height: .fixed(3), alignment: .topLeading)
        .blocksMouse(in: hits)
    }
  }
  #expect(hits.hitTest(column: 1, row: 0)?.id == .third)
  #expect(hits.hitTest(column: 5, row: 2) == nil)
  #expect(hits.hitTest(column: 9, row: 4)?.id == .first)
}

@Test func hitSnapshotsReplaceHiddenAndEmptyTargetsAndSurviveFailedFrames() throws {
  let hits = HitMap<HitTarget>(capacity: 1)
  let other = HitMap<HitTarget>(capacity: 1)
  let size = TerminalSize(columns: 10, rows: 4)
  var surface = try Surface(maximumSize: size)
  try surface.render(size: size) { Text("keep").hitRegion(.first, in: hits) }
  #expect(throws: SurfaceError.layout(.hitRegionCapacityExceeded)) {
    try surface.render(size: size) {
      Text("new").hitRegion(.second, in: hits)
      Text("new").hitRegion(.third, in: other)
      Text("overflow").hitRegion(.parent, in: hits)
    }
  }
  #expect(hits.hitTest(column: 0, row: 0)?.id == .first)
  #expect(other.count == 0)
  #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "k")
  #expect(throws: SurfaceError.layout(.textTooLong)) {
    try surface.render(size: size) {
      Text("new").hitRegion(.second, in: hits)
      Text(String(repeating: "x", count: LayoutLimits.maximumTextScalars + 1))
    }
  }
  #expect(hits.hitTest(column: 0, row: 0)?.id == .first)
  try surface.render(size: size) { Text("other").hitRegion(.third, in: other) }
  #expect(hits.count == 0 && other.hitTest(column: 0, row: 0)?.id == .third)
  try surface.render(size: size) { EmptyHitBlock().hitRegion(.first, in: hits) }
  #expect(hits.bounds(for: .first) == nil && hits.hitTest(column: 0, row: 0) == nil)
  #expect(other.count == 0)
  try surface.render(size: size) { Text("clear") }
  #expect(hits.count == 0)
}

@Test func hitMapsHandleEmptyViewportsAndCustomPaintingWithoutGrowingStorage() throws {
  let hits = HitMap<HitTarget>(capacity: 1)
  let size = TerminalSize(columns: 8, rows: 4)
  var surface = try Surface(maximumSize: size)
  let budget = surface.storageBudgetBytes + hits.storageBudgetBytes
  for viewport in [size, .init(columns: 2, rows: 1), .init(columns: 0, rows: 0), size] {
    try surface.render(size: viewport) {
      Text("clipped").padding(1).hitRegion(.first, in: hits).position(column: 65_535, row: 65_535)
    }
    if viewport.columns == 0 {
      #expect(hits.bounds(for: .first) == nil)
    } else {
      #expect(hits.hitTest(column: viewport.columns - 1, row: viewport.rows - 1)?.id == .first)
    }
    #expect(surface.storageBudgetBytes + hits.storageBudgetBytes == budget)
  }
  try surface.render(size: size, render: { _ in })
  #expect(hits.count == 0)
}

@Test func hitMapsRejectSharingAndReleaseOwnershipWhenTheirSurfaceEnds() throws {
  let hits = HitMap<HitTarget>()
  let size = TerminalSize(columns: 4, rows: 1)
  var second = try Surface(maximumSize: size)
  do {
    var first = try Surface(maximumSize: size)
    try first.render(size: size) { Text("one").hitRegion(.first, in: hits) }
    #expect(throws: SurfaceError.layout(.hitMapInUse)) {
      try second.render(size: size) { Text("two").hitRegion(.second, in: hits) }
    }
    #expect(hits.hitTest(column: 0, row: 0)?.id == .first)
  }
  #expect(hits.count == 0)
  try second.render(size: size) { Text("two").hitRegion(.second, in: hits) }
  #expect(hits.hitTest(column: 0, row: 0)?.id == .second)
}

private enum HitTarget: Hashable { case first, second, third, parent }
private struct EmptyHitBlock: Block { var body: some Block {} }

@Test func hitMapIDLookupHandlesHashCollisionsAndReorderedTargets() throws {
  let hits = HitMap<CollidingHitID>(capacity: 32)
  let size = TerminalSize(columns: 32, rows: 1)
  var surface = try Surface(maximumSize: size)
  let forward = (0..<32).map { Text("x").hitRegion(CollidingHitID(value: $0), in: hits) }
  let backward = (0..<32).reversed().map { Text("x").hitRegion(CollidingHitID(value: $0), in: hits) }
  try surface.render(size: size) { Row { BlockList(forward[...]) } }
  for column in 0..<32 {
    #expect(hits.hitTest(column: column, row: 0)?.id.value == column)
    #expect(hits.bounds(for: CollidingHitID(value: column))?.x == column)
  }
  try surface.render(size: size) { Row { BlockList(backward[...]) } }
  for column in 0..<32 {
    #expect(hits.hitTest(column: column, row: 0)?.id.value == 31 - column)
    #expect(hits.bounds(for: CollidingHitID(value: column))?.x == 31 - column)
  }
  #expect(hits.bounds(for: CollidingHitID(value: 99)) == nil)
}

@Test func hitMapOwnershipRollsBackAfterNodeExhaustionAndCommitsAfterPainting() throws {
  let hits = HitMap<Int>()
  let size = TerminalSize(columns: 4, rows: 1)
  var limited = try Surface(maximumSize: size, layoutBudget: .init(nodeCapacity: 2))
  #expect(throws: SurfaceError.layout(.nodeCapacityExceeded)) {
    try limited.render(size: size) { Text("fail").hitRegion(1, in: hits) }
  }
  var surface = try Surface(maximumSize: size)
  try surface.render(size: size) { Text("old").hitRegion(1, in: hits) }
  try surface.render(
    size: size, content: { Text("new").hitRegion(2, in: hits) },
    paint: { _ in #expect(hits.hitTest(column: 0, row: 0)?.id == 1) })
  #expect(hits.hitTest(column: 0, row: 0)?.id == 2)
}

private struct CollidingHitID: Hashable {
  let value: Int
  func hash(into hasher: inout Hasher) { hasher.combine(0) }
}
