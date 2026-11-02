//! Windows-native directory resolution: Roaming/Local AppData + ProgramData.
//! No env-var override chain, no ordered list-of-dirs — every location is a
//! single fixed environment variable, unlike XDG's *_HOME/*_DIRS split.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub const Spec = struct {
    pub const APPDATA = "APPDATA";
    pub const LOCALAPPDATA = "LOCALAPPDATA";
    pub const PROGRAMDATA = "PROGRAMDATA";
};

/// User-scoped locations. Fully owned, every field is a fresh gpa allocation.
pub const UserDirs = struct {
    /// %APPDATA%
    local: []const u8,

    /// %LOCALAPPDATA%
    roaming: []const u8,

    pub fn deinit(self: *UserDirs, gpa: Allocator) void {
        gpa.free(self.local);
        gpa.free(self.roaming);
        self.* = undefined;
    }
};

/// Machine-wide, all-users location. No list/ordering concept on Windows,
/// FIXME: unlike xdg.SystemDirs, kept as a distinct type only for symmetry and to
/// leave room for future KNOWNFOLDERID-based paths (e.g. FOLDERID_ProgramData).
pub const SystemDirs = struct {
    program_data: []const u8,

    pub fn deinit(self: *SystemDirs, gpa: Allocator) void {
        gpa.free(self.program_data);
        self.* = undefined;
    }
};

pub fn userDirs(gpa: Allocator, map: *const Environ.Map) !UserDirs {
    const roaming = map.get(Spec.APPDATA) orelse return error.BaseDirUnavailable;
    const local = map.get(Spec.LOCALAPPDATA) orelse return error.BaseDirUnavailable;

    const roaming_owned = try gpa.dupe(u8, roaming);
    errdefer gpa.free(roaming_owned);
    const local_owned = try gpa.dupe(u8, local);
    errdefer gpa.free(local_owned);

    return .{ .roaming = roaming_owned, .local = local_owned };
}

pub fn systemDirs(gpa: Allocator, map: *const Environ.Map) !SystemDirs {
    const program_data = map.get(Spec.PROGRAMDATA) orelse return error.BaseDirUnavailable;
    return .{ .program_data = try gpa.dupe(u8, program_data) };
}