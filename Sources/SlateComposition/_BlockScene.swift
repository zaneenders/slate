import BasicContainers

/// Experimental renderer boundary. Layout storage stays private to composition;
/// optional renderers receive resolved, read-only paint elements.
@_spi(Rendering) public struct _BlockScene: ~Copyable, ~Sendable {
  private var layout: LayoutTree
  private let nodeCapacity: Int

  public init(nodeCapacity: Int) {
    precondition((1...LayoutLimits.maximumNodes).contains(nodeCapacity))
    self.nodeCapacity = nodeCapacity
    layout = LayoutTree(capacity: nodeCapacity)
  }

  public var count: Int { layout.count }
  public var storageBudgetBytes: Int {
    nodeCapacity * (MemoryLayout<LayoutNode>.stride + MemoryLayout<TextInput?>.stride) + MemoryLayout<Self>.stride
  }

  /// Caller resets after painting, including failures, to release text and inputs.
  public mutating func build<Content: Block>(
    in area: Rect, @BlockBuilder content: () -> Content
  ) throws(LayoutError) {
    try layout.build(in: area, content: content)
  }

  public mutating func reset() { layout.reset() }

  public borrowing func element(at index: Int) -> _PaintElement {
    precondition((0..<layout.count).contains(index))
    let node = layout.nodes[index]
    let kind: _PaintElement.Kind
    switch node.kind {
    case .text: kind = .text
    case .input: kind = .input
    case .border: kind = .border
    case .background: kind = .background
    default: kind = .none
    }
    var style = node.style
    if style.background == .default { style.background = node.inheritedBackground }
    return _PaintElement(kind: kind, region: node.region, text: node.text, style: style)
  }
}

/// Value snapshot of one resolved element. Retained snapshots are caller-owned;
/// renderers normally consume each synchronously before resetting their scene.
@_spi(Rendering) public struct _PaintElement: Sendable {
  public enum Kind: Sendable { case none, text, input, border, background }
  public let kind: Kind
  public let region: Rect
  public let text: String
  public let style: Style
}
