//! macOS-native directory resolution via Apple's domain-mask model
//! (NSUserDomainMask / NSLocalDomainMask), not XDG env-var overrides.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub const Spec = struct {
    pub const HOME = "HOME";
};

/// NSUserDomainMask "~/Libarary/*". Fully owned.
pub const UserDomain = struct {
    /// ~/Library/Application Support
    application_support: []const u8,
    /// ~/Library/Caches
    caches: []const u8,
    /// ~/Library/Logs
    logs: []const u8,

    pub fn deinit(self: *UserDomain, gpa: Allocator) void {
        gpa.free(self.application_support);
        gpa.free(self.caches);
        gpa.free(self.logs);
        self.* = undefined;
    }
};

/// NSUserDomainMask "/Libarary/*". machine-wide, all users.
/// Fixed paths, no ENVIRONMENT_VARIABLE backs this on macos.
pub const LocalDomain = struct {
    pub const application_support = "/Library/Application Support";
};

pub fn userDomain(gpa: Allocator, home: []const u8) !UserDomain {
    if (home.len == 0) return error.BaseDirUnavailable;

    const application_support = try std.fs.path.join(gpa, &.{ home, "Library", "Application Support" });
    errdefer gpa.free(application_support);

    const caches = try std.fs.path.join(gpa, &.{ home, "Library", "Caches" });
    errdefer gpa.free(caches);

    const logs = try std.fs.path.join(gpa, &.{ home, "Library", "Logs" });
    errdefer gpa.free(logs);

    return .{ .application_support = application_support, .caches = caches, .logs = logs };
}