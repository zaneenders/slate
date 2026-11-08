`EastAsianWidth.txt` is the unmodified Unicode 18.0.0 data file from
https://www.unicode.org/Public/18.0.0/ucd/EastAsianWidth.txt.
Its license is in `../Unicode-LICENSE.txt`.

`UnicodeWidthPlugin` runs `Tools/UnicodeWidthGenerator` when this input or the
generator changes, or when its output is missing. SwiftPM compiles the generated
`UnicodeWidth.swift` into `SlateComposition` from the plugin's build directory.
Builds need no network access for Unicode data. Do not check in generated Swift.

The generator retains only wide (`W`) and fullwidth (`F`) ranges and merges
adjacent ranges. Ambiguous characters stay one column. Updating Unicode requires
replacing this file and changing the generator's version check and output header
together, then checking the Unicode tests.

Generation is a one-shot build operation and may allocate temporary strings and
collections. Input reads are capped at 1 MiB plus one overflow-detection byte;
invalid UTF-8, a wrong version, malformed/unordered records, empty wide data, or
more than 1,024 merged wide ranges fail the build before writing output. The
range array reserves 1,024 entries, and output reserves 64 KiB (at most 1,024
case lines under 48 bytes each plus the fixed header/footer). These bounds do
not include Foundation or parser temporary allocation overhead. At runtime the
generated switch needs no heap table, input parsing, or file access.
