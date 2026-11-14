import Slate

@main
struct SlateKittyGraphicsDemo: ScreenApplication, ~Copyable {
  private let image: KittyImage
  private var needsImageCleanup = false

  init() {
    let width = 256
    let height = 128
    var pixels = [UInt8]()
    pixels.reserveCapacity(width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        pixels.append(contentsOf: [UInt8(x), UInt8(y * 2), UInt8(255 - x), 255])
      }
    }
    // Fixed, known-valid pixels are prepared once before entering terminal modes.
    image = try! KittyImage(pixels: pixels.span, width: width, height: height)
  }

  var tickInterval: Duration? { nil }

  func render(in size: TerminalSize) -> some Block {
    Text("Kitty graphics / swift-zlib - Enter, Escape, Ctrl-C, or Q to exit")
  }

  mutating func presentGraphics(in size: TerminalSize, to output: borrowing Output) throws(KittyGraphicsError) {
    if !needsImageCleanup {
      // Register ownership before writing so a partial upload is also cleaned up.
      needsImageCleanup = true
      try output.uploadKittyImage(image, id: 1)
    }
    if size.columns > 2 && size.rows > 3 {
      try output.placeKittyImage(
        id: 1, in: Rect(x: 1, y: 2, width: size.columns - 2, height: size.rows - 3))
    } else {
      try output.deleteKittyPlacement(imageID: 1, placementID: 1)
    }
  }

  mutating func clearGraphics(to output: borrowing Output) throws(KittyGraphicsError) {
    guard needsImageCleanup else { return }
    try output.deleteKittyImage(id: 1)
    needsImageCleanup = false
  }

  mutating func event(_ event: borrowing ScreenEvent, copyBuffer: inout CopyBuffer) -> ScreenUpdate {
    switch event {
    case .key(.enter, _), .key(.escape, _), .key(.control(.c), _), .key(.character("q"), _),
      .key(.character("Q"), _):
      return .quit
    case .key(.character("c"), let modifiers) where modifiers.withoutLocks == .control:
      return .quit
    default: return .none
    }
  }
}
