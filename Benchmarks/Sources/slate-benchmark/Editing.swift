import AllocationProbe
import Glibc
import SlateTerminal

func runEditingAllocations() throws {
  let descriptor = unsafe open("/dev/null", O_WRONLY | O_CLOEXEC)
  precondition(descriptor >= 0)
  defer { _ = close(descriptor) }
  let output = try Output(fileDescriptor: descriptor)
  let input = try TextInput(capacity: TextInput.maximumCapacity)
  let payload = String(repeating: "e\u{301}", count: 21_845) + "x"
  let family = String(repeating: "👨‍👩‍👧‍👦", count: 2_000)
  let emojiPayload = family + String(repeating: "x", count: 65_536 - family.utf8.count)
  let oversized = String(repeating: "x", count: 65_537)
  var clipboard = Clipboard()
  var screen = try Screen(maximumSize: TerminalSize(columns: 80, rows: 1))
  let fields = Array(repeating: InputBox(input), count: LayoutLimits.maximumNodes - 1)
  for round in 0..<136 {
    if round == 8 { cli_probe_begin() }
    input.selectAll()
    try input.insert((round.isMultiple(of: 2) ? payload : emojiPayload).utf8Span)
    precondition(input.byteCount == 65_536)
    precondition(input.handle(.left, modifiers: .shift, clipboard: &clipboard) == .changed)
    precondition(input.handle(.control(.a), clipboard: &clipboard) == .changed)
    precondition(input.handle(.control(.c), clipboard: &clipboard) == .changed)
    try clipboard.flush(to: output)
    do {
      try input.insert(oversized.utf8Span)
      preconditionFailure("Accepted oversized edit")
    } catch { precondition(error == .capacityExceeded) }
    do {
      try input.insert("\u{1b}".utf8Span)
      preconditionFailure("Accepted control")
    } catch { precondition(error == .invalidControl) }
    try screen.draw(size: screen.maximumSize, to: output) { InputBox(input) }
    try screen.draw(size: screen.maximumSize, to: output) {
      Column { BlockList(fields.dropLast()) }
    }
    do {
      try screen.draw(size: screen.maximumSize, to: output) { Column { BlockList(fields[...]) } }
      preconditionFailure("Accepted excessive input nodes")
    } catch { precondition(error == .layout(.nodeCapacityExceeded)) }
    precondition(input.handle(.control(.x), clipboard: &clipboard) == .changed)
    precondition(input.byteCount == 0)
    try clipboard.flush(to: output)
  }
  let allocations = cli_probe_end()
  print("Editing 128 maximum text/copy/cut/draw/rejection cycles: \(allocations) allocations")
  precondition(allocations == 0)
}
