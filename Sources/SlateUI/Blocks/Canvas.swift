/// A long-lived custom drawing owner. Painting is synchronous; the frame cannot
/// escape. Keep reusable storage in this owner and bound work by the frame size.
/// Canvas retains the owner only while its value or layout is in use.
public protocol CanvasDrawing: AnyObject {
  func paint(in frame: inout Frame)
}

/// Custom drawing that participates in block layout and fills its available slot.
/// Reuse a drawing owner allocated before the render loop. Optimized construction
/// and painting allocate no callback or drawing buffer. Use `frame` to constrain size.
/// Painting receives local coordinates and is skipped for empty regions or failed
/// layout. Writes are clipped; repairing an existing wide glyph may clear its
/// other half just outside the region, preserving that cell's style.
/// Painting writes explicit cell styles; a surrounding `background` remains
/// visible only where drawing leaves cells untouched.
public struct Canvas<Drawing: CanvasDrawing>: Block, ~Sendable {
  public typealias Body = Never
  private let drawing: Drawing

  public init(_ drawing: Drawing) { self.drawing = drawing }

  public borrowing func _build(into builder: inout _BlockLayout) throws(LayoutError) {
    try builder.canvas(drawing)
  }
}

/// Layout mixes unrelated drawing owners. Erase only here, retaining the
/// existing class instance with one witness call per paint and no callback box.
@usableFromInline struct CanvasPayload: ~Sendable {
  @diagnose(ExistentialType, as: ignored, reason: "Heterogeneous class owners fit inline without per-frame allocation")
  private let drawing: any CanvasDrawing

  init<Drawing: CanvasDrawing>(_ drawing: Drawing) { self.drawing = drawing }

  func paint(in frame: inout Frame) { drawing.paint(in: &frame) }
}
