const std = @import("std");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

const log = std.log.scoped(.xdg);

const separator = std.fs.path.sep;
const delimiter = std.fs.path.delimiter;

const env = @import("../env/root.zig");
const PathVar = env.PathVar;
const PlainVar = env.PlainVar;

test {
    _ = @import("xdg_test.zig");
}

/// XDG Base Directory Specification (Environment variable keys).
///
/// Spec only provides the canonical environment variable names used by the
/// XDG Base Directory Specification and their commonly expected meanings/defaults.
/// It does not implement path validation, default selection, or colon-list search
/// behavior; those requirements are applied by the code that reads these variables.
///
/// Reference: [XDG Base Direcotry Specification](https://specifications.freedesktop.org/basedir/latest/).
pub const Spec = struct {
    // User Directories

    /// User-specific data home directory (single base directory).
    ///
    /// Key name for lookup: `XDG_DATA_HOME`.
    /// Default when variable is unset/empty: `$HOME/.local/share`.
    ///
    /// NOTE: Absolute-path validation / relative-path invalidation is responsibility
    /// of the consuming code, not this constant.
    pub const XDG_DATA_HOME = "XDG_DATA_HOME";

    /// User-specific configuration home directory (single base directory).
    ///
    /// Key name for lookup: `XDG_CONFIG_HOME`.
    /// Default when variable is unset/empty: `$HOME/.config`.
    ///
    /// NOTE: Absolute-path validation / relative-path invalidation is responsibility
    /// of the consuming code, not this constant.
    pub const XDG_CONFIG_HOME = "XDG_CONFIG_HOME";

    /// User-specific state home directory (single base directory).
    ///
    /// Key name for lookup: `XDG_STATE_HOME`.
    /// Default when variable is unset/empty: `$HOME/.local/state`.
    ///
    /// NOTE: Absolute-path validation / relative-path invalidation is responsibility
    /// of the consuming code, not this constant.
    pub const XDG_STATE_HOME = "XDG_STATE_HOME";

    /// User cache home directory (single base directory).
    ///
    /// Key name for lookup: `XDG_CACHE_HOME`.
    /// Default when variable is unset/empty: `$HOME/.cache`.
    ///
    /// NOTE: Absolute-path validation / relative-path invalidation is responsibility
    /// of the consuming code, not this constant.
    pub const XDG_CACHE_HOME = "XDG_CACHE_HOME";

    /// User runtime directory (single base directory).
    ///
    /// Key name for lookup: `XDG_RUNTIME_DIR`.
    /// It has no default; applications should fall back if it is not set.
    ///
    /// NOTE: Absolute-path validation / relative-path invalidation is responsibility
    /// of the consuming code, not this constant.
    pub const XDG_RUNTIME_DIR = "XDG_RUNTIME_DIR";

    // System Directories

    /// User data search path (multiple base directories, preference ordered).
    ///
    /// Key name for lookup: `XDG_DATA_DIRS`.
    /// Value is a colon-separated ordered list.
    /// Should default to `/usr/local/share:/usr/share`.
    ///
    /// NOTE: Parsing and ordering rules are responsibility of the consuming code.
    pub const XDG_DATA_DIRS = "XDG_DATA_DIRS";
    pub const XDG_DATA_DIRS_VALUE = "/usr/local/share:/usr/share";

    /// User configuration search path (multiple base directories, preference ordered).
    ///
    /// Key name for lookup: `XDG_CONFIG_DIRS`.
    /// Value is a colon-separated ordered list.
    /// Should default to `/etc/xdg`.
    ///
    /// NOTE: Parsing and ordering rules are responsibility of the consuming code.
    pub const XDG_CONFIG_DIRS = "XDG_CONFIG_DIRS";
    pub const XDG_CONFIG_DIRS_VALUE = "/etc/xdg";
};

