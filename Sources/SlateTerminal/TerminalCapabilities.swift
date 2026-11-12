import SlateUI

/// Explicit output policy. No environment inspection, negotiation, or per-frame
/// capability queries. Choose settings appropriate for the terminal you own.
public struct TerminalCapabilities: Equatable, Sendable {
  public enum ColorMode: Equatable, Sendable {
    case trueColor
    case indexed256
    case ansi16
    case monochrome
  }

  public enum UnicodeMode: Equatable, Sendable {
    /// Emit Unicode using Slate's grapheme widths. ScreenApplication enables
    /// mode 2027; manual presenters must coordinate that mode themselves.
    case grapheme
    /// Emit ASCII only. Non-ASCII graphemes become `?`, followed by a space for
    /// a two-column glyph, so subsequent cells retain their logical positions.
    case ascii
  }

  public let color: ColorMode
  public let unicode: UnicodeMode

  public init(color: ColorMode = .indexed256, unicode: UnicodeMode = .grapheme) {
    self.color = color
    self.unicode = unicode
  }

  /// RGB fallback compares the nearest xterm cube color with its nearest gray.
  /// ANSI-16 fallback uses canonical 0/128/192/255 channel values; a terminal's
  /// customized palette may differ. Existing indices below 16 remain unchanged.
  /// At most sixteen fixed candidates are examined; no palette storage is needed.
  func resolve(_ requested: Color) -> Color {
    switch color {
    case .trueColor: return requested
    case .monochrome: return .default
    case .indexed256:
      guard case .rgb(let red, let green, let blue) = requested else { return requested }
      return .indexed(nearest256(red: Int(red), green: Int(green), blue: Int(blue)))
    case .ansi16:
      let rgb: (Int, Int, Int)
      switch requested {
      case .default: return .default
      case .indexed(let index):
        if index < 16 { return requested }
        rgb = paletteRGB(index)
      case .rgb(let red, let green, let blue): rgb = (Int(red), Int(green), Int(blue))
      }
      var nearest: UInt8 = 0
      var distance = Int.max
      for index: UInt8 in 0..<16 {
        let candidate = paletteRGB(index)
        let next = squaredDistance(rgb, candidate)
        if next < distance {
          nearest = index
          distance = next
        }
      }
      return .indexed(nearest)
    }
  }
}

private func nearest256(red: Int, green: Int, blue: Int) -> UInt8 {
  let r = cubeIndex(red)
  let g = cubeIndex(green)
  let b = cubeIndex(blue)
  let cube = (cubeValue(r), cubeValue(g), cubeValue(b))
  let grayIndex = min(23, max(0, (red + green + blue - 9) / 30))
  let gray = 8 + 10 * grayIndex
  let source = (red, green, blue)
  if squaredDistance(source, (gray, gray, gray)) < squaredDistance(source, cube) {
    return UInt8(232 + grayIndex)
  }
  return UInt8(16 + 36 * r + 6 * g + b)
}

private func cubeIndex(_ channel: Int) -> Int {
  if channel < 48 { return 0 }
  if channel < 115 { return 1 }
  return (channel - 35) / 40
}

private func cubeValue(_ index: Int) -> Int { index == 0 ? 0 : 55 + 40 * index }

private func paletteRGB(_ index: UInt8) -> (Int, Int, Int) {
  if index >= 232 {
    let gray = 8 + 10 * Int(index - 232)
    return (gray, gray, gray)
  }
  if index >= 16 {
    let cube = Int(index - 16)
    return (cubeValue(cube / 36), cubeValue(cube / 6 % 6), cubeValue(cube % 6))
  }
  if index == 7 { return (192, 192, 192) }
  if index == 8 { return (128, 128, 128) }
  let value = index < 8 ? 128 : 255
  return (index & 1 == 0 ? 0 : value, index & 2 == 0 ? 0 : value, index & 4 == 0 ? 0 : value)
}

private func squaredDistance(_ left: (Int, Int, Int), _ right: (Int, Int, Int)) -> Int {
  let red = left.0 - right.0
  let green = left.1 - right.1
  let blue = left.2 - right.2
  return red * red + green * green + blue * blue
}
