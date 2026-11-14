import SlateUI
import Testing

@Test func spatialFocusFollowsGroupsAndAlignedEntriesAcrossTheScreen() throws {
  let focus = FocusState<Int>(capacity: 16, initial: 103)
  let size = TerminalSize(columns: 32, rows: 12)
  var surface = try Surface(maximumSize: size)
  try surface.render(size: size) { NavigationFixture(focus: focus) }
  let budget = focus.storageBudgetBytes + surface.storageBudgetBytes
  #expect(focus.move(.right) && focus.focusedID == 104)
  #expect(focus.move(.down) && focus.focusedID == 106)
  #expect(focus.move(.down) && focus.focusedID == 202)
  #expect(focus.move(.up) && focus.focusedID == 106)
  #expect(focus.move(.left) && focus.focusedID == 105)
  #expect(focus.move(.left) && focus.focusedID == 3)
  #expect(focus.focus(1))
  // A farther sibling wins over a nearby target in another group.
  #expect(focus.move(.down) && focus.focusedID == 2)
  #expect(focus.focus(4))
  #expect(focus.move(.right) && focus.focusedID == 201)
  #expect(!focus.move(.down))
  #expect(focus.storageBudgetBytes + surface.storageBudgetBytes == budget)
}

@Test func spatialFocusSearchesTheNearestAncestorBeforeLeavingANestedGroup() throws {
  let focus = FocusState<Int>(capacity: 10, initial: 1)
  var surface = try Surface(maximumSize: .init(columns: 32, rows: 8))
  try surface.render(size: surface.maximumSize) {
    Overlay {
      Overlay {
        Overlay {
          placedFocusTarget(1, at: .init(x: 0, y: 0, width: 2, height: 1), in: focus)
          placedFocusTarget(2, at: .init(x: 0, y: 4, width: 2, height: 1), in: focus)
        }.frame(width: .fixed(4), height: .fixed(5)).navigationGroup(in: focus)
        placedFocusTarget(3, at: .init(x: 8, y: 1, width: 2, height: 1), in: focus)
      }.frame(width: .fixed(20), height: .fixed(6)).navigationGroup(in: focus)
      placedFocusTarget(4, at: .init(x: 25, y: 0, width: 2, height: 1), in: focus)
    }
  }
  #expect(focus.move(.down) && focus.focusedID == 2)
  #expect(focus.move(.right) && focus.focusedID == 3)
  #expect(focus.move(.right) && focus.focusedID == 4)
}

@Test func spatialFocusPrefersAlignedTargetsAndUsesStableTiesWithoutWrapping() throws {
  let focus = FocusState<Int>(initial: 1)
  var surface = try Surface(maximumSize: .init(columns: 12, rows: 6))
  try surface.render(size: surface.maximumSize) {
    Overlay {
      placedFocusTarget(1, at: .init(x: 0, y: 1, width: 2, height: 1), in: focus)
      placedFocusTarget(2, at: .init(x: 6, y: 1, width: 2, height: 1), in: focus)
      placedFocusTarget(3, at: .init(x: 3, y: 4, width: 2, height: 1), in: focus)
      placedFocusTarget(4, at: .init(x: 6, y: 1, width: 2, height: 1), in: focus)
    }
  }
  #expect(focus.move(.right) && focus.focusedID == 2)
  #expect(!focus.move(.right))
  #expect(focus.focus(column: 6, row: 1) && focus.focusedID == 4)
  #expect(!focus.focus(column: 11, row: 5))
  #expect(focus.move(.left) && focus.focusedID == 1)
  #expect(!focus.move(.left))
}

@Test(arguments: [FocusDirection.left, .right, .up, .down])
func spatialFocusDoesNotTreatContainedTargetsAsSidewaysDestinations(_ direction: FocusDirection) throws {
  let focus = FocusState<Int>(capacity: 8, initial: 1)
  var surface = try Surface(maximumSize: .init(columns: 40, rows: 40))
  let horizontal = direction == .left || direction == .right
  let origin = horizontal ? Rect(width: 20, height: 1) : Rect(width: 1, height: 20)
  let contained: Rect
  let neighbor: Rect
  switch direction {
  case .left:
    contained = Rect(x: 2, y: 10, width: 4, height: 1)
    neighbor = Rect(x: 1, y: 10, width: 4, height: 1)
  case .right:
    contained = Rect(x: 14, y: 10, width: 4, height: 1)
    neighbor = Rect(x: 34, y: 10, width: 4, height: 1)
  case .up:
    contained = Rect(x: 10, y: 2, width: 1, height: 4)
    neighbor = Rect(x: 10, y: 1, width: 1, height: 4)
  case .down:
    contained = Rect(x: 10, y: 14, width: 1, height: 4)
    neighbor = Rect(x: 10, y: 34, width: 1, height: 4)
  }
  try surface.render(size: surface.maximumSize) {
    Overlay {
      Overlay {
        placedFocusTarget(1, at: origin, in: focus)
        placedFocusTarget(2, at: contained, in: focus)
      }.frame(width: .fixed(horizontal ? 20 : 11), height: .fixed(horizontal ? 11 : 20))
        .navigationGroup(in: focus).position(column: 10, row: 10)
      placedFocusTarget(3, at: neighbor, in: focus)
    }
  }
  #expect(focus.move(direction) && focus.focusedID == 3)
}

