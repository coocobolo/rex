//! Classifies decoded Unicode codepoints for terminal-style word selection.
//!
//! The classifier applies a terminal word selection policy rather than Unicode
//! word-boundary rules. ASCII alphanumerics, underscores, and configured extra
//! characters are treated as words. Spaces and tabs act as blank boundaries,
//! while newlines and carriage returns form line boundaries. Other ASCII controls
//! follow the configured control policy, remaining ASCII characters are treated
//! as punctuation, and non-ASCII codepoints follow the non-ASCII policy.
//!
//! Extra word characters currently support ASCII codepoints only. Input must be
//! decoded from UTF-8 into valid Unicode scalar values before classification.

const std = @import("std");

/// The broad category used for terminal word selection.
pub const Kind = enum {
    /// A space or tab. These act as selection boundaries.
    blank,

    /// A character that belongs to a word.
    word,

    /// Punctuation or another ASCII character that is not part of a word character.
    punctuation,

    /// A line terminator. Newlines never join another character.
    newline,

    /// A non-newline control character. Controls never join another character.
    control,
};

pub const JoinOption = struct {
    /// Whether adjacent blank characters can join during selection.
    ///
    /// When false, spaces and tabs are boundaries. When true, a consecutive
    /// run of spaces and tabs can be selected.
    select_blank_runs: bool = false,

    /// Whether punctuation must have the same codepoint to join.
    ///
    /// When true, '(' joins only '(', and ')' joins only ')'.
    /// When false, all punctuation belongs to one joinable class.
    punctuation_must_match: bool = true,
};

/// Classification result for one decoded Unicode codepoint.
pub const CharClass = struct {
    kind: Kind,

    /// The original codepoint. This is used so punctuation can be compared
    /// by character rather than treating all punctuation as one class.
    cp: u21,

    /// Returns whether `other` can be joined to this character during selection expansion.
    pub fn canJoin(
        self: CharClass,
        other: CharClass,
        option: JoinOption,
    ) bool {
        return switch (self.kind) {
            .word => other.kind == .word,
            .blank => option.select_blank_runs and other.kind == .blank,
            .punctuation => blk: {
                if (other.kind != .punctuation) break :blk false;
                if (!option.punctuation_must_match) break :blk true;
                break :blk self.cp == other.cp;
            },
            .newline, .control => false,
        };
    }
};

/// Controls how non-ASCII codepoints are classified.
pub const NonAsciiPolicy = enum {
    /// Treat every non-ASCII code point as a word character.
    word,

    /// Treat every non-ASCII code point as punctuation.
    punctuation,
};

/// Controls how ASCII control characters are classified.
pub const ControlPolicy = enum {
    /// Classify controls as `.control`. They act as boundaries.
    boundary,

    /// Classify controls as `.punctuation`.
    punctuation,
};

pub const Option = struct {
    /// Additional ASCII characters treated as word characters.
    ///
    /// Common examples include ['-', '.', '/', '~', ':', '@'].
    ///
    /// This slice must contain ASCII bytes only. It is borrowed only during
    /// initialization and is not retained by the classifier.
    extra_word_chars: []const u8 = "",

    join: JoinOption = .{},

    /// Classification policy for non-ASCII codepoints.
    non_ascii: NonAsciiPolicy = .word,

    /// Classification policy for ASCII control characters other than
    /// newline and carriage return.
    control: ControlPolicy = .boundary,
};

const Classifier = @This();

/// Classification table for all ASCII code points.
ascii_kind: [128]Kind,

/// Configuration controlling joining behavior and non-ASCII handling.
option: Option,

/// A classifier using the default configuration.
pub const empty = Classifier.init(.{}) catch unreachable;

/// Errors that can occur while constructing a classifier.
pub const InitError = error{ExtraWordCharacterNotAscii};

