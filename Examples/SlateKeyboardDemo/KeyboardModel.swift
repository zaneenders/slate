import BasicContainers
import Slate

enum KeyboardMode: Int, Sendable, CaseIterable {
  case predictive, common, chords
  var title: String {
    switch self {
    case .predictive: "Flick + predict"
    case .common: "Common letters"
    case .chords: "Two-stick chords"
    }
  }
  var instruction: String {
    switch self {
    case .predictive: "Left: flick a group / Right: choose a word / Cross: accept + space"
    case .common: "Left: flick a letter / Hold R1: more groups / Right: pick a letter"
    case .chords: "Left: aim at a group / Right: flick N/E/S/W to type its letter"
    }
  }
}

enum KeyboardNotice {
  case ready, draftFull, wordFull, unknownWord, chooseGroup, invalidLetter, cancelled
  var text: String {
    switch self {
    case .ready: "Compose with the sticks. Each tab keeps its own draft."
    case .draftFull: "Draft full (512 characters). Delete before continuing."
    case .wordFull: "Word full (16 groups). Accept or delete before continuing."
    case .unknownWord: "No dictionary match. Delete a group, or try exact spelling in Chords."
    case .chooseGroup: "Aim the left stick at a group, then flick the right stick."
    case .invalidLetter: "That group has no letter in this direction."
    case .cancelled: "Pending input cancelled. Your draft is kept."
    }
  }
}

struct KeyboardDraft {
  static let capacity = 512
  private var bytes: InlineArray<512, UInt8> = .init(repeating: 0)
  var count = 0
  subscript(_ index: Int) -> UInt8 {
    precondition(index >= 0 && index < count)
    return bytes[index]
  }
  mutating func append(_ byte: UInt8) {
    precondition(count < Self.capacity && (32...126).contains(byte))
    bytes[count] = byte
    count += 1
  }
  func endsWithWord(_ word: String) -> Bool {
    var end = count
    while end > 0 && bytes[end - 1] == 32 { end -= 1 }
    let text = word.utf8Span
    guard end >= text.count else { return false }
    let start = end - text.count
    if start > 0 && bytes[start - 1] != 32 { return false }
    for index in 0..<text.count {
      let byte = bytes[start + index]
      if (65...90).contains(byte) ? byte + 32 != text.span[index] : byte != text.span[index] { return false }
    }
    return true
  }
  // Explicitly allocating test/debug snapshot, outside event and rendering paths.
  func snapshot() -> String { String(copying: unsafe UTF8Span(unchecked: bytes.span.extracting(first: count))) }
}

struct KeyboardWord {
  var text = ""
  var signature: UInt64 = 0
  var length = 0
}

/// One startup-built, ranked vocabulary shared by all three sessions. Lookup
/// visits at most 512 words and inserts into five inline candidate slots.
final class KeyboardLexicon: ~Sendable {
  static let capacity = 512
  private var words = RigidArray(repeating: KeyboardWord(), count: capacity)
  private(set) var count = 0
  var storageBudgetBytes: Int { Self.capacity * (MemoryLayout<KeyboardWord>.stride + 16) }
  subscript(_ index: Int) -> KeyboardWord {
    precondition(index >= 0 && index < count)
    return words[index]
  }
  init() {
    let source = """
      the of and to a in is it you that for on are with as i be this have from or one had by
      but what all were we when your can said there use an each which she do how their if will
      up other about out many then them these so some her would make like him into time has
      look two more write go see number no way could people my than first water been call who
      its now find long down day did get come made may part good home gone hood hello help held
      hold text test tests type typing letter letters keyboard controller game games play player
      demo english input screen focus navigation common predict prediction predictive radial stick
      joystick space back quick brown fox jumps over lazy dog slate thanks thank please yes sure
      okay great well am need want love meet later tomorrow today morning night new name code cool
      food book room soon work world words where here phone house inside nice much know learn
      change choose choice right left enjoy welcome friend friends happy run running stop start
      build built button save shift spelling exact orbit read reading send message sample try
      apple banana coffee tea cat dog hello design example open close clear small big black white
      blue green red north south east west letter word sentence english input output window tab
      optional linux macos swift computer music video photo picture search settings value zero
      over under after before again also away because between both city country even every family
      feel few hand head high keep kind last life little live man might most move must never next
      old only our own place point put same say school seem should show side since still such take
      tell think through too together turn very walk while why without woman year young
      """
    let tokens = source.split(whereSeparator: { $0 == " " || $0 == "\n" })
    precondition(tokens.count <= Self.capacity)
    for token in tokens {
      let text = String(token)
      let bytes = text.utf8Span
      precondition((1...16).contains(bytes.count))
      // Duplicate fixture words don't consume capacity or appear twice.
      var duplicate = false
      for index in 0..<count where words[index].text == text {
        duplicate = true
        break
      }
      if duplicate { continue }
      var signature: UInt64 = 0
      for index in 0..<bytes.count {
        signature |= UInt64(Self.group(for: bytes.span[index]) + 2) << (index * 4)
      }
      words[count] = .init(text: text, signature: signature, length: bytes.count)
      count += 1
    }
  }
  static func group(for byte: UInt8) -> Int {
    switch byte {
    case 97...99: 0
    case 100...102: 1
    case 103...105: 2
    case 106...108: 3
    case 109...111: 4
    case 112...115: 5
    case 116...118: 6
    case 119...122: 7
    default: preconditionFailure("The demo vocabulary contains only lowercase ASCII")
    }
  }
}

