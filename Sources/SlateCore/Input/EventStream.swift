#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Bridges POSIX `poll()`/`read()` into Swift Concurrency via `AsyncStream<KeyEvent>`.
public struct EventStream: ~Copyable {
  public init() {}

  /// Returns an ``AsyncStream`` of ``KeyEvent`` values parsed from stdin.
  ///
  /// The stream owns a detached producer task that polls stdin (~60fps) and yields
  /// parsed events.  The task is automatically cancelled when the stream terminates.
  public func start() -> AsyncStream<KeyEvent> {
    let (stream, continuation) = AsyncStream<KeyEvent>.makeStream()
    let task = Task.detached {
      var parser = EscapeParser()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while !Task.isCancelled {
        if pollStdin(timeoutMs: 16) {
          let n = unsafe read(STDIN_FILENO, &buffer, buffer.count)
          if n < 0 {
            if errno == EINTR {
              continue
            }
            // EOF or unrecoverable error
            continuation.finish()
            return
          }
          if n > 0 {
            for i in 0..<n {
              let events = parser.feed(buffer[i])
              for event in events {
                continuation.yield(event)
              }
            }
          }
        }
      }
    }
    continuation.onTermination = { _ in
      task.cancel()
    }
    return stream
  }
}