/// Fully borrowed view of `XDG_*_HOME` variables and `XDG_RUNTIME_DIR`,
/// produced by `userDirs()`.
///
/// See that function's doc comment for the lifetime and normalization requirements.
pub const UserDirs = struct {
    data_home: []const u8,
    config_home: []const u8,
    state_home: []const u8,
    cache_home: []const u8,
    /// len=0 means sentinel empty/not available instead of optional values
    runtime_dir: []const u8,
};

/// Fully owned result of `systemDirs()`. Every string, both the outer
/// slice-of-slices and each segment inside them, is a fresh allocation
/// from `gpa`. Safe to store and use for any lifetime, independent of
/// the `Environ.Map` that produced it. Free with `deinit`.
pub const SystemDirs = struct {
    data_dirs: []const []const u8, // ordered, absolute
    config_dirs: []const []const u8, // ordered, absolute

    pub const empty: SystemDirs = .{
        .data_dirs = &.{},
        .config_dirs = &.{},
    };

    /// Frees only the outer slices-of-slices. Does not free the segment
    /// strings themselves, those are borrowed from the `Environ.Map`
    /// passed to `systemDirs()` and are owned by that map.
    pub fn deinit(self: *SystemDirs, gpa: Allocator) void {
        for (self.data_dirs) |d| gpa.free(d);
        gpa.free(self.data_dirs);
        for (self.config_dirs) |d| gpa.free(d);
        gpa.free(self.config_dirs);
        self.* = undefined;
    }
};

pub const user_dirs = [_]PathVar{
    PathVar{ .key = Spec.XDG_CACHE_HOME, .segments = &.{".cache"} },
    PathVar{ .key = Spec.XDG_CONFIG_HOME, .segments = &.{".config"} },
    PathVar{ .key = Spec.XDG_DATA_HOME, .segments = &.{ ".local", "share" } },
    PathVar{ .key = Spec.XDG_STATE_HOME, .segments = &.{ ".local", "state" } },
};

pub const system_dirs = [_]PlainVar{
    PlainVar{ .key = Spec.XDG_DATA_DIRS, .value = Spec.XDG_DATA_DIRS_VALUE },
    PlainVar{ .key = Spec.XDG_CONFIG_DIRS, .value = Spec.XDG_CONFIG_DIRS_VALUE },
};

pub const Policy = enum {
    /// error on any relative/invalid entry (single-path or list segment).
    strict,

    /// treat relative/invalid list entries as ignored (i.e., skip invalid segments),
    /// and for user dirs vars use defaults when the env value is invalid/unset/empty.
    fallback,

    // treat relative/invalid list entries as ignored (skip invalid segments),
    // and for user dirs vars still use defaults.
    // ignore,
};

// Returning behavior error/invalid/ignore/fallbacks etc.
//
// Directory existence policy, for "read" operations: don't require directories to exist; just attempt paths.
// For "write" operations, ensure parent directories exist (create as needed).
//
// Caching behavior, if the platform's resolve directories once at process start, document that environment
// changes during runtime are not observed. Or re-resolve on demand if that maters for the platform sake's.
pub const Option = struct {
    policy: Policy,
};

/// Normalize map in-place so every XDG variable holds a spec-compliant,
/// absolute value (or, for XDG_RUNTIME_DIR, is remove if invalid).
/// $HOME must already validated (non-empty, absolute) by the caller.
pub fn normalize(gpa: Allocator, home: []const u8, map: *Environ.Map, option: Option) !void {
    const policy = option.policy;
    inline for (0..user_dirs.len) |i| try normalizeUserDir(gpa, map, home, i, policy);
    for (0..system_dirs.len) |i| try normalizeSystemDir(gpa, map, i, policy);
    try normalizeRuntimeDir(map, policy);
}

