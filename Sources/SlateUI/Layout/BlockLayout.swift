import BasicContainers

// Optimized presenters need the metadata for Surface's fixed generic storage.
// Keep it ABI-visible while layout nodes remain internal to SlateUI.
@usableFromInline struct LayoutNode: Sendable {
  enum Kind: Sendable { case root, row, column, frame, padding, border, background, text, input }
  var kind: Kind = .root
  // These fit alongside kind before the next 8-byte-aligned field. Field
  // references live in a separate fixed array so ordinary nodes stay compact.
  var inputIndex: UInt16 = 0
  var focused = false
  var width: LayoutSize = .fit
  var height: LayoutSize = .fit
  var alignment: Alignment = .topLeading
  var gap: Int = 0
  var text: String = ""
  var style = Style()
  var inheritedBackground: Color = .default
  var horizontalPadding: Int = 0
  var verticalPadding: Int = 0
  var firstChild: Int = -1
  var lastChild: Int = -1
  var nextSibling: Int = -1
  var measuredWidth: Int = 0
  var measuredHeight: Int = 0
  var region = Rect(width: 0, height: 0)
}

/// Compiler support for block rendering. Custom blocks compose through `body`.
/// Public only because it appears in the protocol's underscored rendering hook;
/// storage and mutation remain module-internal and frame-scoped.
public struct _BlockLayout: ~Copyable, ~Escapable, ~Sendable {
  private var nodes: MutableSpan<LayoutNode>
  private var inputs: MutableSpan<TextInput?>
  private var inputCount = 0
  private var parent = 0
  private var depth = 0
  private(set) var count = 1

  @_lifetime(copy nodes, copy inputs)
  init(nodes: consuming MutableSpan<LayoutNode>, inputs: consuming MutableSpan<TextInput?>) {
    precondition(nodes.count > 0)
    precondition(inputs.count == nodes.count)
    self.nodes = consume nodes
    self.inputs = consume inputs
  }

  mutating func begin(_ node: LayoutNode) throws(LayoutError) -> Int {
    guard depth < LayoutLimits.maximumDepth else { throw .depthExceeded }
    let previous = parent
    parent = try append(node)
    depth += 1
    return previous
  }

  mutating func end(_ previous: Int) {
    precondition(depth > 0 && previous >= 0 && previous < count)
    depth -= 1
    parent = previous
  }

  private mutating func append(_ node: LayoutNode) throws(LayoutError) -> Int {
    guard count < nodes.count else { throw .nodeCapacityExceeded }
    let index = count
    nodes[index] = node
    let last = nodes[parent].lastChild
    if last >= 0 { nodes[last].nextSibling = index } else { nodes[parent].firstChild = index }
    nodes[parent].lastChild = index
    count += 1
    return index
  }

  func validateText(_ text: borrowing String) throws(LayoutError) {
    var count = 0
    for _ in text.unicodeScalars {
      guard count < LayoutLimits.maximumTextScalars else { throw .textTooLong }
      count += 1
    }
  }

  mutating func inputBox(_ input: TextInput, focused: Bool, placeholder: String, style: Style) throws(LayoutError) {
    try validateText(placeholder)
    _ = try append(
      LayoutNode(
        kind: .input, inputIndex: UInt16(inputCount), focused: focused,
        width: .fill, text: placeholder, style: style, measuredWidth: 12, measuredHeight: 1))
    precondition(inputCount < inputs.count)
    inputs[inputCount] = input
    inputCount += 1
  }

  mutating func text(_ text: String, style: Style) throws(LayoutError) {
    var width = 0
    var maximumWidth = 0
    var height = 1
    var count = 0
    var clusters = UnicodeGraphemeBuffer()
    for scalar in text.unicodeScalars {
      guard count < LayoutLimits.maximumTextScalars else { throw .textTooLong }
      count += 1
      if let cluster = clusters.append(scalar, at: count) {
        if cluster.firstScalar == "\n" || cluster.firstScalar == "\r" {
          maximumWidth = max(maximumWidth, width)
          width = 0
          height += 1
        } else {
          width += cluster.glyph.columnWidth
        }
      }
    }
    if let cluster = clusters.take() {
      if cluster.firstScalar == "\n" || cluster.firstScalar == "\r" {
        maximumWidth = max(maximumWidth, width)
        width = 0
        height += 1
      } else {
        width += cluster.glyph.columnWidth
      }
    }
    _ = try append(
      LayoutNode(
        kind: .text, text: text, style: style,
        measuredWidth: max(maximumWidth, width), measuredHeight: height))
  }
}

struct LayoutTree: ~Copyable {
  private(set) var nodes: RigidArray<LayoutNode>
  private(set) var inputs: RigidArray<TextInput?>
  private(set) var count = 1

  init(capacity: Int) {
    nodes = RigidArray(repeating: LayoutNode(), count: capacity)
    inputs = RigidArray(repeating: nil, count: capacity)
  }

