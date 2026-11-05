//! Rex Configuration Subsystem.
//!
//! Provides zero-allocation file parsing, layered resolution hierarchy,
//! and live hot-reloading for terminal customization.

const std = @import("std");

pub const types = @import("types.zig");
pub const FileConfig = types.FileConfig;
pub const Diagnostics = types.Diagnostics;
pub const Diagnostic = types.Diagnostic;
pub const Severity = types.Severity;
pub const Section = types.Section;

pub const lexer = @import("lexer.zig");
pub const Lexer = lexer.Lexer;
pub const Token = lexer.Token;

pub const parser = @import("parser.zig");
pub const Parser = parser.Parser;

pub const keymap_parser = @import("keymap_parser.zig");

pub const merge = @import("merge.zig");
pub const loadFile = merge.loadFile;
pub const applyFileConfig = merge.applyFileConfig;
pub const resolveUserConfigPath = merge.resolveUserConfigPath;
pub const dumpDefaultConfig = merge.dumpDefaultConfig;
pub const canonical_default_config = merge.canonical_default_config;
pub const mergeFileConfigs = merge.mergeFileConfigs;
pub const serializeConfig = merge.serializeConfig;
pub const mergeFiles = merge.mergeFiles;
pub const migrateConfigFile = merge.migrateConfigFile;
pub const system_config_path = merge.system_config_path;

pub const watcher = @import("watcher.zig");
pub const Watcher = watcher.Watcher;

test {
    _ = @import("parser_test.zig");
    std.testing.refAllDecls(@This());
}
