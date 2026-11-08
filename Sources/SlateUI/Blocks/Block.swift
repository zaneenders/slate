/// Compose blocks through `body`; no view hierarchy is retained.
/// Underscored requirements support rendering and are not extension points.
public protocol Block {
  associatedtype Body: Block
  @BlockBuilder var body: Body { get }
  // A public protocol requires a public witness. Preserve generic dispatch
  // without casting or boxing each block to an internal protocol.
  borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError)
}

extension Block {
  public borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    try body._build(into: &builder)
  }
}

extension Block where Body == Never {
  public var body: Never { fatalError("Primitive blocks build directly") }
}

extension Never: Block {
  public typealias Body = Never
  public borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {}
}
