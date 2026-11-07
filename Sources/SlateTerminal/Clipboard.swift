public import SlateUI

extension Clipboard {
  /// Encodes a pending copy as OSC 52. Scratch storage is a bounded 4 KiB inline
  /// buffer in this synchronous call; no heap storage or tasks are created.
  public mutating func flush(to output: borrowing Output) throws(IOError) {
    try flush { (text: UTF8Span) throws(IOError) in
      var writer = ANSIWriter()
      do throws(IOError) {
        try writer.literal("\u{1b}]52;c;", to: output)
        try writer.base64(text.span, to: output)
        try writer.literal("\u{1b}\\", to: output)
        try writer.flush(to: output)
      } catch {
        // A partial OSC must not swallow subsequent frame or restoration bytes.
        try? writeStatic("\u{18}\u{1b}\\", to: output.descriptor)
        if case .write(let number, let bytesWritten) = error {
          throw .write(errno: number, bytesWritten: writer.outputBytes + bytesWritten)
        }
        throw error
      }
    }
  }
}
