import CIOTestSupport
import Foundation
import SlateTerminal
import SlateTestSupport
import Testing
import Zlib

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

@Test func kittyRawPixelsRoundTripThroughZlibAndChunkedBase64() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  for format in [KittyImage.PixelFormat.rgb, .rgba] {
    let width = 80
    let height = 60
    var state: UInt32 = 42
    let pixels = (0..<(width * height * (format.rawValue / 8))).map { _ -> UInt8 in
      state = state &* 1_664_525 &+ 1_013_904_223
      return UInt8(truncatingIfNeeded: state >> 24)
    }
    let image = try KittyImage(pixels: pixels.span, width: width, height: height, format: format)
    #expect(image.width == width && image.height == height)
    let count = try output.uploadKittyImage(image, id: .max)
    let bytes = try capture.take()
    #expect(count == bytes.count)
    let chunks = try kittyChunks(bytes)
    #expect(chunks.count > 1)
    #expect(chunks[0].header == "a=t,t=d,f=\(format.rawValue),s=80,v=60,o=z,i=4294967295,q=2,m=1")
    let compressed = try decodeKittyPayload(chunks)
    #expect(image.byteCount == compressed.count)
    let inflated = try ZLib.inflate(input: compressed.span, format: .zlib, maximumOutputSize: pixels.count)
    #expect(inflated.count == pixels.count)
    for index in 0..<pixels.count { #expect(inflated.span[index] == pixels[index]) }
    // Prepared data can be borrowed repeatedly without recompression or mutation.
    try output.uploadKittyImage(image, id: .max)
    #expect(try capture.take() == bytes)
  }
}

@Test func kittyPNGTransportPreservesBytesAtEveryChunkBoundary() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  for count in [8, 3_071, 3_072, 3_073, 6_144, 6_145] {
    // PNG validation belongs to the terminal. Exercise opaque transport with
    // a signature followed by enough bytes to straddle each base64 boundary.
    var png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    png.append(contentsOf: repeatElement(0xab, count: count - png.count))
    let image = try KittyImage(png: png.span)
    #expect(image.width == nil && image.height == nil && image.byteCount == png.count)
    let written = try output.uploadKittyImage(image, id: 7, responses: .errors)
    let bytes = try capture.take()
    #expect(written == bytes.count)
    let chunks = try kittyChunks(bytes)
    #expect(chunks.count == (count + 3_071) / 3_072)
    #expect(chunks[0].header == "a=t,t=d,f=100,i=7,q=1,m=\(chunks.count > 1 ? 1 : 0)")
    #expect(try decodeKittyPayload(chunks) == png)
  }
}

@Test func kittyPlacementPreservesCursorAndUsesFullIdentifiersAndSignedZIndex() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let count = try output.placeKittyImage(
    id: .max, placementID: .max, in: Rect(x: 4, y: 2, width: 20, height: 10), zIndex: .min, responses: .all)
  let bytes = try capture.take()
  #expect(count == bytes.count)
  #expect(
    bytes
      == Array(
        "\u{1b}7\u{1b}[3;5H\u{1b}_Ga=p,i=4294967295,p=4294967295,c=20,r=10,z=-2147483648,C=1,q=0\u{1b}\\\u{1b}8".utf8))
  try output.deleteKittyPlacement(imageID: .max, placementID: 2)
  #expect(try capture.take() == Array("\u{1b}_Ga=d,d=i,i=4294967295,p=2,q=2\u{1b}\\".utf8))
  try output.deleteKittyImage(id: .max)
  #expect(try capture.take() == Array("\u{1b}_Ga=d,d=I,i=4294967295,q=2\u{1b}\\".utf8))
  try output.queryKittyGraphics(id: 31)
  #expect(try capture.take() == Array("\u{1b}_Ga=q,t=d,f=24,s=1,v=1,i=31;AAAA\u{1b}\\\u{1b}[c".utf8))
}