@Test func spatialFocusStillAllowsNeighborsThatPartiallyOverlapTheSource() throws {
  let focus = FocusState<Int>(initial: 1)
  var surface = try Surface(maximumSize: .init(columns: 30, rows: 20))
  try surface.render(size: surface.maximumSize) {
    Overlay {
      placedFocusTarget(1, at: .init(x: 10, y: 8, width: 10, height: 4), in: focus)
      placedFocusTarget(2, at: .init(x: 6, y: 8, width: 8, height: 4), in: focus)
      placedFocusTarget(3, at: .init(x: 16, y: 8, width: 8, height: 4), in: focus)
      placedFocusTarget(4, at: .init(x: 10, y: 6, width: 10, height: 4), in: focus)
      placedFocusTarget(5, at: .init(x: 10, y: 10, width: 10, height: 4), in: focus)
    }
  }
  #expect(focus.move(.left) && focus.focusedID == 2)
  #expect(focus.focus(1) && focus.move(.right) && focus.focusedID == 3)
  #expect(focus.focus(1) && focus.move(.up) && focus.focusedID == 4)
  #expect(focus.focus(1) && focus.move(.down) && focus.focusedID == 5)
}

@Test(arguments: [FocusDirection.left, .right, .up, .down])
func spatialFocusLeavesGroupsAccordingToTheirBounds(_ direction: FocusDirection) throws {
  let focus = FocusState<Int>(capacity: 8, initial: 1)
  var surface = try Surface(maximumSize: .init(columns: 40, rows: 40))
  let horizontal = direction == .left || direction == .right
  let source = horizontal ? Rect(x: 8, y: 0, width: 20, height: 8) : Rect(x: 0, y: 8, width: 8, height: 20)
  let beside = horizontal ? Rect(x: 8, y: 12, width: 22, height: 8) : Rect(x: 12, y: 8, width: 8, height: 22)
  let sourceChild: Rect
  let besideChild: Rect
  switch direction {
  case .left:
    sourceChild = Rect(x: 10, y: 2, width: 4, height: 1)
    besideChild = Rect(x: 0, y: 2, width: 4, height: 1)
  case .right:
    sourceChild = Rect(x: 2, y: 2, width: 4, height: 1)
    besideChild = Rect(x: 16, y: 2, width: 4, height: 1)
  case .up:
    sourceChild = Rect(x: 2, y: 10, width: 1, height: 4)
    besideChild = Rect(x: 2, y: 0, width: 1, height: 4)
  case .down:
    sourceChild = Rect(x: 2, y: 2, width: 1, height: 4)
    besideChild = Rect(x: 2, y: 16, width: 1, height: 4)
  }
  try surface.render(size: surface.maximumSize) {
    Overlay {
      Overlay { placedFocusTarget(1, at: sourceChild, in: focus) }
        .frame(width: .fixed(source.width), height: .fixed(source.height)).navigationGroup(in: focus)
        .position(column: source.x, row: source.y)
      Overlay { placedFocusTarget(2, at: besideChild, in: focus) }
        .frame(width: .fixed(beside.width), height: .fixed(beside.height)).navigationGroup(in: focus)
        .position(column: beside.x, row: beside.y)
    }
  }
  #expect(!focus.move(direction) && focus.focusedID == 1)
  // The actual neighboring direction can still enter the other group.
  #expect(focus.move(horizontal ? .down : .right) && focus.focusedID == 2)
}

@Test func spatialFocusSkipsDisabledAndClippedTargetsAndTracksReflow() throws {
  let focus = FocusState<Int>(initial: 1)
  var surface = try Surface(maximumSize: .init(columns: 20, rows: 4))
  try surface.render(size: surface.maximumSize) {
    Row(gap: 1) {
      Text("a").focusTarget(1, in: focus, enabled: false)
      Text("b").focusTarget(2, in: focus)
      Text("c").focusTarget(3, in: focus)
    }.navigationGroup(in: focus)
  }
  #expect(focus.focusedID == nil && focus.bounds(for: 1) == nil)
  #expect(focus.move(.right) && focus.focusedID == 2)
  #expect(focus.move(.right) && focus.focusedID == 3)
  try surface.render(size: surface.maximumSize) {
    Column {
      Text("a").focusTarget(1, in: focus)
      Text("b").focusTarget(2, in: focus)
      Text("c").focusTarget(3, in: focus)
    }.navigationGroup(in: focus)
  }
  #expect(!focus.move(.left))
  #expect(focus.move(.up) && focus.focusedID == 2)
  try surface.render(size: .init(columns: 1, rows: 1)) {
    Column {
      Text("a").focusTarget(1, in: focus)
      Text("b").focusTarget(2, in: focus)
    }
  }
  #expect(focus.focusedID == nil && focus.bounds(for: 2) == nil)
  #expect(!focus.focus(2))
  #expect(focus.move(.down) && focus.focusedID == 1)
  #expect(focus.clear() && !focus.clear())
  try surface.render(size: surface.maximumSize, render: { _ in })
  #expect(!focus.move(.right))
}

