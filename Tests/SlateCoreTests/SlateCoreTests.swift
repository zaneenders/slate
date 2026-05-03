import BasicContainers
import Testing

@testable import SlateCore

// MARK: - EscapeParser

struct EscapeParserTests {

  @Test
  func asciiCharacters() {
    var parser = EscapeParser()
    #expect(parser.feed(0x61)?.code == .character("a"))
    #expect(parser.feed(0x41)?.code == .character("A"))
    #expect(parser.feed(0x30)?.code == .character("0"))
  }

  @Test
  func controlCharacters() {
    var parser = EscapeParser()
    let ctrlC = parser.feed(0x03)
    #expect(ctrlC?.code == .character("c"))
    #expect(ctrlC?.modifiers == .control)

    let tab = parser.feed(0x09)
    #expect(tab?.code == .tab)

    let enter = parser.feed(0x0D)
    #expect(enter?.code == .enter)

    let backspace = parser.feed(0x7F)
    #expect(backspace?.code == .backspace)
  }

  @Test
  func arrowKeys() {
    var parser = EscapeParser()
    let events = parseSequence(&parser, [0x1B, 0x5B, 0x41])  // ESC [ A
    #expect(events.count == 1)
    #expect(events[0].code == .up)
  }

  @Test
  func functionKeys() {
    var parser = EscapeParser()
    let f1 = parseSequence(&parser, [0x1B, 0x4F, 0x50])  // ESC O P
    #expect(f1.count == 1)
    #expect(f1[0].code == .f(1))

    let f5 = parseSequence(&parser, bytesFromString("\u{001b}[15~"))
    #expect(f5.count == 1)
    #expect(f5[0].code == .f(5))
  }

  @Test
  func modifiedArrows() {
    var parser = EscapeParser()
    // ESC [ 1 ; 5 A  → Ctrl+Up
    let ctrlUp = parseSequence(&parser, bytesFromString("\u{001b}[1;5A"))
    #expect(ctrlUp.count == 1)
    #expect(ctrlUp[0].code == .up)
    #expect(ctrlUp[0].modifiers == .control)
  }

  @Test
  func utf8MultiByte() {
    var parser = EscapeParser()
    // "é" = U+00E9 = 0xC3 0xA9
    let events = parseSequence(&parser, [0xC3, 0xA9])
    #expect(events.count == 1)
    #expect(events[0].code == .character("é"))
  }

  @Test
  func altKey() {
    var parser = EscapeParser()
    // ESC x → Alt+x
    let altX = parseSequence(&parser, [0x1B, 0x78])
    #expect(altX.count == 1)
    #expect(altX[0].code == .character("x"))
    #expect(altX[0].modifiers == .alt)
  }
}

// MARK: - RigidArray

struct RigidArrayTests {

  @Test
  func initAndAppend() {
    var arr = RigidArray<UInt8>(capacity: 4)
    arr.append(1)
    arr.append(2)
    #expect(arr.count == 2)
    #expect(arr[0] == 1)
    #expect(arr[1] == 2)
  }

  @Test
  func repeatingInit() {
    let arr = RigidArray<Int>(repeating: 7, count: 3)
    #expect(arr.count == 3)
    #expect(arr[0] == 7)
    #expect(arr[1] == 7)
    #expect(arr[2] == 7)
  }

  @Test
  func removeAll() {
    var arr = RigidArray<Int>(repeating: 5, count: 3)
    arr.removeAll()
    #expect(arr.count == 0)
  }
}

// MARK: - ScreenBuffer

struct ScreenBufferTests {

  @Test
  func getSet() {
    let cell = Cell(char: "X", attrs: .default)
    var buf = ScreenBuffer(cols: 10, rows: 5, filling: cell)
    #expect(buf.cell(column: 0, row: 0).char == "X")

    buf.setCell(column: 3, row: 2, to: Cell(char: "#", attrs: Attributes(foreground: .red, background: .black)))
    #expect(buf.cell(column: 3, row: 2).char == "#")
    #expect(buf.cell(column: 3, row: 2).attrs.foreground == .red)
  }

  @Test
  func clear() {
    var buf = ScreenBuffer(cols: 5, rows: 5, filling: Cell(char: "A", attrs: .default))
    buf.setCell(column: 1, row: 1, to: Cell(char: "B", attrs: .default))
    buf.clear(to: Cell(char: "C", attrs: .default))
    #expect(buf.cell(column: 0, row: 0).char == "C")
    #expect(buf.cell(column: 1, row: 1).char == "C")
  }
}

// MARK: - Helpers

private func parseSequence(_ parser: inout EscapeParser, _ bytes: [UInt8]) -> [KeyEvent] {
  var events: [KeyEvent] = []
  for b in bytes {
    if let ev = parser.feed(b) {
      events.append(ev)
    }
  }
  return events
}

private func bytesFromString(_ str: String) -> [UInt8] {
  Array(str.utf8)
}