/// Returns a borrowed view of `XDG_*_HOME` variables and `XDG_RUNTIME_DIR`.
/// Every field aliases a string owned by `map`.
///
/// The map must outlive the returned UserDirs, and the fields become dangling
/// if map is deinitialized, or if any of these keys are overwritten or
/// removed from map afterward.
///
/// Safety: map must already be normalized via `normalize()`, which
/// guarantees `XDG_*_HOME` are present. Calling this on a raw, un-normalized
/// map triggers `unreachable` (a panic in Debug/ReleaseSafe; undefined behavior
/// in ReleaseFast/ReleaseSmall).
pub fn userDirs(map: *const Environ.Map) UserDirs {
    return .{
        .data_home = map.get(Spec.XDG_DATA_HOME) orelse unreachable,
        .config_home = map.get(Spec.XDG_CONFIG_HOME) orelse unreachable,
        .state_home = map.get(Spec.XDG_STATE_HOME) orelse unreachable,
        .cache_home = map.get(Spec.XDG_CACHE_HOME) orelse unreachable,
        .runtime_dir = map.get(Spec.XDG_RUNTIME_DIR) orelse "",
    };
}

/// Splits and duplicates XDG_DATA_DIRS / XDG_CONFIG_DIRS from `map` into a
/// fully owned `SystemDirs`. `map` does not need to outlive the result.
/// `map` must already be normalized via `fromMap()`.
pub fn systemDirs(gpa: Allocator, map: *const Environ.Map) !SystemDirs {
    var data_dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (data_dirs.items) |d| gpa.free(d);
        data_dirs.deinit(gpa);
    }

    {
        var it = std.mem.tokenizeScalar(u8, map.get(Spec.XDG_DATA_DIRS) orelse unreachable, delimiter);
        while (it.next()) |seg| try data_dirs.append(gpa, try gpa.dupe(u8, seg));
    }

    var config_dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (config_dirs.items) |d| gpa.free(d);
        config_dirs.deinit(gpa);
    }

    {
        var it = std.mem.tokenizeScalar(u8, map.get(Spec.XDG_CONFIG_DIRS) orelse unreachable, delimiter);
        while (it.next()) |seg| try config_dirs.append(gpa, try gpa.dupe(u8, seg));
    }

    return .{
        .config_dirs = try config_dirs.toOwnedSlice(gpa),
        .data_dirs = try data_dirs.toOwnedSlice(gpa),
    };
}

/// Returns true when valid and non-empty value,
/// otherwise false indicates value is invalid.
pub fn validateAbsolute(path: ?[]const u8) bool {
    const value = path orelse return false;
    return value.len > 0 and std.fs.path.isAbsolute(value);
}

fn normalizeUserDir(
    gpa: Allocator,
    map: *Environ.Map,
    home: []const u8,
    comptime index: usize,
    policy: Policy,
) !void {
    const user_dir: PathVar = user_dirs[index];
    const current = map.get(user_dir.key);

    if (validateAbsolute(current)) return; // already spec-compliant, leave untouched.
    if (current != null and policy == .strict) return error.EnvironmentVariableInvalid;

    // .fallback and .ignore both substitute the spec-defined default.
    var buf: [user_dir.segments.len + 1][]const u8 = undefined;
    buf[0] = home;
    inline for (user_dir.segments, 0..) |seg, i| buf[i + 1] = seg;

    const default_path = try std.fs.path.join(gpa, &buf);
    defer gpa.free(default_path);

    // Map.put copies the value, so freeing default_path afterwards is safe.
    try map.put(user_dir.key, default_path);
}

fn normalizeSystemDir(
    gpa: Allocator,
    map: *Environ.Map,
    index: usize,
    policy: Policy,
) !void {
    const system_dir: PlainVar = system_dirs[index];
    const current = map.get(system_dir.key) orelse {
        return try map.put(system_dir.key, system_dir.value);
    };

    if (current.len == 0) {
        return try map.put(system_dir.key, system_dir.value);
    }

    var segs: std.ArrayList([]const u8) = try .initCapacity(gpa, 8);
    defer segs.deinit(gpa);

    var any_invalid = false;
    var it = std.mem.splitScalar(u8, current, delimiter);
    while (it.next()) |seg| {
        const not_empty = seg.len > 0;
        if (not_empty and std.fs.path.isAbsolute(seg)) {
            try segs.append(gpa, seg);
        } else if (not_empty) {
            any_invalid = true;
        }
    }

    if (any_invalid and policy == .strict) return error.EnvironmentVariableInvalid;
    if (!any_invalid) return; // fully valid already, no rewirte needed.

    if (segs.items.len == 0) return try map.put(system_dir.key, system_dir.value);
    const joined = try std.mem.join(gpa, &.{delimiter}, segs.items);
    defer gpa.free(joined);
    try map.put(system_dir.key, joined);
}

