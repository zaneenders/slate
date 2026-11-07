/// Roots-style sizing, measured in whole terminal cells.
public enum LayoutSize: Equatable, Sendable {
  case fit
  case fill
  case fixed(Int)

  func measured(_ content: Int) -> Int {
    if case .fixed(let value) = self { return value }
    return content
  }

  func resolved(_ content: Int, available: Int) -> Int {
    switch self {
    case .fit: return min(content, available)
    case .fill: return available
    case .fixed(let value): return min(value, available)
    }
  }
}

public enum Alignment: Sendable {
  case topLeading, center, leading, trailing, bottomTrailing

  func offset(available: Int, content: Int, horizontal: Bool) -> Int {
    let remainder = max(0, available - content)
    switch self {
    case .topLeading: return 0
    case .center: return remainder / 2
    case .leading: return horizontal ? 0 : remainder / 2
    case .trailing: return horizontal ? remainder : remainder / 2
    case .bottomTrailing: return remainder
    }
  }
}

public enum LayoutLimits {
  public static let maximumNodes = 512
  public static let maximumDepth = 32
  public static let maximumTextScalars = 4_096
}

public enum LayoutError: Error, Equatable, Sendable {
  case nodeCapacityExceeded
  case depthExceeded
  case textTooLong
}

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

  // Inline these small factories so opaque results specialize in client code.
  // Their @usableFromInline storage stays inaccessible to normal source imports.
  @inlinable public func frame(
    width: LayoutSize = .fit, height: LayoutSize = .fit,
    alignment: Alignment = .center
  ) -> some Block {
    Framed(content: self, width: width, height: height, alignment: alignment)
  }

  @inlinable public func padding(_ cells: Int) -> some Block {
    padding(horizontal: cells, vertical: cells)
  }

  @inlinable public func padding(horizontal: Int = 0, vertical: Int = 0) -> some Block {
    precondition((0...65_535).contains(horizontal) && (0...65_535).contains(vertical))
    return Padded(content: self, horizontal: horizontal, vertical: vertical)
  }

  @inlinable public func border(_ title: String = "", style: Style = Style()) -> some Block {
    Bordered(content: self, title: title, style: style)
  }

  @inlinable public func background(_ color: Color) -> some Block { Background(content: self, color: color) }
}

extension Block where Body == Never {
  public var body: Never { fatalError("Primitive blocks build directly") }
}

extension Never: Block {
  public typealias Body = Never
  public borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {}
}

@resultBuilder
public enum BlockBuilder {
  @inlinable public static func buildBlock() -> some Block { EmptyBlock() }
  public static func buildExpression<B: Block>(_ block: B) -> B { block }
  public static func buildPartialBlock<B: Block>(first: B) -> B { first }
  @inlinable public static func buildPartialBlock<A: Block, B: Block>(accumulated: A, next: B) -> some Block {
    BlockPair(first: accumulated, next: next)
  }
  public static func buildEither<A: Block, B: Block>(first: A) -> _ConditionalBlock<A, B> { .init(first: first) }
  public static func buildEither<A: Block, B: Block>(second: B) -> _ConditionalBlock<A, B> { .init(second: second) }
  @inlinable public static func buildOptional<B: Block>(_ block: B?) -> some Block { OptionalBlock(content: block) }
}

@usableFromInline struct EmptyBlock: Block {
  @usableFromInline typealias Body = Never
  @usableFromInline init() {}
  @usableFromInline borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {}
}

@usableFromInline struct BlockPair<A: Block, B: Block>: Block {
  @usableFromInline typealias Body = Never
  let first: A
  let next: B
  @usableFromInline init(first: A, next: B) {
    self.first = first
    self.next = next
  }
  @usableFromInline borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    try first._build(into: &builder)
    try next._build(into: &builder)
  }
}

/// Compiler support for `if`/`else` in `BlockBuilder`; use conditional syntax.
/// Both builder overloads must return the same named generic type so Swift can
/// infer the opposite branch. Its constructors and storage stay internal.
public struct _ConditionalBlock<A: Block, B: Block>: Block {
  public typealias Body = Never
  private enum Storage {
    case first(A)
    case second(B)
  }
  private let storage: Storage

