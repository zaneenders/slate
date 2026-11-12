extension Block {
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

  /// Positions a layer's top-left corner in parent-local terminal cells. The
  /// content is sized first, then its common origin is clamped inside the parent.
  /// Intended for Overlay: this wrapper fills its allocated layout slot. It adds
  /// one layout node and shares the existing cell grid. Coordinates are 0...65,535.
  @inlinable public func position(column: Int, row: Int) -> some Block {
    Positioned(content: self, column: column, row: row)
  }
}

@usableFromInline struct Positioned<Content: Block>: Block, ~Sendable {
  @usableFromInline typealias Body = Never
  let content: Content
  let column: UInt16
  let row: UInt16

  @usableFromInline init(content: Content, column: Int, row: Int) {
    precondition((0...65_535).contains(column) && (0...65_535).contains(row))
    self.content = content
    self.column = UInt16(column)
    self.row = UInt16(row)
  }

  @usableFromInline borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    let parent = try builder.begin(
      LayoutNode(kind: .positioned, positionColumn: column, positionRow: row, width: .fill, height: .fill))
    defer { builder.end(parent) }
    try content._build(into: &builder)
  }
}

@usableFromInline struct Framed<Content: Block>: Block, ~Sendable {
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

@usableFromInline struct Padded<Content: Block>: Block, ~Sendable {
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

@usableFromInline struct Bordered<Content: Block>: Block, ~Sendable {
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

@usableFromInline struct Background<Content: Block>: Block, ~Sendable {
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