  /// The surface resets after painting or failure; this records every initialized
  /// node even on a throw.
  mutating func build<Content: Block>(
    in area: Rect, @BlockBuilder content: () -> Content
  ) throws(LayoutError) {
    precondition(count == 1)
    do {
      var builder = _BlockLayout(nodes: nodes.mutableSpan, inputs: inputs.mutableSpan)
      defer { count = builder.count }
      try content()._build(into: &builder)
    }
    resolve(in: area)
  }

  mutating func reset() {
    // Also clears partially built trees after a build error, releasing caller text.
    for index in 0..<count { nodes[index] = LayoutNode() }
    // A contiguous prefix is populated, including a partially failed build.
    // The common no-input frame examines just the first empty slot.
    for index in 0..<inputs.count {
      guard inputs[index] != nil else { break }
      inputs[index] = nil
    }
    count = 1
  }

  private mutating func resolve(in area: Rect) {
    for index in (0..<count).reversed() {
      let node = nodes[index]
      if node.kind == .text || node.kind == .input { continue }
      var child = node.firstChild
      var width = 0
      var height = 0
      var childCount = 0
      while child >= 0 {
        let next = nodes[child]
        if node.kind == .row {
          width += next.measuredWidth
          height = max(height, next.measuredHeight)
        } else if node.kind == .column {
          width = max(width, next.measuredWidth)
          height += next.measuredHeight
        } else {
          width = max(width, next.measuredWidth)
          height = max(height, next.measuredHeight)
        }
        childCount += 1
        child = next.nextSibling
      }
      if node.kind == .row { width += max(0, childCount - 1) * node.gap }
      if node.kind == .column { height += max(0, childCount - 1) * node.gap }
      nodes[index].measuredWidth = node.width.measured(min(65_535, width + 2 * node.horizontalPadding))
      nodes[index].measuredHeight = node.height.measured(min(65_535, height + 2 * node.verticalPadding))
    }
    nodes[0].region = area
    for index in 0..<count {
      let node = nodes[index]
      if node.kind == .row || node.kind == .column {
        placeChildren(of: index)
      } else {
        let inner = node.region.inset(horizontal: node.horizontalPadding, vertical: node.verticalPadding)
        var child = node.firstChild
        while child >= 0 {
          nodes[child].inheritedBackground = node.kind == .background ? node.style.background : node.inheritedBackground
          place(
            child, in: inner, alignment: node.alignment,
            expandContainers: node.kind != .text)
          child = nodes[child].nextSibling
        }
      }
    }
  }

  private mutating func place(_ index: Int, in slot: Rect, alignment: Alignment, expandContainers: Bool) {
    let node = nodes[index]
    let expand = expandContainers && node.kind != .text && node.kind != .input
    let width =
      expand && node.width == .fit ? slot.width : node.width.resolved(node.measuredWidth, available: slot.width)
    let height =
      expand && node.height == .fit ? slot.height : node.height.resolved(node.measuredHeight, available: slot.height)
    nodes[index].region = Rect(
      x: slot.x + alignment.offset(available: slot.width, content: width, horizontal: true),
      y: slot.y + alignment.offset(available: slot.height, content: height, horizontal: false),
      width: width, height: height)
  }

  private mutating func placeChildren(of index: Int) {
    let node = nodes[index]
    let horizontal = node.kind == .row
    let available = horizontal ? node.region.width : node.region.height
    var child = node.firstChild
    var reserved = 0
    var fills = 0
    var children = 0
    while child >= 0 {
      let next = nodes[child]
      let mode = horizontal ? next.width : next.height
      if mode == .fill { fills += 1 } else { reserved += horizontal ? next.measuredWidth : next.measuredHeight }
      children += 1
      child = next.nextSibling
    }
    let gaps = max(0, children - 1) * node.gap
    let remainder = max(0, available - gaps - reserved)
    let share = fills == 0 ? 0 : remainder / fills
    var extras = fills == 0 ? 0 : remainder % fills
    var position = node.alignment.offset(
      available: available,
      content: reserved + gaps + (fills == 0 ? 0 : remainder), horizontal: horizontal)
    child = node.firstChild
    while child >= 0 {
      let next = nodes[child]
      let mode = horizontal ? next.width : next.height
      let measured = horizontal ? next.measuredWidth : next.measuredHeight
      var length = measured
      if mode == .fill {
        length = share + (extras > 0 ? 1 : 0)
        extras = max(0, extras - 1)
      }
      let start = min(position, available)
      length = min(length, available - start)
      let slot =
        horizontal
        ? Rect(x: node.region.x + start, y: node.region.y, width: length, height: node.region.height)
        : Rect(x: node.region.x, y: node.region.y + start, width: node.region.width, height: length)
      nodes[child].inheritedBackground = node.inheritedBackground
      place(child, in: slot, alignment: node.alignment, expandContainers: true)
      // The main axis belongs to the slot; .fill shares are already resolved.
      if horizontal {
        nodes[child].region = Rect(
          x: slot.x, y: nodes[child].region.y,
          width: slot.width, height: nodes[child].region.height)
      } else {
        nodes[child].region = Rect(
          x: nodes[child].region.x, y: slot.y,
          width: nodes[child].region.width, height: slot.height)
      }
      position += length + node.gap
      child = next.nextSibling
    }
  }

}