/// All mutable text/candidate storage is inline and retains its fixed capacity.
/// Owners have shared identity so drawing can borrow the active tab's state.
final class KeyboardSession: ~Sendable {
  let mode: KeyboardMode
  let lexicon: KeyboardLexicon
  var draft = KeyboardDraft()
  private(set) var tokens: InlineArray<16, UInt8> = .init(repeating: 0)
  private(set) var tokenCount = 0
  private var candidates: InlineArray<5, Int> = .init(repeating: -1)
  private var scores: InlineArray<5, Int> = .init(repeating: 0)
  private(set) var candidateCount = 0
  var selectedCandidate = 0
  var selectedGroup: Int?
  var leftPreview: Int?
  var rightPreview: Int?
  var latchedGroup: Int?
  var moreLetters = false
  var capitals = false
  var notice = KeyboardNotice.ready

  init(mode: KeyboardMode, lexicon: KeyboardLexicon) {
    self.mode = mode
    self.lexicon = lexicon
  }
  var inlineStorageBudgetBytes: Int {
    MemoryLayout<KeyboardDraft>.stride + MemoryLayout<InlineArray<16, UInt8>>.stride
      + 2 * MemoryLayout<InlineArray<5, Int>>.stride
  }
  func candidate(_ index: Int) -> String {
    guard index >= 0 && index < candidateCount else { return "" }
    return lexicon[candidates[index]].text
  }
  var preview: String { candidate(selectedCandidate) }

  func addGroup(_ sector: Int) {
    precondition((0..<8).contains(sector))
    guard tokenCount < 16 else {
      notice = .wordFull
      return
    }
    tokens[tokenCount] = UInt8(sector + 2)
    tokenCount += 1
    refine()
  }
  func type(_ byte: UInt8) {
    guard draft.count < KeyboardDraft.capacity else {
      notice = .draftFull
      return
    }
    draft.append(cased(byte))
    notice = .ready
  }
  func cased(_ byte: UInt8) -> UInt8 { capitals && (97...122).contains(byte) ? byte - 32 : byte }
  func moveCandidate(_ delta: Int) {
    guard candidateCount > 0 else { return }
    selectedCandidate = max(0, min(candidateCount - 1, selectedCandidate + delta))
  }
  func delete() {
    if tokenCount > 0 {
      tokenCount -= 1
      refine()
    } else if draft.count > 0 {
      draft.count -= 1
      notice = .ready
    }
  }
  func cancel() {
    tokenCount = 0
    candidateCount = 0
    selectedCandidate = 0
    selectedGroup = nil
    notice = .cancelled
  }
  func finish(period: Bool = false) {
    guard tokenCount == 0 || candidateCount > 0 else {
      notice = .unknownWord
      return
    }
    let word = tokenCount > 0 ? candidate(selectedCandidate) : ""
    let bytes = word.utf8Span
    var base = draft.count
    if period && tokenCount == 0 { while base > 0 && draft[base - 1] == 32 { base -= 1 } }
    guard base + bytes.count + (period ? 2 : 1) <= KeyboardDraft.capacity else {
      notice = .draftFull
      return
    }
    draft.count = base
    for index in 0..<bytes.count { draft.append(cased(bytes.span[index])) }
    if period { draft.append(46) }
    draft.append(32)
    tokenCount = 0
    candidateCount = 0
    selectedCandidate = 0
    notice = .ready
  }

  private func refine() {
    candidateCount = 0
    selectedCandidate = 0
    guard tokenCount > 0 else {
      notice = .ready
      return
    }
    var signature: UInt64 = 0
    for index in 0..<tokenCount { signature |= UInt64(tokens[index]) << (index * 4) }
    let mask: UInt64 = tokenCount == 16 ? .max : (UInt64(1) << (tokenCount * 4)) - 1
    let afterGo = draft.endsWithWord("go")
    let afterI = draft.endsWithWord("i")
    let afterThank = draft.endsWithWord("thank")
    let afterGood = draft.endsWithWord("good")
    for index in 0..<lexicon.count {
      let word = lexicon[index]
      guard word.length >= tokenCount && word.signature & mask == signature else { continue }
      var score = index + (word.length == tokenCount ? 0 : 1024)
      if afterGo && (word.text == "home" || word.text == "to")
        || afterI && (word.text == "am" || word.text == "have" || word.text == "need")
        || afterThank && word.text == "you"
        || afterGood && (word.text == "morning" || word.text == "night")
      {
        score -= 2048
      }
      var slot = 0
      while slot < candidateCount && scores[slot] <= score { slot += 1 }
      guard slot < 5 else { continue }
      let last = min(candidateCount, 4)
      if slot < last {
        for target in stride(from: last, through: slot + 1, by: -1) {
          candidates[target] = candidates[target - 1]
          scores[target] = scores[target - 1]
        }
      }
      candidates[slot] = index
      scores[slot] = score
      candidateCount = min(5, candidateCount + 1)
    }
    notice = candidateCount == 0 ? .unknownWord : .ready
  }
}