fn normalizeRuntimeDir(
    map: *Environ.Map,
    policy: Policy,
) !void {
    const current = map.get(Spec.XDG_RUNTIME_DIR) orelse return;
    if (validateAbsolute(current)) return;
    if (policy == .strict) return error.EnvironmentVariableInvalid;

    // Spec: never fabricate a runtime dir. Drop the invalid value so the
    // caller sees "not set" and applies its own fallback + warning.
    _ = map.swapRemove(Spec.XDG_RUNTIME_DIR);
}

// If an XDG variable value cannot be decoded as the platform's string model,
// return an error (or treat as invalid/ignored, but be consistent).
//
// On empty-value handling, treat "unset or set but empty" as "not provided".
// For `XDG_*_HOME` and XDG_CACHE_HOME, default values will be applied when
// met criteria of "not provided".
// For `XDG_RUNTIME_DIR`, treat "unset or set but empty" as "runtime dir unavailable"
// means no default value will be applied.
//
// On absolute-path validation, for `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`,
// `XDG_CACHE_HOME`, and `XDG_RUNTIME_DIR` if the variable is set and non-empty, the path
// must be absolute. If it is relative, treat as invalid/ignored or return an error
// (choose one policy and apply consistently across all these "single-path" vars).
// Prefer "return error" if the caller wants strict complience; prefer "ignore invalid and
// fallback to default" if caller want resilience.
//
// On colon-separated ordered search lists, parsing `XDG_DATA_DIRS` and `XDG_CONFIG_DIRS` as a colon (':').
// separated list. Preserve order, the earlier have higher precendence. If an entry in the list is relative
// treat it using the same chosen policy option. Empty list segments (e.g., a::b) should be treated
// as empty/skip.
//
// On home directory required for defaults, the value defaults depends on `$HOME`, if is "not provided",
// treat it using the same chosen policy option.
// pub const Resolver = struct {
// Directory resolution requirements (outputs)
//
// Given the environment:
//
//     XDG_DATA_HOME (default: $HOME/.local/share)
//         Return a single resolved absolute directory path.
//
//     XDG_CONFIG_HOME (default: $HOME/.config)
//         Return a single resolved absolute directory path.
//
//     XDG_STATE_HOME (default: $HOME/.local/state)
//         Return a single resolved absolute directory path.
//
//     XDG_CACHE_HOME (default: $HOME/.cache)
//         Return a single resolved absolute directory path.
//
//     XDG_RUNTIME_DIR (no default)
//         If set and absolute: return runtime_dir.
//         If unset/empty: return None (or equivalent “not available”).
//
//     XDG_DATA_DIRS (default: /usr/local/share:/usr/share)
//         Return an ordered list of absolute directory paths.
//
//     XDG_CONFIG_DIRS (default: /etc/xdg)
//         Return an ordered list of absolute directory paths.

// Search requirements (finding files)

// Define “search” as: locate a relative file path (e.g. myapp/config.json) inside the relevant base directories.
//
//     User-first, then system-wide
//         For data/config lookups:
//             Search inside the user-specific *_HOME directory first.
//             If not found, search in the ordered *_DIRS list.
//
//     Return semantics
//         Return the first match encountered in precedence order.
//         If not found anywhere, return NotFound/None (not an error).
//
//     Runtime directory usage
//         Only use XDG_RUNTIME_DIR if it is available (Some) and absolute.
//         If it is not available, fall back to an alternate storage policy defined by your application (but do not fabricate a runtime directory).
//};
