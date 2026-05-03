#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Poll stdin for readability with a millisecond timeout.
///
/// Returns `true` if input is ready, `false` on timeout or error.
internal func pollStdin(timeoutMs: Int) -> Bool {
  var fds = pollfd()
  fds.fd = STDIN_FILENO
  fds.events = Int16(POLLIN)
  let ret = unsafe poll(&fds, 1, Int32(timeoutMs))
  return ret > 0 && (fds.revents & Int16(POLLIN)) != 0
}
