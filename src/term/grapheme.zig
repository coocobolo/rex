//! Unicode TR29 grapheme cluster break detector.
//! Zig port of libcxx __extended_grapheme_cluster_break (unicode.h).
//! GB9c (Indic conjunct break) is intentionally omitted.

const std = @import("std");
const table = @import("grapheme_table.zig");
const Property = table.Property;


/// Stateful grapheme cluster break detector.
///
/// Usage:
///   var gb = GraphemeBreaker.init(first_cp);
///   for (rest_cps) |cp| {
///       if (gb.isBreak(cp)) {
///           // cluster boundary before cp
///       }
///   }
pub const Breaker = struct {
    prev_prop: ?Property,
    rule: Rule = .none,
    gb11_state: Gb11State = .extended_pictographic,

    const Rule = enum { none, gb11_emoji, gb12_gb13_ri };
    const Gb11State = enum {
        extended_pictographic, // saw an Extended_Pictographic
        extend, // saw Extend* after it
        zwj, // saw ZWJ after Extend*
    };

    /// Initialize with the first codepoint of the stream.
    /// The first codepoint never has a break before it.
    pub fn init(first_cp: u21) Breaker {
        const prop = table.getProperty(first_cp);
        var gb: Breaker = .{ .prev_prop = prop };
        if (prop == .extended_pictographic) gb.rule = .gb11_emoji;
        if (prop == .regional_indicator) gb.rule = .gb12_gb13_ri;
        return gb;
    }

    /// Returns true if there is a grapheme cluster break break BEFORE `codepoint (cp)`
    /// Call this for every codepoint after the first.
    pub fn isBreak(self: *Breaker, cp: u21) bool {
        const next_prop = table.getProperty(cp);
        const breaks = switch (self.rule) {
            .none => self.evalNone(next_prop),
            .gb11_emoji => self.evalGb11(next_prop),
            .gb12_gb13_ri => self.evalGb12(next_prop),
        };
        self.prev_prop = next_prop;
        return breaks;
    }

    fn evalNone(self: *Breaker, next: ?Property) bool {
        const prev = self.prev_prop;

        // GB3: CR x LF
        if (prev == .cr and next == .lf) return false;
        // GB4: (Control|CR|LF) ÷
        if (prev == .control or prev == .cr or prev == .lf) return true;
        // GB5: ÷ (Control|CR|LF)
        if (next == .control or next == .cr or next == .lf) return true;

        // GB6: Hangul syllable sequences
        if (prev == .l and (next == .l or next == .v or next == .lv or next == .lvt)) return false;
        if ((prev == .lv or prev == .v) and (next == .v or next == .t)) return false;
        if ((prev == .lvt or prev == .t) and next == .t) return false;

        // GB9: × (Extend | ZWJ)
        if (next == .extend or next == .zwj) return false;
        // GB9a: × SpacingMakr
        if (next == .spacing_mark) return false;
        // GB9b: Prepend ×
        if (prev == .prepend) return false;

        // GB11: enter emoji state
        if (next == .extended_pictographic) {
            self.rule = .gb11_emoji;
            self.gb11_state = .extended_pictographic;
            return true;
        }

        // GB12: enter RI state
        if (next == .regional_indicator) {
            self.rule = .gb12_gb13_ri;
            return true;
        }
        return true; // GBB999
    }

    fn evalGb11(self: *Breaker, next: ?Property) bool {
        switch (self.gb11_state) {
            .extended_pictographic, .extend => {
                if (next == .extend) {
                    self.gb11_state = .extend;
                    return false;
                }

                if (next == .zwj) {
                    self.gb11_state = .zwj;
                    return false;
                }

                // not extend or zwj, fallback to normal rule
                self.rule = .none;
                return self.evalNone(next);
            },
            .zwj => {
                if (next == .extended_pictographic) {
                    // GB11: WZJ x Extended_Pictographic, no break
                    self.gb11_state = .extended_pictographic;
                    return false;
                }
                self.rule = .none;
                return self.evalNone(next);
            },
        }
    }

    fn evalGb12(self: *Breaker, next: ?Property) bool {
        self.rule = .none;
        if (next == .regional_indicator) return false;
        return self.evalNone(next);
    }
};
