public import SlateUI

public enum KittyGraphicsError: Error, Equatable, Sendable {
  case invalidImageID
  case invalidPlacementID
  case emptyRegion
  case output(IOError)
}

/// Reply policy for uploads and placements. Replies use the existing input owner.
public enum KittyGraphicsResponses: UInt32, Sendable {
  case all = 0
  case errors = 1
  case none = 2
}

extension Output {
  /// Queries support using one RGB pixel without storing or replacing an image,
  /// followed by a primary device attributes request. Read both replies through
  /// the existing TerminalInput owner. A matching successful Kitty reply means
  /// support; primary attributes arriving first means no support. This method
  /// never waits or creates a second reader. Choose a nonzero correlation ID.
  @discardableResult
  public borrowing func queryKittyGraphics(id: UInt32) throws(KittyGraphicsError) -> Int {
    guard id != 0 else { throw .invalidImageID }
    return try writeKittyCommand { (writer: inout ANSIWriter) throws(IOError) in
      try writer.literal("\u{1b}_Ga=q,t=d,f=24,s=1,v=1,i=", to: self)
      try writer.unsignedNumber(id, to: self)
      try writer.literal(";AAAA\u{1b}\\\u{1b}[c", to: self)
    }
  }

  /// Uploads prepared pixels or PNG bytes without displaying them. Uses direct
  /// transport, including over SSH, with at most 4096 base64 bytes per chunk.
  /// The caller chooses a nonzero image ID and serializes output with other
  /// writers. Re-uploading an ID replaces its data and removes its placements.
  /// By default commands suppress terminal replies (q=2); success reports local I/O,
  /// not terminal support or acceptance. Returns the number of bytes written.
  @discardableResult
  public borrowing func uploadKittyImage(
    _ image: borrowing KittyImage, id: UInt32, responses: KittyGraphicsResponses = .none
  ) throws(KittyGraphicsError) -> Int {
    guard id != 0 else { throw .invalidImageID }
    return try writeKittyCommand(cancelImageID: id) { (writer: inout ANSIWriter) throws(IOError) in
      let bytes = image.bytes.span
      var offset = 0
      while offset < bytes.count {
        // Three raw bytes encode to four base64 bytes. Only the final chunk
        // may have padding; the stream is compressed once before chunking.
        let end = offset + min(3_072, bytes.count - offset)
        try writer.literal("\u{1b}_G", to: self)
        if offset == 0 {
          try writer.literal("a=t,t=d,f=", to: self)
          try writer.unsignedNumber(image.format, to: self)
          if let width = image.width, let height = image.height {
            try writer.literal(",s=", to: self)
            try writer.unsignedNumber(UInt32(width), to: self)
            try writer.literal(",v=", to: self)
            try writer.unsignedNumber(UInt32(height), to: self)
          }
          if image.compressed { try writer.literal(",o=z", to: self) }
          try writer.literal(",i=", to: self)
          try writer.unsignedNumber(id, to: self)
          try writer.literal(",q=", to: self)
          try writer.unsignedNumber(responses.rawValue, to: self)
          try writer.literal(",", to: self)
        }
        try writer.literal(end == bytes.count ? "m=0;" : "m=1;", to: self)
        try writer.base64(bytes.extracting(offset..<end), to: self)
        try writer.literal("\u{1b}\\", to: self)
        offset = end
      }
    }
  }

