import SlateUI
import Testing

@Test func controlKeysCoverOnlyC0Bytes() {
  for byte in UInt8.min...UInt8.max {
    #expect((ControlKey(rawValue: byte) != nil) == (byte < 0x20))
  }
  // These control bytes have dedicated InputKey cases in the decoder.
  #expect(ControlKey.h.rawValue == 0x08)
  #expect(ControlKey.i.rawValue == 0x09)
  #expect(ControlKey.j.rawValue == 0x0a)
  #expect(ControlKey.m.rawValue == 0x0d)
  #expect(ControlKey.leftBracket.rawValue == 0x1b)
}

@Test func functionKeysCoverOnlyDocumentedNumbers() {
  let keys: [FunctionKey] = [
    .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12,
    .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20, .f21, .f22, .f23, .f24,
    .f25, .f26, .f27, .f28, .f29, .f30, .f31, .f32, .f33, .f34, .f35
  ]
  for (index, key) in keys.enumerated() {
    #expect(key.rawValue == UInt8(index + 1))
    #expect(FunctionKey(rawValue: UInt8(index + 1)) == key)
  }
  for byte in UInt8.min...UInt8.max {
    #expect((FunctionKey(rawValue: byte) != nil) == (1...35).contains(byte))
  }
}
