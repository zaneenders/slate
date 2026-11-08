import BasicContainers
import SlateComposition

extension LayoutTree {
  borrowing func paint(into frame: inout Frame) {
    for index in 0..<count {
      let node = nodes[index]
      var style = node.style
      if style.background == .default { style.background = node.inheritedBackground }
      switch node.kind {
      case .input:
        inputs[Int(node.inputIndex)]!.paint(
          in: node.region, frame: &frame, focused: node.focused, placeholder: node.text, style: style)
      case .text: frame.text(node.text, in: node.region, style: style)
      case .border: frame.border(node.region, title: node.text, style: style)
      case .background: frame.fill(node.region, with: Cell(style: node.style))
      default: break
      }
    }
  }
}
