import SlateUI
import Testing

@Test func incrementalUTF8MatchesSwiftValidationForEveryTwoByteInput() {
  var input = InlineArray<2, UInt8>(repeating: 0)
  for first in UInt8.min...UInt8.max {
    for second in UInt8.min...UInt8.max {
      input[0] = first
      input[1] = second
      var decoder = IncrementalUTF8Decoder()
      var accepted = true
      for byte in input {
        if case .invalid = decoder.append(byte) {
          accepted = false
          break
        }
      }
      let valid = (try? UTF8Span(validating: input.span)) != nil
      #expect((accepted && decoder.isComplete) == valid)
    }
  }
}

@Test func incrementalUTF8PreservesScalarBoundsAndRecoversAfterInvalidContinuations() {
  let boundaries: [UInt32] = [
    0, 0x7f, 0x80, 0x7ff, 0x800, 0xd7ff, 0xe000, 0xffff,
    0x10000, 0x3ffff, 0x40000, 0xfffff, 0x100000, 0x10ffff
  ]
  for value in boundaries {
    let scalar = Unicode.Scalar(value)!
    var decoder = IncrementalUTF8Decoder()
    var decoded: Unicode.Scalar?
    UTF8.encode(scalar) { byte in
      switch decoder.append(byte) {
      case .pending: break
      case .scalar(let scalar): decoded = scalar
      case .invalid: Issue.record("Rejected a valid scalar at an encoding boundary")
      }
    }
    #expect(decoded == scalar && decoder.isComplete)
  }
  for bytes: [UInt8] in [
    [0xe0, 0x9f], [0xed, 0xa0], [0xf0, 0x8f], [0xf4, 0x90],
    [0xe1, 0x80, 0x7f], [0xf1, 0x80, 0x80, 0xc0]
  ] {
    var decoder = IncrementalUTF8Decoder()
    for byte in bytes.dropLast() { #expect(decoder.append(byte) == .pending) }
    #expect(decoder.append(bytes.last!) == .invalid)
    let complete = decoder.isComplete
    #expect(complete)
    #expect(decoder.append(0x71) == .scalar("q"))
  }
}