/// Constructs a classifier from `Option`.
///
/// `extra_word_chars` must contain ASCII bytes only. A UTF-8 string
/// containing non-ASCII characters is not valid for this field because
/// its bytes are not individual ASCII characters.
pub fn init(option: Option) InitError!Classifier {
    var classifier: Classifier = .{ .ascii_kind = @splat(Kind.punctuation), .option = option };

    for (&classifier.ascii_kind, 0..) |*kind, i| {
        const cp: u8 = @intCast(i);

        if (std.ascii.isAlphanumeric(cp) or cp == '_') {
            kind.* = .word;
        } else if (cp == ' ' or cp == '\t') {
            kind.* = .blank;
        } else if (cp == '\n' or cp == '\r') {
            kind.* = .newline;
        } else if (cp < 32 or cp == 127) {
            kind.* = switch (option.control) {
                .boundary => .control,
                .punctuation => .punctuation,
            };
        }
    }

    // Apply configured additional word characters.
    for (option.extra_word_chars) |cp| {
        if (cp >= 128) return error.ExtraWordCharacterNotAscii;

        // Whitespace and line boundaries cannot be overridden.
        if (cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r') {
            continue;
        }

        // Do not allow control characters to become word characters.
        if (cp < 32 or cp == 127) {
            continue;
        }

        classifier.ascii_kind[cp] = .word;
    }

    return classifier;
}

/// Classifies one decoded Unicode code point.
pub inline fn classify(self: *const Classifier, cp: u21) CharClass {
    if (cp < 128) {
        @branchHint(.likely);
        return .{
            .kind = self.ascii_kind[@intCast(cp)],
            .cp = cp,
        };
    } else {
        @branchHint(.unlikely);
        // Non-ASCII is classified by policy alone, not by Unicode
        // properties.
        return .{
            .kind = switch (self.option.non_ascii) {
                .word => .word,
                .punctuation => .punctuation,
            },
            .cp = cp,
        };
    }
}

const testing = std.testing;

test "Classifier: default ASCII classification" {
    const classifier = try Classifier.init(.{});

    try testing.expectEqual(Kind.word, classifier.classify('a').kind);
    try testing.expectEqual(Kind.word, classifier.classify('Z').kind);
    try testing.expectEqual(Kind.word, classifier.classify('7').kind);
    try testing.expectEqual(Kind.word, classifier.classify('_').kind);

    try testing.expectEqual(Kind.blank, classifier.classify(' ').kind);
    try testing.expectEqual(Kind.blank, classifier.classify('\t').kind);

    try testing.expectEqual(Kind.newline, classifier.classify('\n').kind);
    try testing.expectEqual(Kind.newline, classifier.classify('\r').kind);

    try testing.expectEqual(Kind.punctuation, classifier.classify('!').kind);

    try testing.expectEqual(Kind.punctuation, classifier.classify('(').kind);
}

test "Classifier: default word characters join" {
    const option: Option = .{};
    const classifier = try Classifier.init(option);

    const letter = classifier.classify('a');
    const digit = classifier.classify('7');
    const underscore = classifier.classify('_');
    const punctuation = classifier.classify('.');
    const blank = classifier.classify(' ');

    const join_option: JoinOption = .{
        .select_blank_runs = option.join.select_blank_runs,
        .punctuation_must_match = option.join.punctuation_must_match,
    };
    try testing.expect(letter.canJoin(digit, join_option));
    try testing.expect(letter.canJoin(underscore, join_option));
    try testing.expect(underscore.canJoin(letter, join_option));

    try testing.expect(!letter.canJoin(punctuation, join_option));
    try testing.expect(!letter.canJoin(blank, join_option));
}

test "Classifier: extra ASCII characters become word characters" {
    const classifier = try Classifier.init(.{
        .extra_word_chars = "-./~:@",
    });

    try testing.expectEqual(Kind.word, classifier.classify('-').kind);
    try testing.expectEqual(Kind.word, classifier.classify('.').kind);
    try testing.expectEqual(Kind.word, classifier.classify('/').kind);
    try testing.expectEqual(Kind.word, classifier.classify('~').kind);
    try testing.expectEqual(Kind.word, classifier.classify(':').kind);
    try testing.expectEqual(Kind.word, classifier.classify('@').kind);

    // Characters not included in the configuration remain punctuation.
    try testing.expectEqual(Kind.punctuation, classifier.classify('!').kind);
}

