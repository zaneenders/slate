import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

package struct ScreenCapture: ~Copyable {
  package let descriptor: Int32

  package init() throws {
    var template = Array("/tmp/slate-screen-XXXXXX".utf8CString)
    let descriptor = unsafe mkstemp(&template)
    try #require(descriptor >= 0)
    _ = unsafe unlink(template)
    let status = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    if status != 0 { _ = close(descriptor) }
    try #require(status == 0)
    self.descriptor = descriptor
  }

  package func take() throws -> [UInt8] {
    let count = lseek(descriptor, 0, SEEK_END)
    try #require(count >= 0 && count <= 1_048_576)
    try #require(lseek(descriptor, 0, SEEK_SET) == 0)
    var bytes = [UInt8](repeating: 0, count: Int(count))
    try bytes.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let readCount = unsafe read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        try #require(readCount > 0)
        offset += readCount
      }
    }
    try #require(ftruncate(descriptor, 0) == 0 && lseek(descriptor, 0, SEEK_SET) == 0)
    return bytes
  }

  deinit { _ = close(descriptor) }
}
