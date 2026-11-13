@resultBuilder
public enum BlockBuilder: Sendable {
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

@usableFromInline struct EmptyBlock: Block, Sendable {
  @usableFromInline typealias Body = Never
  @usableFromInline init() {}
  @usableFromInline borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {}
}

@usableFromInline struct BlockPair<A: Block, B: Block>: Block, ~Sendable {
  @usableFromInline typealias Body = Never
  let first: A
  let next: B
  @usableFromInline init(first: A, next: B) {
    self.first = first
    self.next = next
  }
  @usableFromInline borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    try builder.build(first)
    try builder.build(next)
  }
}

/// Compiler support for `if`/`else` in `BlockBuilder`; use conditional syntax.
/// Both builder overloads must return the same named generic type so Swift can
/// infer the opposite branch. Its constructors and storage stay internal.
public struct _ConditionalBlock<A: Block, B: Block>: Block, ~Sendable {
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
    case .first(let block): try builder.build(block)
    case .second(let block): try builder.build(block)
    }
  }
}

@usableFromInline struct OptionalBlock<Content: Block>: Block, ~Sendable {
  @usableFromInline typealias Body = Never
  let content: Content?
  @usableFromInline init(content: Content?) { self.content = content }
  @usableFromInline borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    if let content { try builder.build(content) }
  }
}