test "Classifier: extra word characters join word characters" {
    const option: Option = .{ .extra_word_chars = "-./" };
    const classifier = try Classifier.init(option);

    const hyphen = classifier.classify('-');
    const dot = classifier.classify('.');
    const slash = classifier.classify('/');
    const letter = classifier.classify('a');
    const join_option: JoinOption = .{
        .select_blank_runs = option.join.select_blank_runs,
        .punctuation_must_match = option.join.punctuation_must_match,
    };

    try testing.expect(hyphen.canJoin(letter, join_option));
    try testing.expect(dot.canJoin(slash, join_option));
    try testing.expect(slash.canJoin(letter, join_option));
}

test "Classifier: whitespace cannot be overridden" {
    const classifier = try Classifier.init(.{
        .extra_word_chars = " \t\n\r",
    });

    try testing.expectEqual(Kind.blank, classifier.classify(' ').kind);
    try testing.expectEqual(Kind.blank, classifier.classify('\t').kind);
    try testing.expectEqual(Kind.newline, classifier.classify('\n').kind);
    try testing.expectEqual(Kind.newline, classifier.classify('\r').kind);
}

test "Classifier: rejects non-ASCII extra word characters" {
    const invalid_chars = [_]u8{
        0x80,
        0x81,
        0xA0,
        0xFF,
    };

    for (invalid_chars) |char| {
        const extra_word_chars = [_]u8{char};

        try testing.expectError(
            InitError.ExtraWordCharacterNotAscii,
            Classifier.init(.{
                .extra_word_chars = &extra_word_chars,
            }),
        );
    }
}

test "Classifier: punctuation only joins identical punctuation by default" {
    const option: Option = .{};
    const classifier = try Classifier.init(option);

    const left_paren = classifier.classify('(');
    const another_left_paren = classifier.classify('(');
    const right_paren = classifier.classify(')');
    const period = classifier.classify('.');

    const join_option: JoinOption = .{
        .select_blank_runs = option.join.select_blank_runs,
        .punctuation_must_match = option.join.punctuation_must_match,
    };
    try testing.expect(left_paren.canJoin(another_left_paren, join_option));
    try testing.expect(!left_paren.canJoin(right_paren, join_option));
    try testing.expect(!left_paren.canJoin(period, join_option));
}

test "Classifier: punctuation can join regardless of character" {
    const option: Option = .{
        .join = .{ .punctuation_must_match = false },
    };
    const classifier = try Classifier.init(option);

    const left_paren = classifier.classify('(');
    const right_paren = classifier.classify(')');
    const period = classifier.classify('.');

    const join_option: JoinOption = .{
        .select_blank_runs = option.join.select_blank_runs,
        .punctuation_must_match = option.join.punctuation_must_match,
    };
    try testing.expect(left_paren.canJoin(right_paren, join_option));
    try testing.expect(right_paren.canJoin(period, join_option));
}

test "Classifier: blank characters do not join by default" {
    const option: Option = .{};
    const classifier = try Classifier.init(option);

    const space = classifier.classify(' ');
    const tab = classifier.classify('\t');

    const join_option: JoinOption = .{
        .select_blank_runs = option.join.select_blank_runs,
        .punctuation_must_match = option.join.punctuation_must_match,
    };
    try testing.expect(!space.canJoin(space, join_option));
    try testing.expect(!space.canJoin(tab, join_option));
    try testing.expect(!tab.canJoin(space, join_option));
}

test "Classifier: blank runs can be enabled" {
    const option: Option = .{
        .join = .{ .select_blank_runs = true },
    };
    const classifier = try Classifier.init(option);

    const space = classifier.classify(' ');
    const tab = classifier.classify('\t');
    const letter = classifier.classify('a');

    const join_option: JoinOption = .{
        .select_blank_runs = option.join.select_blank_runs,
        .punctuation_must_match = option.join.punctuation_must_match,
    };
    try testing.expect(space.canJoin(space, join_option));
    try testing.expect(space.canJoin(tab, join_option));
    try testing.expect(tab.canJoin(space, join_option));

    try testing.expect(!space.canJoin(letter, join_option));
    try testing.expect(!letter.canJoin(space, join_option));
}

