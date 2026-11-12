import SlateTestSupport
import Testing

@testable import SlateTerminal

@Test func trueColorPreservesChannelsAttributesAndColorOnlyTransitions() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var writer = ANSIWriter(capabilities: .init(color: .trueColor))
  let first = Style(foreground: .rgb(0, 127, 255), background: .rgb(255, 0, 16), bold: true)
  try writer.style(first, to: output)
  try writer.flush(to: output)
  #expect(try capture.take() == Array("\u{1b}[0;1;38;2;0;127;255;48;2;255;0;16m".utf8))
  let next = Style(background: .rgb(1, 2, 3), bold: true)
  try writer.style(next, previous: first, to: output)
  try writer.flush(to: output)
  #expect(try capture.take() == Array("\u{1b}[39;48;2;1;2;3m".utf8))
  try writer.style(Style(foreground: .rgb(255, 255, 255)), previous: next, to: output)
  try writer.flush(to: output)
  #expect(try capture.take() == Array("\u{1b}[0;38;2;255;255;255m".utf8))
  #expect(Color.rgb(1, 2, 3) != .rgb(1, 2, 4))
}

@Test func paletteFallbackUsesNearestCubeOrGrayAndPreservesExistingIndices() throws {
  let capabilities = TerminalCapabilities()
  for index in UInt8.min...UInt8.max {
    #expect(capabilities.resolve(.indexed(index)) == .indexed(index))
  }
  #expect(capabilities.resolve(.default) == .default)
  #expect(capabilities.resolve(.rgb(0, 0, 0)) == .indexed(16))
  #expect(capabilities.resolve(.rgb(255, 255, 255)) == .indexed(231))
  #expect(capabilities.resolve(.rgb(255, 0, 0)) == .indexed(196))
  #expect(capabilities.resolve(.rgb(128, 128, 128)) == .indexed(244))
  // Scan the entire fixed palette independently; ties may select either nearest
  // candidate. Include cube midpoint and grayscale boundary channels.
  let channels: [UInt8] = [0, 47, 48, 115, 128, 155, 195, 235, 255]
  for red in channels {
    for green in channels {
      for blue in channels {
        let color = capabilities.resolve(.rgb(red, green, blue))
        guard case .indexed(let index) = color else {
          Issue.record("RGB fallback did not select a palette color")
          return
        }
        let chosen = referenceColorDistance(Int(index), red, green, blue)
        var nearest = Int.max
        for candidate in 16..<256 {
          nearest = min(nearest, referenceColorDistance(candidate, red, green, blue))
        }
        #expect(chosen == nearest)
      }
    }
  }
}

@Test func ansi16AndMonochromeFallbackKeepAttributesAndAvoidExtendedColorSequences() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var writer = ANSIWriter(capabilities: .init(color: .ansi16))
  let style = Style(foreground: .rgb(255, 0, 0), background: .indexed(21), underlined: true)
  try writer.style(style, to: output)
  try writer.flush(to: output)
  #expect(try capture.take() == Array("\u{1b}[0;4;91;104m".utf8))
  let next = Style(foreground: .red, underlined: true)
  try writer.style(next, previous: style, to: output)
  try writer.flush(to: output)
  #expect(try capture.take() == Array("\u{1b}[31;49m".utf8))

  let ansi = TerminalCapabilities(color: .ansi16)
  for index: UInt8 in 0..<16 { #expect(ansi.resolve(.indexed(index)) == .indexed(index)) }
  for index in UInt8.min...UInt8.max {
    guard case .indexed(let result) = ansi.resolve(.indexed(index)) else {
      Issue.record("Missing palette entry")
      return
    }
    #expect(result < 16)
  }
  var monochrome = ANSIWriter(capabilities: .init(color: .monochrome))
  try monochrome.style(style, to: output)
  try monochrome.style(next, previous: style, to: output)
  try monochrome.flush(to: output)
  #expect(try capture.take() == Array("\u{1b}[0;4m".utf8))
}

@Test func asciiPresentationPreservesWideColumnsAndDiffsLogicalCells() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let size = TerminalSize(columns: 6, rows: 1)
  var screen = try Screen(maximumSize: size, capabilities: .init(color: .monochrome, unicode: .ascii))
  try screen.draw(size: size, to: output) { Text("Aé漢e\u{301}B", style: Style(foreground: .rgb(1, 2, 3))) }
  let bytes = try capture.take()
  #expect(bytes == Array("\u{1b}[0m\u{1b}[2J\u{1b}[1;1H\u{1b}[0mA?? ?B\u{1b}[0m".utf8))
  #expect(bytes.allSatisfy { $0 < 128 })
  #expect(screen.cell(x: 2, y: 0)?.glyph.scalar == "漢")
  #expect(screen.cell(x: 3, y: 0)?.isContinuation == true)
  let repeated = try screen.draw(size: size, to: output) {
    Text("Aé漢e\u{301}B", style: Style(foreground: .rgb(1, 2, 3)))
  }
  #expect(repeated.outputBytes == 0)
  #expect(try capture.take().isEmpty)
}

@Test func regionPresentationUsesConfiguredRGBAndASCIIWithoutChangingLogicalCells() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let size = TerminalSize(columns: 4, rows: 1)
  var region = try ScreenRegion(maximumSize: size, capabilities: .init(color: .trueColor, unicode: .ascii))
  try region.draw(in: Rect(width: 4, height: 1), clippedTo: size, to: output) {
    Text("漢é!", style: Style(foreground: .rgb(255, 0, 127)))
  }
  #expect(
    try capture.take()
      == Array("\u{1b}7\u{1b}[0m\u{1b}[1;1H\u{1b}[0;38;2;255;0;127m? ?!\u{1b}[0m\u{1b}8".utf8))
}

private func referenceColorDistance(_ index: Int, _ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Int {
  precondition((16..<256).contains(index))
  let components: (Int, Int, Int)
  if index >= 232 {
    let gray = 8 + (index - 232) * 10
    components = (gray, gray, gray)
  } else {
    let cube: InlineArray<6, Int> = [0, 95, 135, 175, 215, 255]
    let position = index - 16
    components = (cube[position / 36], cube[position / 6 % 6], cube[position % 6])
  }
  let r = Int(red) - components.0
  let g = Int(green) - components.1
  let b = Int(blue) - components.2
  return r * r + g * g + b * b
}
