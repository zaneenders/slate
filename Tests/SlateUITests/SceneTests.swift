@_spi(Rendering) import SlateComposition
import SlateUI
import Testing

@Test func optionalRenderersSeeResolvedElementsWithoutOwningLayoutInternals() throws {
  var scene = _BlockScene(nodeCapacity: 8)
  let budget = scene.storageBudgetBytes
  try scene.build(in: Rect(width: 8, height: 4)) { Text("hello").padding(1).background(.blue) }
  var texts = 0
  for index in 0..<scene.count {
    let element = scene.element(at: index)
    if element.kind == .text {
      #expect(element.text == "hello" && element.style.background == .blue)
      #expect(element.region == Rect(x: 1, y: 1, width: 5, height: 1))
      texts += 1
    }
  }
  #expect(texts == 1)
  scene.reset()
  #expect(scene.count == 1 && scene.storageBudgetBytes == budget)
}

@Test func rendererScenesReleaseInputsAfterPartialBuildFailureAndReuseTheirStorage() throws {
  var scene = _BlockScene(nodeCapacity: 3)
  let budget = scene.storageBudgetBytes
  weak var retained: TextInput?
  do {
    let input = try TextInput("field")
    retained = input
    #expect(throws: LayoutError.nodeCapacityExceeded) {
      try scene.build(in: Rect(width: 8, height: 4)) {
        Column {
          InputBox(input)
          Text("overflow")
        }
      }
    }
    scene.reset()
  }
  #expect(retained == nil)
  try scene.build(in: Rect(width: 1, height: 1)) { Text("x") }
  #expect(scene.element(at: scene.count - 1).text == "x" && scene.storageBudgetBytes == budget)
  scene.reset()
}
