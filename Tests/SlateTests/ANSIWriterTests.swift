import Testing

@testable import SlateTerminal

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

@Test func writerChangesOnlyColorsWhenAttributesAreUnchanged() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var writer = ANSIWriter()
  let previous = Style(
    foreground: .indexed(255), background: .blue,
    bold: true, dim: true, underlined: true, inverse: true)
  var next = previous
  next.foreground = .indexed(0)
  try writer.style(next, previous: previous, to: output)
  try writer.flush(to: output)
  #expect(try capture.take() == Array("\u{1b}[38;5;0m".utf8))

  let colored = next
  next.foreground = .default
  next.background = .default
  try writer.style(next, previous: colored, to: output)
  try writer.flush(to: output)
  #expect(try capture.take() == Array("\u{1b}[39;49m".utf8))

  writer.reset()
  try writer.style(next, previous: next, to: output)
  try writer.flush(to: output)
  #expect(try capture.take().isEmpty)
  #expect(writer.outputBytes == 0)
}

@Test func writerStyleTransitionsPreserveEveryAttributeAndRestoreDefaultColors() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var writer = ANSIWriter()
  let colors: [Color] = [
    .default, .indexed(0), .indexed(1), .indexed(9),
    .indexed(10), .indexed(99), .indexed(100), .indexed(255)
  ]
  for flags in 0..<16 {
    for source in colors {
      for destination in colors {
        for transition in 0..<3 {
          let previous = style(flags: flags, foreground: source, background: source)
          let next = style(
            flags: flags,
            foreground: transition == 1 ? source : destination,
            background: transition == 0 ? source : destination)
          writer.reset()
          // Initial full style must overwrite arbitrary prior terminal attributes.
          try writer.style(previous, to: output)
          try writer.style(next, previous: previous, to: output)
          try writer.flush(to: output)
          #expect(try decodeStyles(capture.take()) == next)
        }
      }
    }
  }
  // Full resets handle every flag combination, including bold and dim together.
  for previousFlags in 0..<16 {
    for nextFlags in 0..<16 {
      let previous = style(flags: previousFlags, foreground: .indexed(255), background: .blue)
      let next = style(flags: nextFlags, foreground: .default, background: .indexed(0))
      writer.reset()
      try writer.style(previous, to: output)
      try writer.style(next, previous: previous, to: output)
      try writer.flush(to: output)
      #expect(try decodeStyles(capture.take()) == next)
    }
  }
}

@Test func writerColorTransitionsRemainCorrectAcrossBufferFlushes() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var writer = ANSIWriter()
  var previous: Style?
  // More than five buffers; transitions include both default and indexed colors.
  for index in 0..<2_048 {
    let next = style(
      flags: 15,
      foreground: index.isMultiple(of: 17) ? .default : .indexed(UInt8(index % 256)),
      background: index.isMultiple(of: 31) ? .default : .indexed(UInt8((index / 31) % 256)))
    try writer.style(next, previous: previous, to: output)
    previous = next
  }
  try writer.flush(to: output)
  let bytes = try capture.take()
  #expect(bytes.count > 4_096 * 5)
  #expect(writer.outputBytes == bytes.count)
  #expect(try decodeStyles(bytes) == previous)
}

@Test func writerPropagatesAnAutomaticFlushFailureDuringAColorTransition() throws {
  // A duplicate of a read-only descriptor deterministically rejects writes.
  let descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
  try #require(descriptor >= 0)
  defer { _ = close(descriptor) }
  let output = try Output(fileDescriptor: descriptor)
  var writer = ANSIWriter()
  for _ in 0..<4_095 { try writer.glyph(.space, to: output) }
  #expect(throws: IOError.write(errno: EBADF, bytesWritten: 0)) {
    try writer.style(Style(foreground: .red), previous: Style(), to: output)
  }
  #expect(writer.outputBytes == 0)
  writer.reset()
  try writer.flush(to: output)
  #expect(writer.outputBytes == 0)
}

private func style(flags: Int, foreground: Color, background: Color) -> Style {
  Style(
    foreground: foreground, background: background,
    bold: flags & 1 != 0, dim: flags & 2 != 0,
    underlined: flags & 4 != 0, inverse: flags & 8 != 0)
}

// Independent SGR interpreter for the emitted subset, using terminal semantics:
// https://xtermjs.org/docs/api/vtfeatures/#select-graphic-rendition
// An arbitrary starting state catches missing resets in the first full style.
private func decodeStyles(_ bytes: [UInt8]) throws -> Style {
  var result = Style(
    foreground: .red, background: .green,
    bold: true, dim: true, underlined: true, inverse: true)
  let sequences = String(decoding: bytes, as: UTF8.self).split(separator: "\u{1b}")
  for sequence in sequences {
    try #require(sequence.first == "[" && sequence.last == "m")
    let parameters = try sequence.dropFirst().dropLast().split(separator: ";").map { try #require(Int($0)) }
    var index = 0
    while index < parameters.count {
      switch parameters[index] {
      case 0: result = Style()
      case 1: result.bold = true
      case 2: result.dim = true
      case 4: result.underlined = true
      case 7: result.inverse = true
      case 39: result.foreground = .default
      case 49: result.background = .default
      case 38, 48:
        try #require(index + 2 < parameters.count && parameters[index + 1] == 5)
        let color = Color.indexed(try #require(UInt8(exactly: parameters[index + 2])))
        if parameters[index] == 38 { result.foreground = color } else { result.background = color }
        index += 2
      default:
        Issue.record("Unexpected SGR parameter: \(parameters[index])")
      }
      index += 1
    }
  }
  return result
}
