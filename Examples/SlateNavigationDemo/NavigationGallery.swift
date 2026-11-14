import Slate

enum GalleryScene: Int, Sendable {
  case aurora, orbit, dunes

  var imageID: UInt32 { 4_200 + UInt32(rawValue) }
  var title: String {
    switch self {
    case .aurora: return "Aurora / northern lights"
    case .orbit: return "Orbit / a distant world"
    case .dunes: return "Dunes / last light"
    }
  }

  /// One procedural artwork shared by the cell renderer and the Kitty image.
  /// Coordinates use a fixed 256 × 160 design space at any output resolution.
  func pixel(x: Int, y: Int) -> StudioPixel {
    let stars = (x * 73 + y * 179 + x * y * 11) % 997 < 3
    switch self {
    case .aurora:
      if y > 122 + abs(x - 170) / 6 { return StudioPixel(13, 29, 48) }
      if y > 105 + abs(x - 72) / 5 { return StudioPixel(28, 55, 78) }
      let center = 35 + (x - 128) * (x - 128) / 680
      let distance = abs(y - center - (x % 11) / 4)
      if distance < 30 && y < 110 {
        let brightness = 30 - distance
        return StudioPixel(20 + brightness, 60 + brightness * 5, 100 + brightness * 3)
      }
      return stars && y < 100 ? StudioPixel(210, 236, 255) : StudioPixel(10 + y / 12, 18 + y / 5, 42 + y / 5)
    case .orbit:
      let dx = x - 151
      let dy = y - 78
      let ring = dx * dx * 3 + (dy + dx / 4) * (dy + dx / 4) * 30
      let planet = dx * dx + dy * dy < 42 * 42
      if ring > 15_000 && ring < 19_500 && (dy > 0 || !planet) {
        return StudioPixel(220, 171 + abs(dx) / 3, 185)
      }
      if planet {
        let light = max(0, min(65, 32 - dx))
        let stripe = (y / 7) % 3 * 12
        return StudioPixel(140 + light, 67 + light + stripe, 114 + light + stripe)
      }
      if (x - 56) * (x - 56) + (y - 39) * (y - 39) < 9 * 9 { return StudioPixel(109, 219, 244) }
      return stars ? StudioPixel(203, 216, 250) : StudioPixel(16 + y / 18, 15 + x / 32, 40 + y / 9)
    case .dunes:
      if y > 119 + (x - 180) * (x - 180) / 900 { return StudioPixel(59 + y / 8, 34, 78) }
      if y > 96 + (x - 55) * (x - 55) / 1_500 { return StudioPixel(155 + y / 10, 73, 108) }
      if y > 84 + abs(x - 170) / 10 { return StudioPixel(197, 102, 122) }
      if (x - 181) * (x - 181) + (y - 43) * (y - 43) < 23 * 23 { return StudioPixel(255, 221, 160) }
      return StudioPixel(103 + y, 72 + y, 143 + y / 3)
    }
  }
}

struct StudioPixel {
  let red: UInt8
  let green: UInt8
  let blue: UInt8

  init(_ red: Int, _ green: Int, _ blue: Int) {
    self.red = UInt8(clamping: red)
    self.green = UInt8(clamping: green)
    self.blue = UInt8(clamping: blue)
  }

  var color: Color { .rgb(red, green, blue) }
}

final class StudioArtwork: CanvasDrawing, ~Sendable {
  var scene = GalleryScene.aurora
  var showsCells = true
  var background = StudioPalette().panel

  func paint(in frame: inout Frame) {
    frame.fill(frame.area, with: Cell(style: Style(background: background)))
    guard showsCells else { return }
    for y in 0..<frame.area.height {
      for x in 0..<frame.area.width {
        let u = x * 256 / max(1, frame.area.width)
        let v = y * 160 / max(1, frame.area.height)
        let top = scene.pixel(x: u, y: v)
        let bottom = scene.pixel(x: u, y: min(159, v + 80 / max(1, frame.area.height)))
        frame[x, y] = Cell(Glyph("▀")!, style: Style(foreground: top.color, background: bottom.color))
      }
    }
  }
}

/// Images are prepared lazily on the first supported gallery presentation, then
/// uploaded once per scene. The procedural cell fallback needs no image storage.
final class StudioImages: ~Sendable {
  private let aurora: KittyImage
  private let orbit: KittyImage
  private let dunes: KittyImage

  init() {
    aurora = Self.prepare(.aurora)
    orbit = Self.prepare(.orbit)
    dunes = Self.prepare(.dunes)
  }

  func upload(_ scene: GalleryScene, to output: borrowing Output) throws(KittyGraphicsError) {
    switch scene {
    case .aurora: try output.uploadKittyImage(aurora, id: scene.imageID, responses: .errors)
    case .orbit: try output.uploadKittyImage(orbit, id: scene.imageID, responses: .errors)
    case .dunes: try output.uploadKittyImage(dunes, id: scene.imageID, responses: .errors)
    }
  }

  private static func prepare(_ scene: GalleryScene) -> KittyImage {
    let width = 256
    let height = 160
    var pixels = [UInt8]()
    pixels.reserveCapacity(width * height * 3)
    for y in 0..<height {
      for x in 0..<width {
        let pixel = scene.pixel(x: x, y: y)
        pixels.append(pixel.red)
        pixels.append(pixel.green)
        pixels.append(pixel.blue)
      }
    }
    return try! KittyImage(pixels: pixels.span, width: width, height: height, format: .rgb)
  }
}

enum GallerySupport { case probing, supported, unavailable }

extension SlateNavigationDemo {
  static var graphicsQueryID: UInt32 { 4_199 }

  var galleryStatus: String {
    if !usesKitty { return "Cell preview / Enter the image to change scene" }
    switch graphicsSupport {
    case .probing: return "Cell preview / checking Kitty graphics support"
    case .supported: return "Kitty image / 256 × 160 / switch to Cells to compare"
    case .unavailable: return "Cell preview / Kitty graphics unavailable"
    }
  }

  mutating func presentGraphics(in size: TerminalSize, to output: borrowing Output) throws(KittyGraphicsError) {
    let region =
      page == .gallery && graphicsSupport == .supported && usesKitty
      ? focus.bounds(for: .artwork) : nil
    let desiredID = region == nil ? nil : scene.imageID
    if let placedImageID, placedImageID != desiredID {
      try output.deleteKittyPlacement(imageID: placedImageID, placementID: 1)
      self.placedImageID = nil
    }
    guard let region, !region.isEmpty else { return }
    if images == nil { images = StudioImages() }
    let bit = UInt8(1 << scene.rawValue)
    if uploadedImages & bit == 0 {
      // Record ownership before output so partial uploads are cleaned up too.
      uploadedImages |= bit
      try images!.upload(scene, to: output)
    }
    placedImageID = scene.imageID
    try output.placeKittyImage(id: scene.imageID, in: region, responses: .errors)
  }

  mutating func clearGraphics(to output: borrowing Output) throws(KittyGraphicsError) {
    for scene in [GalleryScene.aurora, .orbit, .dunes] {
      let bit = UInt8(1 << scene.rawValue)
      if uploadedImages & bit != 0 {
        try output.deleteKittyImage(id: scene.imageID)
        uploadedImages &= ~bit
      }
    }
    placedImageID = nil
  }
}
