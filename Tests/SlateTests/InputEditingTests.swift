import Foundation
import Slate
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

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
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  try copyBuffer.flush(to: output)
  #expect(try capture.take() == Array("\u{1b}]52;c;Y2Fmw6k=\u{1b}\\".utf8))
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
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var screen = try Screen(maximumSize: TerminalSize(columns: 4, rows: 1))
  try screen.draw(size: screen.maximumSize, to: output) { InputBox(input) }
  #expect(screen.cell(x: 0, y: 0)?.glyph.scalar == "d")
  #expect(screen.cell(x: 3, y: 0)?.style.inverse == true)
  input.selectAll()
  try screen.draw(size: screen.maximumSize, to: output) { InputBox(input) }
  #expect(screen.cell(x: 0, y: 0)?.style.inverse == true)
  try screen.draw(size: screen.maximumSize, to: output) { InputBox(input, focused: false) }
  #expect(screen.cell(x: 0, y: 0)?.glyph.scalar == "a")
  #expect(screen.cell(x: 0, y: 0)?.style.inverse == false)
  for size in [TerminalSize(columns: 0, rows: 0), TerminalSize(columns: 1, rows: 1)] {
    try screen.draw(size: size, to: output) { InputBox(input).border("Field") }
  }
}

@Test func inputLayoutReleasesFieldReferencesAfterSuccessAndPartialFailure() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let size = TerminalSize(columns: 8, rows: 1)
  var screen = try Screen(maximumSize: size, nodeCapacity: 3)
  weak var retained: TextInput?
  do {
    let input = try TextInput("field")
    retained = input
    try screen.draw(size: size, to: output) { InputBox(input) }
    #expect(throws: ScreenError.layout(.nodeCapacityExceeded)) {
      try screen.draw(size: size, to: output) {
        Column {
          InputBox(input)
          Text("overflow")
        }
      }
    }
  }
  #expect(retained == nil)
  try screen.draw(size: size, to: output) { Text("reused") }
  #expect(screen.cell(x: 0, y: 0)?.glyph.scalar == "r")
}