  /// Displays an uploaded image in absolute, zero-based terminal cells. A repeated
  /// image/placement ID moves or resizes the existing placement. Preserves the
  /// cursor and requests C=1 so placement cannot scroll the screen. The terminal
  /// fits the image's aspect ratio inside the rectangle. Negative z-indices draw
  /// under text; values below -1_073_741_824 also draw under cell backgrounds.
  /// Call after presenting text; redraw placements after a screen clear/resize.
  @discardableResult
  public borrowing func placeKittyImage(
    id: UInt32, placementID: UInt32 = 1, in region: Rect, zIndex: Int32 = 0,
    responses: KittyGraphicsResponses = .none
  ) throws(KittyGraphicsError) -> Int {
    guard id != 0 else { throw .invalidImageID }
    guard placementID != 0 else { throw .invalidPlacementID }
    guard !region.isEmpty else { throw .emptyRegion }
    return try writeKittyCommand(restoreCursor: true) { (writer: inout ANSIWriter) throws(IOError) in
      try writer.literal("\u{1b}7", to: self)
      try writer.cursor(x: region.x, y: region.y, to: self)
      try writer.literal("\u{1b}_Ga=p,i=", to: self)
      try writer.unsignedNumber(id, to: self)
      try writer.literal(",p=", to: self)
      try writer.unsignedNumber(placementID, to: self)
      try writer.literal(",c=", to: self)
      try writer.unsignedNumber(UInt32(region.width), to: self)
      try writer.literal(",r=", to: self)
      try writer.unsignedNumber(UInt32(region.height), to: self)
      try writer.literal(",z=", to: self)
      try writer.signedNumber(zIndex, to: self)
      try writer.literal(",C=1,q=", to: self)
      try writer.unsignedNumber(responses.rawValue, to: self)
      try writer.literal("\u{1b}\\\u{1b}8", to: self)
    }
  }

  /// Removes one placement, retaining the uploaded image for reuse.
  @discardableResult
  public borrowing func deleteKittyPlacement(
    imageID: UInt32, placementID: UInt32
  ) throws(KittyGraphicsError) -> Int {
    guard imageID != 0 else { throw .invalidImageID }
    guard placementID != 0 else { throw .invalidPlacementID }
    return try writeKittyCommand { (writer: inout ANSIWriter) throws(IOError) in
      try writer.literal("\u{1b}_Ga=d,d=i,i=", to: self)
      try writer.unsignedNumber(imageID, to: self)
      try writer.literal(",p=", to: self)
      try writer.unsignedNumber(placementID, to: self)
      try writer.literal(",q=2\u{1b}\\", to: self)
    }
  }

  /// Removes an image's placements and asks the terminal to release its data.
  /// Cleanup is explicit; destroying KittyImage performs no terminal I/O.
  @discardableResult
  public borrowing func deleteKittyImage(id: UInt32) throws(KittyGraphicsError) -> Int {
    guard id != 0 else { throw .invalidImageID }
    return try writeKittyCommand { (writer: inout ANSIWriter) throws(IOError) in
      try writer.deleteKittyImage(id: id, to: self)
    }
  }

  private borrowing func writeKittyCommand(
    cancelImageID: UInt32? = nil, restoreCursor: Bool = false,
    _ encode: (inout ANSIWriter) throws(IOError) -> Void
  ) throws(KittyGraphicsError) -> Int {
    var writer = ANSIWriter()
    do throws(IOError) {
      try encode(&writer)
      try writer.flush(to: self)
    } catch {
      var progress = writer.outputBytes
      if case .write(_, let partial) = error { progress += partial }
      if progress > 0 {
        // Cancel any partial APC before recovery. A targeted deletion also
        // aborts a chunked upload that has not received its final chunk.
        try? writeStatic("\u{18}\u{1b}\\", to: descriptor)
        if restoreCursor && progress >= 2 { try? writeStatic("\u{1b}8", to: descriptor) }
        if let id = cancelImageID {
          var recovery = ANSIWriter()
          try? recovery.deleteKittyImage(id: id, to: self)
          try? recovery.flush(to: self)
        }
      }
      if case .write(let number, _) = error { throw .output(.write(errno: number, bytesWritten: progress)) }
      throw .output(error)
    }
    return writer.outputBytes
  }
}

extension ANSIWriter {
  fileprivate mutating func deleteKittyImage(id: UInt32, to output: borrowing Output) throws(IOError) {
    try literal("\u{1b}_Ga=d,d=I,i=", to: output)
    try unsignedNumber(id, to: output)
    try literal(",q=2\u{1b}\\", to: output)
  }
}