  init(first: A) { storage = .first(first) }
  init(second: B) { storage = .second(second) }

  public borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    let storage = storage
    switch storage {
    case .first(let block): try block._build(into: &builder)
    case .second(let block): try block._build(into: &builder)
    }
  }
}

@usableFromInline struct OptionalBlock<Content: Block>: Block {
  @usableFromInline typealias Body = Never
  let content: Content?
  @usableFromInline init(content: Content?) { self.content = content }
  @usableFromInline borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    try content?._build(into: &builder)
  }
}

public struct Text: Block {
  public typealias Body = Never
  let content: String
  let style: Style
  public init(_ content: String, style: Style = Style()) {
    self.content = content
    self.style = style
  }
  public borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    try builder.text(content, style: style)
  }
}

public struct Row<Content: Block>: Block {
  public typealias Body = Never
  let gap: Int
  let alignment: Alignment
  let content: Content
  public init(gap: Int = 0, alignment: Alignment = .topLeading, @BlockBuilder content: () -> Content) {
    precondition((0...65_535).contains(gap))
    self.gap = gap
    self.alignment = alignment
    self.content = content()
  }
  public borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    let parent = try builder.begin(LayoutNode(kind: .row, alignment: alignment, gap: gap))
    defer { builder.end(parent) }
    try content._build(into: &builder)
  }
}

public struct Column<Content: Block>: Block {
  public typealias Body = Never
  let gap: Int
  let alignment: Alignment
  let content: Content
  public init(gap: Int = 0, alignment: Alignment = .topLeading, @BlockBuilder content: () -> Content) {
    precondition((0...65_535).contains(gap))
    self.gap = gap
    self.alignment = alignment
    self.content = content()
  }
  public borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    let parent = try builder.begin(LayoutNode(kind: .column, alignment: alignment, gap: gap))
    defer { builder.end(parent) }
    try content._build(into: &builder)
  }
}

@usableFromInline struct Framed<Content: Block>: Block {
  @usableFromInline typealias Body = Never
  let content: Content
  let width: LayoutSize
  let height: LayoutSize
  let alignment: Alignment

  @usableFromInline init(content: Content, width: LayoutSize, height: LayoutSize, alignment: Alignment) {
    if case .fixed(let cells) = width { precondition((0...65_535).contains(cells)) }
    if case .fixed(let cells) = height { precondition((0...65_535).contains(cells)) }
    self.content = content
    self.width = width
    self.height = height
    self.alignment = alignment
  }

  @usableFromInline borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    let parent = try builder.begin(LayoutNode(kind: .frame, width: width, height: height, alignment: alignment))
    defer { builder.end(parent) }
    try content._build(into: &builder)
  }
}

@usableFromInline struct Padded<Content: Block>: Block {
  @usableFromInline typealias Body = Never
  let content: Content
  let horizontal: Int
  let vertical: Int
  @usableFromInline init(content: Content, horizontal: Int, vertical: Int) {
    self.content = content
    self.horizontal = horizontal
    self.vertical = vertical
  }
  @usableFromInline borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    let parent = try builder.begin(LayoutNode(kind: .padding, horizontalPadding: horizontal, verticalPadding: vertical))
    defer { builder.end(parent) }
    try content._build(into: &builder)
  }
}

@usableFromInline struct Bordered<Content: Block>: Block {
  @usableFromInline typealias Body = Never
  let content: Content
  let title: String
  let style: Style
  @usableFromInline init(content: Content, title: String, style: Style) {
    self.content = content
    self.title = title
    self.style = style
  }
  @usableFromInline borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    try builder.validateText(title)
    let parent = try builder.begin(
      LayoutNode(
        kind: .border, text: title, style: style,
        horizontalPadding: 1, verticalPadding: 1))
    defer { builder.end(parent) }
    try content._build(into: &builder)
  }
}

@usableFromInline struct Background<Content: Block>: Block {
  @usableFromInline typealias Body = Never
  let content: Content
  let color: Color
  @usableFromInline init(content: Content, color: Color) {
    self.content = content
    self.color = color
  }
  @usableFromInline borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    let parent = try builder.begin(LayoutNode(kind: .background, style: Style(background: color)))
    defer { builder.end(parent) }
    try content._build(into: &builder)
  }
}
