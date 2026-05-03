import BasicContainers
import Testing

@testable import SlateCore

// MARK: - EscapeParser

struct EscapeParserTests {

  @Test
  func asciiCharacters() {
    var parser = EscapeParser()
    #expect(parser.feed(0x61).first?.code == .character("a"))
    #expect(parser.feed(0x41).first?.code == .character("A"))
    #expect(parser.feed(0x30).first?.code == .character("0"))
  }

  @Test
  func controlCharacters() {
    var parser = EscapeParser()
    let ctrlC = parser.feed(0x03).first
    #expect(ctrlC?.code == .character("c"))
    #expect(ctrlC?.modifiers == .control)

    let tab = parser.feed(0x09).first
    #expect(tab?.code == .tab)

    let enter = parser.feed(0x0D).first
    #expect(enter?.code == .enter)

    let backspace = parser.feed(0x7F).first
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

  @Test
  func bracketedPasteSimple() {
    var parser = EscapeParser()
    // \e[200~hello\e[201~
    let bytes = bytesFromString("\u{001b}[200~hello\u{001b}[201~")
    let events = parseSequence(&parser, bytes)
    #expect(events.count == 5)
    #expect(events[0].code == .character("h"))
    #expect(events[1].code == .character("e"))
    #expect(events[2].code == .character("l"))
    #expect(events[3].code == .character("l"))
    #expect(events[4].code == .character("o"))
  }

  @Test
  func bracketedPasteWithNewlines() {
    var parser = EscapeParser()
    // \e[200~line1\nline2\r\nline3\e[201~
    let bytes = bytesFromString("\u{001b}[200~line1\nline2\r\nline3\u{001b}[201~")
    let events = parseSequence(&parser, bytes)
    let chars = events.compactMap { ev -> Character? in
      if case .character(let ch) = ev.code { return ch }
      return nil
    }
    let text = String(chars)
    #expect(text == "line1\nline2\r\nline3")
  }

  @Test
  func bracketedPasteWithEscInside() {
    var parser = EscapeParser()
    // \e[200~a\eXb\e[201~  (ESC X in the middle is not the close sequence)
    let bytes = bytesFromString("\u{001b}[200~a\u{001b}Xb\u{001b}[201~")
    let events = parseSequence(&parser, bytes)
    let chars = events.compactMap { ev -> Character? in
      if case .character(let ch) = ev.code { return ch }
      return nil
    }
    let text = String(chars)
    #expect(text == "a\u{001b}Xb")
  }

  @Test
  func kittyModifiedEnter() {
    var parser = EscapeParser()
    // CSI 13 ; 2 u → Shift+Enter
    let shiftEnter = parseSequence(&parser, bytesFromString("\u{001b}[13;2u"))
    #expect(shiftEnter.count == 1)
    #expect(shiftEnter[0].code == .enter)
    #expect(shiftEnter[0].modifiers == .shift)
  }

  @Test
  func xtermModifyOtherKeysEnter() {
    var parser = EscapeParser()
    // CSI 27 ; 2 ; 13 ~ → Shift+Enter (xterm modifyOtherKeys)
    let shiftEnter = parseSequence(&parser, bytesFromString("\u{001b}[27;2;13~"))
    #expect(shiftEnter.count == 1)
    #expect(shiftEnter[0].code == .enter)
    #expect(shiftEnter[0].modifiers == .shift)
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
    events.append(contentsOf: parser.feed(b))
  }
  return events
}

private func bytesFromString(_ str: String) -> [UInt8] {
  Array(str.utf8)
}
