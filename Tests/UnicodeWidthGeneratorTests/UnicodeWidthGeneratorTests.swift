import Testing

@testable import UnicodeWidthGenerator

private let header = "# EastAsianWidth-18.0.0.txt\n"

@Test func unicodeWidthGeneratorMergesWideRangesAndPreservesGaps() throws {
  let output = try UnicodeWidthGenerator.generate(
    header + """
      0041 ; Na # narrow
      00A1 ; A # ambiguous stays narrow
      1100..115F ; W
      1160 ; F # adjacent fullwidth range merges
      1161 ; N
      1162 ; H
      1163 ; W
      10FFFF ; F
      """
  )
  #expect(output.contains("case 0x1100...0x1160: return true\n"))
  #expect(output.contains("case 0x1163: return true\n"))
  #expect(output.contains("case 0x10ffff: return true\n"))
  #expect(output.split(separator: "\n").filter { $0.contains("case ") }.count == 3)
  #expect(output.hasSuffix("    default: return false\n    }\n  }\n}\n"))
}

@Test func unicodeWidthGeneratorRejectsWrongVersionsAndMalformedData() {
  for input in [
    "", "# EastAsianWidth-17.0.0.txt\n1100 ; W\n", header,
    header + "0041 ; Na\n", header + "1100\n", header + "1100 ; W ; F\n",
    header + "1100 ; unknown\n", header + "not-hex ; W\n",
    header + "1100..1000 ; W\n", header + "1100..115F..1160 ; W\n",
    header + "110000 ; W\n", header + "FFFFFFFF ; W\n",
    header + "1100..115F ; W\n115F ; F\n",
    header + "1100 ; W\n0041 ; Na\n"
  ] {
    #expect(throws: GenerationError.self) { try UnicodeWidthGenerator.generate(input) }
  }
}

@Test func unicodeWidthGeneratorBoundsInputBytes() throws {
  var input = header + "1100 ; W\n#"
  input += String(repeating: "x", count: UnicodeWidthGenerator.maximumInputBytes - input.utf8.count)
  let output = try UnicodeWidthGenerator.generate(input)
  #expect(output.contains("case 0x1100: return true\n"))
  input += "x"
  #expect(throws: GenerationError.self) { try UnicodeWidthGenerator.generate(input) }
}

@Test func unicodeWidthGeneratorBoundsDisjointRangesAndMergesAtCapacity() throws {
  var input = header
  for index in 0..<UnicodeWidthGenerator.maximumRanges {
    input += String(index * 2, radix: 16) + " ; W\n"
  }
  let output = try UnicodeWidthGenerator.generate(input)
  #expect(output.split(separator: "\n").filter { $0.contains("case ") }.count == UnicodeWidthGenerator.maximumRanges)
  #expect(output.utf8.count < 65_536)
  // Extending the last range needs no additional capacity.
  input += String(UnicodeWidthGenerator.maximumRanges * 2 - 1, radix: 16) + " ; F\n"
  #expect(try UnicodeWidthGenerator.generate(input).contains("case 0x7fe...0x7ff: return true\n"))
  input += String(UnicodeWidthGenerator.maximumRanges * 2 + 1, radix: 16) + " ; W\n"
  #expect(throws: GenerationError.self) { try UnicodeWidthGenerator.generate(input) }
}
