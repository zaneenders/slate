extension Block {
  // Inline these small factories so opaque results specialize in client code.
  // Their @usableFromInline storage stays inaccessible to normal source imports.
  @inlinable public func frame(
    width: LayoutSize = .fit, height: LayoutSize = .fit,
    alignment: Alignment = .center
  ) -> some Block {
    if case .fixed(let cells) = width { precondition((0...65_535).contains(cells)) }
    if case .fixed(let cells) = height { precondition((0...65_535).contains(cells)) }
    return ModifiedBlock(content: self, decoration: .frame(width, height, alignment))
  }

  @inlinable public func padding(_ cells: Int) -> some Block {
    padding(horizontal: cells, vertical: cells)
  }

  @inlinable public func padding(horizontal: Int = 0, vertical: Int = 0) -> some Block {
    precondition((0...65_535).contains(horizontal) && (0...65_535).contains(vertical))
    return ModifiedBlock(content: self, decoration: .padding(horizontal, vertical))
  }

  @inlinable public func border(_ title: String = "", style: Style = Style()) -> some Block {
    ModifiedBlock(content: self, decoration: .border(title, style))
  }

  @inlinable public func background(_ color: Color) -> some Block {
    ModifiedBlock(content: self, decoration: .background(color))
  }

  /// Positions a layer's top-left corner in parent-local terminal cells. The
  /// content is sized first, then its common origin is clamped inside the parent.
  /// Intended for Overlay: this wrapper fills its allocated layout slot. It adds
  /// one layout node and shares the existing cell grid. Coordinates are 0...65,535.
  @inlinable public func position(column: Int, row: Int) -> some Block {
    precondition((0...65_535).contains(column) && (0...65_535).contains(row))
    return ModifiedBlock(content: self, decoration: .position(UInt16(column), UInt16(row)))
  }
}

// Store only the modifier payload; full layout nodes belong to the frame's
// existing storage rather than every value in a composed block chain.
@usableFromInline enum BlockDecoration: Sendable {
  case frame(LayoutSize, LayoutSize, Alignment)
  case padding(Int, Int)
  case border(String, Style)
  case background(Color)
  case position(UInt16, UInt16)
}

@usableFromInline struct ModifiedBlock<Content: Block>: Block, ~Sendable {
  @usableFromInline typealias Body = Never
  let content: Content
  let decoration: BlockDecoration

  @usableFromInline init(content: Content, decoration: BlockDecoration) {
    self.content = content
    self.decoration = decoration
  }

  @usableFromInline borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    let node: LayoutNode
    switch decoration {
    case .frame(let width, let height, let alignment):
      node = LayoutNode(kind: .frame, width: width, height: height, alignment: alignment)
    case .padding(let horizontal, let vertical):
      node = LayoutNode(kind: .padding, horizontalPadding: horizontal, verticalPadding: vertical)
    case .border(let title, let style):
      try builder.validateText(title)
      node = LayoutNode(kind: .border, text: title, style: style, horizontalPadding: 1, verticalPadding: 1)
    case .background(let color):
      node = LayoutNode(kind: .background, style: Style(background: color))
    case .position(let column, let row):
      node = LayoutNode(kind: .positioned, positionColumn: column, positionRow: row, width: .fill, height: .fill)
    }
    let parent = try builder.begin(node)
    defer { builder.end(parent) }
    try builder.build(content)
  }
}
