import Slate
import SlateTestSupport
import Testing

@Test func publicBlockListsRenderSlicesAndLargeEmptyOrPopulatedLists() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let size = TerminalSize(columns: 8, rows: 3)
  var screen = try Screen(maximumSize: size, layoutBudget: .init(nodeCapacity: 4_098))
  let lines = [Text("skip"), Text("one"), Text("two")]
  try screen.draw(size: size, to: output) { Column { BlockList(lines[1...]) } }
  #expect(screen.cell(x: 0, y: 0)?.glyph.scalar == "o")
  #expect(screen.cell(x: 0, y: 1)?.glyph.scalar == "t")
  #expect(screen.cell(x: 0, y: 2)?.glyph == .space)
  let empty = Array(repeating: EmptyPublicBlock(), count: 4_096)
  try screen.draw(size: size, to: output) { BlockList(empty[...]) }
  #expect(screen.cell(x: 0, y: 0)?.glyph == .space)
  let repeated = Array(repeating: Text("ok"), count: 4_096)
  try screen.draw(size: size, to: output) { Row { BlockList(repeated[...]) } }
  #expect(screen.cell(x: 0, y: 0)?.glyph.scalar == "o")
  #expect(screen.cell(x: 7, y: 0)?.glyph.scalar == "k")
  try screen.draw(size: size, to: output) { BlockList(lines[0..<0]) }
  #expect(screen.cell(x: 0, y: 0)?.glyph == .space)
}

private struct EmptyPublicBlock: Block {
  var body: some Block { if false { Text("unused") } }
}

@Test func publicLayoutBudgetsPreserveScreensAndRegionsOnNodeOrVisitExhaustion() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let size = TerminalSize(columns: 1, rows: 1)
  let limits = LayoutBudget(nodeCapacity: 2, maximumBlockVisits: 4)
  var screen = try Screen(maximumSize: size, layoutBudget: limits)
  try screen.draw(size: size, to: output) { Text("k") }
  _ = try capture.take()
  #expect(screen.layoutBudget == limits && screen.nodeCapacity == 2)
  #expect(throws: ScreenError.layout(.nodeCapacityExceeded)) {
    try screen.draw(size: size, to: output) {
      Text("x")
      Text("y")
    }
  }
  let empty = Array(repeating: EmptyPublicBlock(), count: 4)
  #expect(throws: ScreenError.layout(.blockVisitLimitExceeded)) {
    try screen.draw(size: size, to: output) { BlockList(empty[...]) }
  }
  #expect(screen.cell(x: 0, y: 0)?.glyph.scalar == "k")
  #expect(try capture.take().isEmpty)

  var region = try ScreenRegion(maximumSize: size, layoutBudget: limits)
  let previous = Rect(x: 1, y: 1, width: 1, height: 1)
  let viewport = TerminalSize(columns: 8, rows: 4)
  try region.draw(in: previous, clippedTo: viewport, to: output) { Text("k") }
  _ = try capture.take()
  #expect(region.layoutBudget == limits && region.nodeCapacity == 2)
  #expect(throws: ScreenError.layout(.nodeCapacityExceeded)) {
    try region.draw(in: Rect(width: 1, height: 1), clippedTo: viewport, to: output) {
      Text("x")
      Text("y")
    }
  }
  #expect(region.paintedRegion == previous)
  #expect(try capture.take().isEmpty)
  #expect(throws: ScreenError.invalidCapacity) { _ = try Screen(layoutBudget: .init(nodeCapacity: 0)) }
  #expect(throws: ScreenError.invalidCapacity) {
    _ = try ScreenRegion(maximumSize: size, layoutBudget: .init(maximumBlockVisits: 0))
  }
}

@Test func publicBlocksComposeOpaqueModifiersAndConditionalOrEmptyContent() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let size = TerminalSize(columns: 10, rows: 5)
  var screen = try Screen(maximumSize: size)
  for expanded in [false, true, false] {
    try screen.draw(size: size, to: output) { PublicCard(expanded: expanded) }
    #expect(screen.cell(x: 0, y: 0)?.glyph.scalar == "┌")
    #expect(screen.cell(x: 2, y: 1)?.glyph.scalar == "o")
    #expect(screen.cell(x: 3, y: 1)?.glyph.scalar == (expanded ? "n" : "f"))
    #expect(screen.cell(x: 4, y: 1)?.glyph.scalar == (expanded ? " " : "f"))
    #expect(screen.cell(x: 2, y: 2)?.glyph.scalar == (expanded ? "e" : " "))
    #expect(screen.cell(x: 9, y: 4)?.style.background == .blue)
  }
  try screen.draw(size: size, to: output) { Column {} }
  #expect(screen.cell(x: 2, y: 1)?.glyph == .space)
  #expect(screen.cell(x: 2, y: 2)?.glyph == .space)
}

// Uses only the supported client contract: a body and opaque composition.
// This fixture is also typechecked independently without @testable imports.
private struct PublicCard: Block {
  let expanded: Bool

  var body: some Block {
    Column {
      Row {}
      if expanded {} else {}
      if expanded {
        Text("on")
      } else {
        Row {
          Text("o")
          Text("ff")
        }
      }
      if expanded { Text("extra") }
    }
    .padding(horizontal: 1)
    .border("T")
    .background(.blue)
    .frame(width: .fill, height: .fill, alignment: .topLeading)
  }
}