@Test func kittyRejectsInvalidImagesIDsAndEmptyPlacementsBeforeWriting() throws {
  let empty: [UInt8] = []
  for (width, height) in [(0, 1), (1, 0), (-1, 1), (Int.max, 1)] {
    #expect(throws: KittyImageError.invalidDimensions) {
      _ = try KittyImage(pixels: empty.span, width: width, height: height)
    }
  }
  for (width, height) in [(1, 1), (Int(UInt32.max), Int(UInt32.max))] {
    #expect(throws: KittyImageError.invalidPixelCount) {
      _ = try KittyImage(pixels: empty.span, width: width, height: height)
    }
  }
  #expect(throws: KittyImageError.invalidPNGSignature) { _ = try KittyImage(png: empty.span) }
  let badPNG = [UInt8](repeating: 0, count: 8)
  #expect(throws: KittyImageError.invalidPNGSignature) { _ = try KittyImage(png: badPNG.span) }
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  let pixel: [UInt8] = [1, 2, 3, 4]
  let image = try KittyImage(pixels: pixel.span, width: 1, height: 1)
  let region = Rect(width: 1, height: 1)
  #expect(throws: KittyGraphicsError.invalidImageID) { try output.uploadKittyImage(image, id: 0) }
  #expect(throws: KittyGraphicsError.invalidImageID) { try output.queryKittyGraphics(id: 0) }
  #expect(throws: KittyGraphicsError.invalidImageID) { try output.placeKittyImage(id: 0, in: region) }
  #expect(throws: KittyGraphicsError.invalidPlacementID) {
    try output.placeKittyImage(id: 1, placementID: 0, in: region)
  }
  #expect(throws: KittyGraphicsError.emptyRegion) {
    try output.placeKittyImage(id: 1, in: Rect(width: 0, height: 1))
  }
  #expect(throws: KittyGraphicsError.invalidImageID) { try output.deleteKittyImage(id: 0) }
  #expect(throws: KittyGraphicsError.invalidPlacementID) {
    try output.deleteKittyPlacement(imageID: 1, placementID: 0)
  }
  #expect(try capture.take().isEmpty)
}

#if os(Linux)
@Test func kittyPartialUploadReportsTotalProgressAndCancelsOnlyItsImage() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  var png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
  png.append(contentsOf: repeatElement(0xab, count: 8_192))
  let image = try KittyImage(png: png.span)
  let steps: InlineArray<3, Int32> = [4_096, 5, -EAGAIN]
  steps.span.withUnsafeBufferPointer { unsafe cli_test_write_script($0.baseAddress, $0.count) }
  defer { cli_test_reset_io() }
  var progress = 0
  do {
    try output.uploadKittyImage(image, id: 17)
    Issue.record("Expected scripted output failure")
  } catch {
    guard case .output(.write(let number, let count)) = error else {
      Issue.record("Unexpected failure: \(error)")
      return
    }
    #expect(number == EAGAIN)
    progress = count
  }
  let bytes = try capture.take()
  let recovery = Array("\u{18}\u{1b}\\\u{1b}_Ga=d,d=I,i=17,q=2\u{1b}\\".utf8)
  #expect(progress > 4_096 && bytes.count == progress + recovery.count)
  #expect(bytes.suffix(recovery.count) == recovery)
  try output.uploadKittyImage(image, id: 17)
  #expect(try decodeKittyPayload(kittyChunks(capture.take())) == png)
}

@Test func kittyFailedPlacementRestoresSavedCursorAndZeroProgressDoesNoRecovery() throws {
  let capture = try ScreenCapture()
  let output = try Output(fileDescriptor: capture.descriptor)
  for partial: Int32 in [0, 1, 2, 20] {
    let steps: [Int32] = partial == 0 ? [-EAGAIN] : [partial, -EAGAIN]
    steps.withUnsafeBufferPointer { unsafe cli_test_write_script($0.baseAddress, $0.count) }
    defer { cli_test_reset_io() }
    #expect(throws: KittyGraphicsError.output(.write(errno: EAGAIN, bytesWritten: Int(partial)))) {
      try output.placeKittyImage(id: 1, in: Rect(width: 1, height: 1))
    }
    let bytes = try capture.take()
    let recovery = partial == 0 ? "" : (partial == 1 ? "\u{18}\u{1b}\\" : "\u{18}\u{1b}\\\u{1b}8")
    #expect(bytes.count == Int(partial) + recovery.utf8.count)
    #expect(bytes.suffix(recovery.utf8.count) == Array(recovery.utf8))
  }
}
#endif

private struct KittyChunk {
  let header: String
  let payload: String
}

private func kittyChunks(_ bytes: [UInt8]) throws -> [KittyChunk] {
  let commands = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\u{1b}\\")
  try #require(commands.last == "")
  return try commands.dropLast().map { command in
    try #require(command.hasPrefix("\u{1b}_G"))
    let fields = command.dropFirst(3).split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
    try #require(fields.count == 2)
    return KittyChunk(header: String(fields[0]), payload: String(fields[1]))
  }
}

private func decodeKittyPayload(_ chunks: [KittyChunk]) throws -> [UInt8] {
  var payload = ""
  for (index, chunk) in chunks.enumerated() {
    let last = index == chunks.count - 1
    #expect(chunk.payload.utf8.count <= 4_096 && chunk.payload.utf8.count.isMultiple(of: 4))
    #expect(chunk.header.hasSuffix(last ? "m=0" : "m=1"))
    if index > 0 { #expect(chunk.header == (last ? "m=0" : "m=1")) }
    if !last { #expect(chunk.payload.utf8.count == 4_096 && !chunk.payload.contains("=")) }
    payload += chunk.payload
  }
  return Array(try #require(Data(base64Encoded: payload)))
}
