# wcwidth design notes

Design notes for `wcwidth.zig` and its generator (`tools/gen/wcwidth_table.zig`). They were moved here from the end of `tools/ucd/17.0.0/PropList.txt`, which must match the copy on unicode.org byte for byte.

1. Scope & compliance target

Faithful to POSIX wcwidth(3) semantics (Kuhn/musl model), not the libc++ format.string estimation model, since the target consumer is a terminal emulator. That means: per-codepoint (not per-grapheme-cluster) classification, with an explicit zero-width category, matching what musl's wcwidth does inline for the fast path and via bitmap tables for the rest wcwidth.c:1-29 .
2. Single unified table, not two

Instead of separate "wide" and "zero-width" tables, pack a property enum + range into one sorted table entry, following the pattern libc++ uses for indic_conjunct_break_table.h (property in low bits, size next, codepoint high bits) rather than allocating two tables and running two binary searches per lookup: indic_conjunct_break_table.h:80-100

Proposed entry layout (one u32):

    bits [0,2]: property enum — .narrow, .wide, .ambiguous, .zero, .control
    bits [3, N]: range size
    bits [N+1, 31]: lower-bound codepoint

Return type from the public API: an explicit enum or small tagged value instead of the C -1/0/1/2 int sentinel — cleaner since you're not bound by C ABI.
3. Lookup: reuse std.sort, don't hand-roll binary search

libc++ hand-rolls std::ranges::upper_bound with shift/mask arithmetic for its table lookup: width_estimation_table.h:241-265

Zig already has the equivalent generic, tested primitives in std.sort — upperBound, lowerBound, partitionPoint, equalRange: sort.zig:604-616

Use std.sort.upperBound with a comparator over your packed-range struct. lib/std/debug/Dwarf.zig's findSource is a good idiomatic-Zig reference for exactly this "find range containing this value" pattern: Dwarf.zig:154-162

Keep the ASCII/control fast path inline before the table lookup (as musl does), since it covers the overwhelmingly common case and avoids the binary search entirely for wc < 0x100.
4. Table generation

    Data sources: EastAsianWidth.txt (narrow/wide/ambiguous), UnicodeData.txt or DerivedGeneralCategory.txt (Cc→control, Mn/Me/Cf→zero-width). Derive everything mechanically — don't hand-transcribe ranges the way musl hardcodes the variation-selector/tag-character ranges as literal comparisons: wcwidth.c:24-27

    Instead, follow the more maintainable approach escaped_output_table.h demonstrates — derive the table straight from DerivedGeneralCategory.txt groupings: escaped_output_table.h:80-101

    Generator: a standalone script (Python or Zig) under a tools//codegen/-style directory that parses the UCD files above and emits a single sorted, merged .zig table file. Pin the Unicode version and mark the file as generated/do-not-modify, following the convention already used for width_estimation_table.h: width_estimation_table.h:1-12

    Vendoring policy: commit the generated table file to the repo; do not invoke the generator automatically from build.zig or fetch UCD files at build time — this matches how musl/libc++'s own generated tables are vendored as plain checked-in source, with no network dependency in the build.

5. API design

    Input: u21 (Zig's codepoint convention, matching lib/std/unicode.zig's usage throughout).
    Output: explicit enum/tagged result, not a magic -1/0/1/2 int.
    Ambiguous-width configurability: expose East Asian Ambiguous handling as a parameter (treat-as-narrow vs treat-as-wide) rather than hardcoding one policy — the man page doesn't mandate a choice here, and this is a real-world pain point for CJK-locale terminal users.
    No locale dependency — ignore LC_CTYPE like every practical libc implementation does; document this as an intentional deviation from the man page's stated locale-sensitivity.

6. Performance / streaming constraints

Keep the core lookup allocation-free and O(log n) over a small static table, callable one codepoint at a time with no buffering — this is required for a terminal's tight per-character rendering loop, and is naturally satisfied by the single merged table + std.sort.upperBound approach in §2–3.

7. Secondary validation target

lib/std/zig/ErrorBundle.zig has an existing // TODO basic unicode code point monospace width gap where it currently treats every byte as one column when rendering source snippets: ErrorBundle.zig:234-240

If the API is generic enough (u21 in, width out, no allocation), it's directly reusable there — a useful sanity check that the design isn't overfit to the terminal-emulator use case alone.
8. Optional future layer (not part of core wcwidth)

If grapheme-cluster-aware width is wanted later (for correctly advancing over emoji-ZWJ sequences), implement it as a separate function (e.g. graphemeWidth) built on top of the codepoint-level wcwidth, not folded into it — keeps the core function compliant with the man page's one-codepoint-in/one-result-out contract. If/when built, reuse the shape of libc++'s __extended_grapheme_cluster_break state machine (one previous codepoint + property, explicit rule dispatch) rather than re-deriving UAX #29 rules from scratch: unicode.h:302-325
9. Testing

Pin a specific Unicode version for the generated tables and test against known fixed points: ASCII printable range, C0 controls, the null character (explicit man-page special case, width 0), a combining mark (U+0301), a CJK ideograph (U+4E2D, width 2), an East-Asian-Ambiguous character under both config modes, and at least one emoji/variation-selector case matching musl's hardcoded VS/tag ranges as a cross-check.