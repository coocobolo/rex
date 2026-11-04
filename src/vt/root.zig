//! VT parser: a byte-stream state machine that calls a handler for
//! print, execute, ESC, CSI, OSC and DCS events.

const std = @import("std");

pub const parser = @import("parser.zig");
pub const Parser = parser.Parser;
pub const ParserOptions = parser.ParserOptions;
pub const Parameter = parser.Parameter;
pub const State = parser.State;
pub const Action = parser.Action;

test {
    _ = @import("parser_test.zig");
}
