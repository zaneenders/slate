import Slate
import SlateTestSupport
import Testing

@Test func publicBlockListsRenderSlicesAndLargeEmptyOrPopulatedLists() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let size = TerminalSize(columns: 8, rows: 3)
  var screen = try Screen(maximumSize: size)
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
