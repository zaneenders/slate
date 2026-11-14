import Zlib

public enum KittyImageError: Error, Equatable, Sendable {
  case invalidDimensions
  case invalidPixelCount
  case invalidPNGSignature
  case compressionFailed
}

/// Prepared image data for the Kitty graphics protocol. Create once, then upload
/// or re-upload without recompressing. Preparation allocates; output only borrows
/// this storage and uses a fixed 4 KiB writer. No native zlib or Foundation is used.
public struct KittyImage: ~Copyable, Sendable {
  public enum PixelFormat: Int, Sendable {
    /// Packed, top-to-bottom red/green/blue bytes, with no row padding.
    case rgb = 24
    /// Packed red/green/blue/alpha bytes with straight (unpremultiplied) alpha.
    case rgba = 32
  }

  /// Pixel dimensions; nil for PNG, whose dimensions are decoded by the terminal.
  public let width: Int?
  public let height: Int?
  public var byteCount: Int { bytes.count }
  let format: UInt32
  let compressed: Bool
  let bytes: Swift.UniqueArray<UInt8>

  /// Compresses raw pixels as an RFC 1950 zlib stream using swift-zlib.
  /// Dimensions must be positive UInt32 values and match the exact byte count.
  public init(
    pixels: Span<UInt8>, width: Int, height: Int, format: PixelFormat = .rgba
  ) throws(KittyImageError) {
    guard width > 0 && height > 0 && UInt32(exactly: width) != nil && UInt32(exactly: height) != nil else {
      throw .invalidDimensions
    }
    let (area, areaOverflow) = width.multipliedReportingOverflow(by: height)
    let (count, countOverflow) = area.multipliedReportingOverflow(by: format.rawValue / 8)
    guard !areaOverflow && !countOverflow && count == pixels.count else { throw .invalidPixelCount }
    do { bytes = try ZLib.deflate(input: pixels, format: .zlib) } catch { throw .compressionFailed }
    self.width = width
    self.height = height
    self.format = UInt32(format.rawValue)
    compressed = true
  }

  /// Copies an already encoded PNG without recompressing it. Only the signature
  /// is checked here; the terminal validates and decodes the image itself.
  public init(png: Span<UInt8>) throws(KittyImageError) {
    let signature: InlineArray<8, UInt8> = [137, 80, 78, 71, 13, 10, 26, 10]
    guard png.count >= signature.count else { throw .invalidPNGSignature }
    for index in 0..<signature.count {
      guard png[index] == signature[index] else { throw .invalidPNGSignature }
    }
    bytes = Swift.UniqueArray(copying: png)
    width = nil
    height = nil
    format = 100
    compressed = false
  }
}