@Test func spatialFocusRollsBackFailedGroupsAndRetainsTheLastSuccessfulGeometry() throws {
  let focus = FocusState<Int>(capacity: 2, initial: 1)
  var surface = try Surface(maximumSize: .init(columns: 8, rows: 2))
  try surface.render(size: surface.maximumSize) { Text("old").focusTarget(1, in: focus) }
  let old = focus.bounds(for: 1)
  #expect(throws: SurfaceError.layout(.focusCapacityExceeded)) {
    try surface.render(size: surface.maximumSize) {
      Column {
        Text("new").focusTarget(2, in: focus)
        Text("overflow").focusTarget(3, in: focus)
      }.navigationGroup(in: focus)
    }
  }
  #expect(focus.focusedID == 1 && focus.bounds(for: 1) == old)
  #expect(focus.bounds(for: 2) == nil)
  try surface.render(size: surface.maximumSize) {
    Row {
      Text("a").focusTarget(2, in: focus)
      Text("b").focusTarget(3, in: focus)
    }
  }
  #expect(focus.focusedID == nil)
  #expect(focus.focus(2) && focus.move(.right) && focus.focusedID == 3)
}

@Test func spatialFocusRejectsSharingAndReleasesOwnershipAfterTheSurfaceEnds() throws {
  let focus = FocusState<Int>(initial: 1)
  var second = try Surface(maximumSize: .init(columns: 8, rows: 1))
  do {
    var first = try Surface(maximumSize: second.maximumSize)
    try first.render(size: first.maximumSize) { Text("one").focusTarget(1, in: focus) }
    #expect(throws: SurfaceError.layout(.focusStateInUse)) {
      try second.render(size: second.maximumSize) { Text("two").focusTarget(2, in: focus) }
    }
    #expect(focus.focusedID == 1 && focus.bounds(for: 2) == nil)
  }
  #expect(focus.focusedID == nil && focus.bounds(for: 1) == nil)
  try second.render(size: second.maximumSize) { Text("two").focusTarget(2, in: focus) }
  #expect(focus.move(.right) && focus.focusedID == 2)
}

private func placedFocusTarget(_ id: Int, at bounds: Rect, in focus: FocusState<Int>) -> some Block {
  Text("x").frame(width: .fixed(bounds.width), height: .fixed(bounds.height))
    .focusTarget(id, in: focus).position(column: bounds.x, row: bounds.y)
}

private struct NavigationFixture: Block {
  let focus: FocusState<Int>
  var body: some Block {
    Overlay {
      Overlay {
        placedFocusTarget(1, at: .init(x: 0, y: 0, width: 2, height: 1), in: focus)
        placedFocusTarget(2, at: .init(x: 0, y: 2, width: 2, height: 1), in: focus)
        placedFocusTarget(3, at: .init(x: 0, y: 4, width: 2, height: 1), in: focus)
        placedFocusTarget(4, at: .init(x: 0, y: 6, width: 2, height: 1), in: focus)
      }.frame(width: .fixed(8), height: .fixed(8)).navigationGroup(in: focus)
      Overlay {
        placedFocusTarget(101, at: .init(x: 0, y: 0, width: 6, height: 1), in: focus)
        placedFocusTarget(102, at: .init(x: 8, y: 0, width: 6, height: 1), in: focus)
        placedFocusTarget(103, at: .init(x: 0, y: 2, width: 6, height: 1), in: focus)
        placedFocusTarget(104, at: .init(x: 8, y: 2, width: 6, height: 1), in: focus)
        placedFocusTarget(105, at: .init(x: 0, y: 4, width: 6, height: 1), in: focus)
        placedFocusTarget(106, at: .init(x: 8, y: 4, width: 6, height: 1), in: focus)
      }.frame(width: .fixed(18), height: .fixed(6)).navigationGroup(in: focus).position(column: 12, row: 0)
      Overlay {
        placedFocusTarget(201, at: .init(x: 0, y: 0, width: 6, height: 1), in: focus)
        placedFocusTarget(202, at: .init(x: 8, y: 0, width: 6, height: 1), in: focus)
      }.frame(width: .fixed(18), height: .fixed(1)).navigationGroup(in: focus).position(column: 12, row: 8)
    }
  }
}
