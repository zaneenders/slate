import SlateUI
import Testing

@Test func textInputEditsWholeSwiftGraphemesAndPreservesUnicode() throws {
  var copyBuffer = CopyBuffer()
  for grapheme in ["e\u{301}", "🇺🇸", "👨‍👩‍👧‍👦", "क्‍ष", "x" + String(repeating: "\u{301}", count: 64)] {
    let input = try TextInput("A" + grapheme + "Z")
    #expect(input.handle(.left, copyBuffer: &copyBuffer) == .changed)
    #expect(input.handle(.backspace, copyBuffer: &copyBuffer) == .changed)
    #expect(input.snapshot() == "AZ")
    #expect(input.cursorByteOffset == 1)
    try input.insert(grapheme.utf8Span)
    #expect(input.snapshot() == "A" + grapheme + "Z")
    #expect(input.handle(.left, copyBuffer: &copyBuffer) == .changed)
    #expect(input.handle(.delete, copyBuffer: &copyBuffer) == .changed)
    #expect(input.snapshot() == "AZ")
  }
  let input = try TextInput("e")
  try input.insert("\u{301}".utf8Span)
  #expect(input.handle(.backspace, copyBuffer: &copyBuffer) == .changed)
  #expect(input.snapshot().isEmpty)
}

@Test func textInputSelectionCopyCutAndCapacityRejectionAreAtomic() throws {
  let input = try TextInput("café", capacity: 5)
  var copyBuffer = CopyBuffer()
  #expect(input.handle(.home, copyBuffer: &copyBuffer) == .changed)
  #expect(input.handle(.right, modifiers: .shift, copyBuffer: &copyBuffer) == .changed)
  #expect(input.selection == 0..<1)
  #expect(throws: TextInputError.capacityExceeded) { try input.insert("xx".utf8Span) }
  #expect(input.snapshot() == "café" && input.selection == 0..<1)
  #expect(throws: TextInputError.invalidControl) { try input.insert("\u{1b}".utf8Span) }
  #expect(input.snapshot() == "café" && input.selection == 0..<1)
  #expect(input.handle(.control(.a), copyBuffer: &copyBuffer) == .changed)
  #expect(input.handle(.control(.c), copyBuffer: &copyBuffer) == .changed)
  var copied: String?
  copyBuffer.flush { copied = String(copying: $0) }
  #expect(copied == "café")
  #expect(input.handle(.control(.x), copyBuffer: &copyBuffer) == .changed)
  #expect(input.snapshot().isEmpty)
  try input.insert("q\r\n\t".utf8Span)
  #expect(input.snapshot() == "q   ")
  #expect(input.handle(.enter, copyBuffer: &copyBuffer) == .submit)
  for capacity in [0, -1, 65_537] {
    #expect(throws: TextInputError.invalidCapacity) { _ = try TextInput(capacity: capacity) }
  }
}

@Test func textInputNamedControlShortcutsMatchModifiedLetters() throws {
  let shortcuts: [(ControlKey, Unicode.Scalar)] = [
    (.a, "a"), (.b, "b"), (.c, "c"), (.d, "d"), (.e, "e"),
    (.f, "f"), (.h, "h"), (.k, "k"), (.u, "u"), (.x, "x")
  ]
  for (control, letter) in shortcuts {
    let named = try TextInput("abcd")
    let modified = try TextInput("abcd")
    var namedCopyBuffer = CopyBuffer()
    var modifiedCopyBuffer = CopyBuffer()
    for input in [named, modified] {
      var copyBuffer = CopyBuffer()
      _ = input.handle(.left, copyBuffer: &copyBuffer)
      _ = input.handle(.left, modifiers: .shift, copyBuffer: &copyBuffer)
    }
    #expect(
      named.handle(.control(control), copyBuffer: &namedCopyBuffer)
        == modified.handle(.character(letter), modifiers: .control, copyBuffer: &modifiedCopyBuffer))
    #expect(named.snapshot() == modified.snapshot())
    #expect(named.cursorByteOffset == modified.cursorByteOffset)
    #expect(named.selection == modified.selection)
  }
  let input = try TextInput("unchanged")
  var copyBuffer = CopyBuffer()
  for control in [ControlKey.space, .leftBracket, .backslash, .rightBracket, .caret, .underscore] {
    #expect(input.handle(.control(control), copyBuffer: &copyBuffer) == .ignored)
    #expect(input.snapshot() == "unchanged")
  }
}

@Test func inputBoxesDrawSelectionCaretClippingAndFocus() throws {
  let input = try TextInput("abcdef")
  var surface = try Surface(maximumSize: TerminalSize(columns: 4, rows: 1))
  try surface.render(size: surface.maximumSize) { InputBox(input) }
  #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "d")
  #expect(surface.cell(x: 3, y: 0)?.style.inverse == true)
  input.selectAll()
  try surface.render(size: surface.maximumSize) { InputBox(input) }
  #expect(surface.cell(x: 0, y: 0)?.style.inverse == true)
  try surface.render(size: surface.maximumSize) { InputBox(input, focused: false) }
  #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "a")
  #expect(surface.cell(x: 0, y: 0)?.style.inverse == false)
  for size in [TerminalSize(columns: 0, rows: 0), TerminalSize(columns: 1, rows: 1)] {
    try surface.render(size: size) { InputBox(input).border("Field") }
  }
}

@Test func inputLayoutReleasesFieldReferencesAfterSuccessAndPartialFailure() throws {
  let size = TerminalSize(columns: 8, rows: 1)
  var surface = try Surface(maximumSize: size)
  weak var retained: TextInput?
  do {
    let input = try TextInput("field")
    retained = input
    try surface.render(size: size) { InputBox(input) }
    #expect(throws: SurfaceError.layout(.textTooLong)) {
      try surface.render(size: size) {
        Column {
          InputBox(input)
          Text(String(repeating: "x", count: LayoutLimits.maximumTextScalars + 1))
        }
      }
    }
  }
  #expect(retained == nil)
  try surface.render(size: size) { Text("reused") }
  #expect(surface.cell(x: 0, y: 0)?.glyph.scalar == "r")
}

@Test func focusedInputAlwaysShowsItsCaretAcrossWideGlyphsAndNarrowFields() throws {
  for text in ["abcdef漢Z", "漢字😀", "e\u{301}漢", "", "a" + String(repeating: "\u{301}", count: 40)] {
    for width in 1...4 {
      let input = try TextInput(text)
      var copy = CopyBuffer()
      var surface = try Surface(maximumSize: TerminalSize(columns: width, rows: 1))
      for _ in 0...text.count {
        try surface.render(size: surface.maximumSize) { InputBox(input) }
        var caretCells = 0
        for column in 0..<width {
          let cell = surface.cell(x: column, y: 0)!
          if cell.style.underlined { caretCells += 1 }
          if cell.isContinuation {
            #expect(column > 0 && surface.cell(x: column - 1, y: 0)?.glyph.columnWidth == 2)
          }
        }
        #expect(caretCells >= 1 && caretCells <= 2)
        _ = input.handle(.left, copyBuffer: &copy)
      }
      try surface.render(size: surface.maximumSize) { InputBox(input, focused: false) }
      #expect((0..<width).allSatisfy { surface.cell(x: $0, y: 0)?.style.underlined == false })
    }
  }
}
