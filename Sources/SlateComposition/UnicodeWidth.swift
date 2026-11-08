// Unicode 18.0.0 W/F ranges. Copyright © 1991-2026 Unicode, Inc.; see Unicode-LICENSE.txt.
// https://www.unicode.org/Public/18.0.0/ucd/EastAsianWidth.txt
// Range comments show endpoint characters; names identify invisible or unsupported characters.

/// Allocation-free lookup of East Asian Wide (W) and Fullwidth (F) scalar ranges.
/// Ambiguous (A) scalars stay narrow; `Glyph` handles combining marks and emoji presentation.
enum UnicodeWidth {
  static func isWide(_ value: UInt32) -> Bool {
    switch value {
    // Hangul leading consonants.
    case 0x1100...0x115f:  // ᄀ … HANGUL CHOSEONG FILLER
      return true

    // Wide symbols and emoji in the Basic Multilingual Plane.
    case 0x231a...0x231b,  // ⌚ … ⌛
      0x2329...0x232a,  // 〈 … 〉
      0x23e9...0x23ec,  // ⏩ … ⏬
      0x23f0,  // ⏰
      0x23f3,  // ⏳
      0x25fd...0x25fe,  // ◽ … ◾
      0x2614...0x2615,  // ☔ … ☕
      0x2630...0x2637,  // ☰ … ☷
      0x2648...0x2653,  // ♈ … ♓
      0x267f,  // ♿
      0x268a...0x268f,  // ⚊ … ⚏
      0x2693,  // ⚓
      0x26a1,  // ⚡
      0x26aa...0x26ab,  // ⚪ … ⚫
      0x26bd...0x26be,  // ⚽ … ⚾
      0x26c4...0x26c5,  // ⛄ … ⛅
      0x26ce,  // ⛎
      0x26d4,  // ⛔
      0x26ea,  // ⛪
      0x26f2...0x26f3,  // ⛲ … ⛳
      0x26f5,  // ⛵
      0x26fa,  // ⛺
      0x26fd,  // ⛽
      0x2705,  // ✅
      0x270a...0x270b,  // ✊ … ✋
      0x2728,  // ✨
      0x274c,  // ❌
      0x274e,  // ❎
      0x2753...0x2755,  // ❓ … ❕
      0x2757,  // ❗
      0x2795...0x2797,  // ➕ … ➗
      0x27b0,  // ➰
      0x27bf,  // ➿
      0x2b1b...0x2b1c,  // ⬛ … ⬜
      0x2b50,  // ⭐
      0x2b55:  // ⭕
      return true

    // CJK radicals, punctuation, kana, Bopomofo, compatibility forms, ideographs, and Yi.
    case 0x2e80...0x2e99,  // ⺀ … ⺙
      0x2e9b...0x2ef3,  // ⺛ … ⻳
      0x2f00...0x2fd5,  // ⼀ … ⿕
      0x2ff0...0x303e,  // ⿰ … 〾
      0x3041...0x3096,  // ぁ … ゖ
      0x3099...0x30ff,  // COMBINING KATAKANA-HIRAGANA VOICED SOUND MARK … ヿ
      0x3105...0x312f,  // ㄅ … ㄯ
      0x3131...0x318e,  // ㄱ … ㆎ
      0x3190...0x31e5,  // ㆐ … ㇥
      0x31ef...0x321e,  // ㇯ … ㈞
      0x3220...0x3247,  // ㈠ … ㉇
      0x3250...0xa48c,  // ㉐ … ꒌ
      0xa490...0xa4c6:  // ꒐ … ꓆
      return true

    // Hangul extended leading consonants and precomposed syllables.
    case 0xa960...0xa97c,  // ꥠ … ꥼ
      0xac00...0xd7a3:  // 가 … 힣
      return true

    // CJK compatibility ideographs.
    case 0xf900...0xfaff:  // 豈 … reserved U+FAFF
      return true

    // Vertical punctuation, small forms, and fullwidth characters.
    case 0xfe10...0xfe19,  // ︐ … ︙
      0xfe30...0xfe52,  // ︰ … ﹒
      0xfe54...0xfe66,  // ﹔ … ﹦
      0xfe68...0xfe6b,  // ﹨ … ﹫
      0xff01...0xff60,  // ！ … ｠
      0xffe0...0xffe6:  // ￠ … ￦
      return true

    // Supplementary East Asian scripts and ideographic symbols.
    case 0x16fe0...0x16fe4,  // 𖿠 … KHITAN SMALL SCRIPT FILLER
      0x16ff0...0x16ff6,  // VIETNAMESE ALTERNATE READING MARK CA … 𖿶
      0x17000...0x18cda,  // 𗀀 … 𘳚 (KHITAN SMALL SCRIPT CHARACTER-18CDA)
      0x18cff...0x18d20,  // 𘳿 … 𘴠 (TANGUT IDEOGRAPH-18D20)
      0x18d80...0x18df2,  // 𘶀 … 𘷲
      0x18e00...0x19191,  // 𘸀 (JURCHEN CHARACTER-18E00) … 𙆑 (JURCHEN CHARACTER-19191)
      0x191a0...0x191d2:  // 𙆠 (JURCHEN RADICAL-01) … 𙇒 (JURCHEN RADICAL-51)
      return true

    // Supplementary kana and Nushu.
    case 0x1aff0...0x1aff3,  // 𚿰 … 𚿳
      0x1aff5...0x1affb,  // 𚿵 … 𚿻
      0x1affd...0x1affe,  // 𚿽 … 𚿾
      0x1b000...0x1b128,  // 𛀀 … 𛄨 (KATAKANA LETTER ALTERNATE WI)
      0x1b132,  // 𛄲
      0x1b150...0x1b152,  // 𛅐 … 𛅒
      0x1b155,  // 𛅕
      0x1b164...0x1b168,  // 𛅤 … 𛅨 (KATAKANA LETTER SMALL ARCHAIC YE)
      0x1b170...0x1b2fb:  // 𛅰 … 𛋻
      return true

    // Tai Xuan Jing symbols and counting rods.
    case 0x1d300...0x1d356,  // 𝌀 … 𝍖
      0x1d360...0x1d376:  // 𝍠 … 𝍶
      return true

    // Supplementary wide pictographs, enclosed symbols, and emoji.
    case 0x1f004,  // 🀄
      0x1f0cf,  // 🃏
      0x1f18e,  // 🆎
      0x1f191...0x1f19a,  // 🆑 … 🆚
      0x1f1ae,  // 🆮 (TOMOBIKI SYMBOL)
      0x1f200...0x1f202,  // 🈀 … 🈂
      0x1f210...0x1f23b,  // 🈐 … 🈻
      0x1f240...0x1f248,  // 🉀 … 🉈
      0x1f250...0x1f251,  // 🉐 … 🉑
      0x1f260...0x1f265,  // 🉠 … 🉥
      0x1f300...0x1f320,  // 🌀 … 🌠
      0x1f32d...0x1f335,  // 🌭 … 🌵
      0x1f337...0x1f37c,  // 🌷 … 🍼
      0x1f37e...0x1f393,  // 🍾 … 🎓
      0x1f3a0...0x1f3ca,  // 🎠 … 🏊
      0x1f3cf...0x1f3d3,  // 🏏 … 🏓
      0x1f3e0...0x1f3f0,  // 🏠 … 🏰
      0x1f3f4,  // 🏴
      0x1f3f8...0x1f43e,  // 🏸 … 🐾
      0x1f440,  // 👀
      0x1f442...0x1f4fc,  // 👂 … 📼
      0x1f4ff...0x1f53d,  // 📿 … 🔽
      0x1f54b...0x1f54e,  // 🕋 … 🕎
      0x1f550...0x1f567,  // 🕐 … 🕧
      0x1f57a,  // 🕺
      0x1f595...0x1f596,  // 🖕 … 🖖
      0x1f5a4,  // 🖤
      0x1f5fb...0x1f64f,  // 🗻 … 🙏
      0x1f680...0x1f6c5,  // 🚀 … 🛅
      0x1f6cc,  // 🛌
      0x1f6d0...0x1f6d2,  // 🛐 … 🛒
      0x1f6d5...0x1f6d9,  // 🛕 … 🛙 (LIGHTHOUSE)
      0x1f6dc...0x1f6df,  // 🛜 … 🛟
      0x1f6eb...0x1f6ec,  // 🛫 … 🛬
      0x1f6f4...0x1f6fc,  // 🛴 … 🛼
      0x1f7da,  // 🟚 (BLACK CIRCLE WITH WHITE VERTICAL BAR)
      0x1f7e0...0x1f7eb,  // 🟠 … 🟫
      0x1f7f0,  // 🟰
      0x1f90c...0x1f93a,  // 🤌 … 🤺
      0x1f93c...0x1f945,  // 🤼 … 🥅
      0x1f947...0x1f9ff,  // 🥇 … 🧿
      0x1fa70...0x1fa7c,  // 🩰 … 🩼
      0x1fa80...0x1fac6,  // 🪀 … 🫆
      0x1fac8,  // 🫈
      0x1facc...0x1fadd,  // 🫌 (MONARCH BUTTERFLY) … 🫝 (PICKLE)
      0x1fadf...0x1faeb,  // 🫟 … 🫫 (CRACKING FACE)
      0x1faef...0x1fafa:  // 🫯 … 🫺 (RIGHTWARDS THUMB SIGN)
      return true

    // CJK extensions, including code points reserved as wide in planes 2 and 3.
    case 0x20000...0x2fffd,  // 𠀀 … reserved U+2FFFD
      0x30000...0x3fffd:  // 𰀀 … reserved U+3FFFD
      return true

    default:
      return false
    }
  }
}