test "Classifier: newlines never join" {
    const option: Option = .{
        .join = .{ .select_blank_runs = true },
    };
    const classifier = try Classifier.init(option);

    const newline = classifier.classify('\n');
    const carriage_return = classifier.classify('\r');
    const space = classifier.classify(' ');
    const letter = classifier.classify('a');

    try testing.expectEqual(Kind.newline, newline.kind);
    try testing.expectEqual(Kind.newline, carriage_return.kind);

    const join_option: JoinOption = .{
        .select_blank_runs = option.join.select_blank_runs,
        .punctuation_must_match = option.join.punctuation_must_match,
    };
    try testing.expect(!newline.canJoin(newline, join_option));
    try testing.expect(!newline.canJoin(carriage_return, join_option));
    try testing.expect(!newline.canJoin(space, join_option));
    try testing.expect(!newline.canJoin(letter, join_option));
}

test "Classifier: control characters are boundaries by default" {
    const option: Option = .{};
    const classifier = try Classifier.init(option);

    const control = classifier.classify(0x01);
    const delete = classifier.classify(0x7f);
    const letter = classifier.classify('a');

    try testing.expectEqual(Kind.control, control.kind);
    try testing.expectEqual(Kind.control, delete.kind);

    const join_option: JoinOption = .{
        .select_blank_runs = option.join.select_blank_runs,
        .punctuation_must_match = option.join.punctuation_must_match,
    };
    try testing.expect(!control.canJoin(control, join_option));
    try testing.expect(!control.canJoin(letter, join_option));
    try testing.expect(!delete.canJoin(delete, join_option));
}

test "Classifier: control characters can be classified as punctuation" {
    const option: Option = .{ .control = .punctuation };
    const classifier = try Classifier.init(option);

    const control = classifier.classify(0x01);
    const delete = classifier.classify(0x7f);
    const another_control = classifier.classify(0x01);
    const letter = classifier.classify('a');

    const join_option: JoinOption = .{
        .select_blank_runs = option.join.select_blank_runs,
        .punctuation_must_match = option.join.punctuation_must_match,
    };

    // Different punctuation characters do not join when exact matching
    // is enabled.
    try testing.expect(!control.canJoin(delete, join_option));

    // Identical punctuation characters do join.
    try testing.expect(control.canJoin(another_control, join_option));

    // Punctuation does not join a word.
    try testing.expect(!control.canJoin(letter, join_option));
}

test "Classifier: punctuation controls can join as one class" {
    const option: Option = .{
        .control = .punctuation,
        .join = .{ .punctuation_must_match = false },
    };

    const classifier = try Classifier.init(option);

    const control = classifier.classify(0x01);
    const delete = classifier.classify(0x7f);
    const letter = classifier.classify('a');

    try testing.expectEqual(Kind.punctuation, control.kind);
    try testing.expectEqual(Kind.punctuation, delete.kind);

    const join_option: JoinOption = .{
        .select_blank_runs = option.join.select_blank_runs,
        .punctuation_must_match = option.join.punctuation_must_match,
    };

    try testing.expect(control.canJoin(delete, join_option));
    try testing.expect(!control.canJoin(letter, join_option));
}

test "Classifier: non-ASCII code points are words by default" {
    const classifier = try Classifier.init(.{});

    try testing.expectEqual(Kind.word, classifier.classify('é').kind);
    try testing.expectEqual(Kind.word, classifier.classify('中').kind);
    try testing.expectEqual(Kind.word, classifier.classify('🙂').kind);
}

test "Classifier: non-ASCII code points can be punctuation" {
    const classifier = try Classifier.init(.{ .non_ascii = .punctuation });

    try testing.expectEqual(
        Kind.punctuation,
        classifier.classify('é').kind,
    );

    try testing.expectEqual(
        Kind.punctuation,
        classifier.classify('中').kind,
    );

    try testing.expectEqual(
        Kind.punctuation,
        classifier.classify('🙂').kind,
    );
}

test "Classifier: non-ASCII punctuation obeys punctuation matching" {
    const option: Option = .{
        .join = .{ .punctuation_must_match = true },
        .non_ascii = .punctuation,
    };

    const classifier = try Classifier.init(option);

    const accented_e = classifier.classify('é');
    const chinese = classifier.classify('中');
    const another_accented_e = classifier.classify('é');

    const join_option: JoinOption = .{
        .select_blank_runs = option.join.select_blank_runs,
        .punctuation_must_match = option.join.punctuation_must_match,
    };

    try testing.expect(accented_e.canJoin(another_accented_e, join_option));
    try testing.expect(!accented_e.canJoin(chinese, join_option));
}
