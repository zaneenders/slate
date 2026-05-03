#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Clamped `ioctl(TIOCGWINSZ)` layout (both dimensions ≥ 1).
///
/// Safe from any isolation; callers that poll for resize typically invoke this off the main actor.
internal enum WinSize {
  internal static func query(maxCols: Int = 512, maxRows: Int = 512) -> (cols: Int, rows: Int) {
    ioctlStdoutWindowSize(maxCols: maxCols, maxRows: maxRows)
  }
}
