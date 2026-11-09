//! Local wall-clock time from the C library's time zone database.
//!
//! The wellbeing engines work on local seconds (UTC seconds plus the UTC
//! offset) so that the wind-down window and the day boundary follow the
//! user's clock. The offset comes from `localtime_r`, which honours `TZ`,
//! falls back to `/etc/localtime`, and applies daylight saving time.
//!
//! glibc's `localtime_r` loads the zone only once per process
//! (`tzset_internal (0)` in glibc 2.39 `time/tzset.c`), so `Clock` calls
//! `tzset` once per wall-clock minute to notice a changed system zone.
//! With `TZ` unset that costs a `stat` of `/etc/localtime`, and the file is
//! re-read only when its inode, device or mtime changed (`time/tzfile.c`).
//! A set `TZ` pins the zone: glibc skips the reload while the string is
//! unchanged.
//! macOS checks for zone changes in every `localtime_r` call
//! (`stdtime/FreeBSD/localtime.c`), so there `tzset` adds nothing.

const std = @import("std");

const log = std.log.scoped(.localtime);

/// `struct tm` from `<time.h>`. The field order is the same in glibc and on
/// the BSDs (macOS); `tm_gmtoff` and `tm_zone` are extensions both provide.
const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timer: *const std.c.time_t, result: *Tm) ?*Tm;
extern "c" fn tzset() void;

/// Converts UTC seconds to local seconds, caching the offset until the
/// second changes. The system zone is re-checked with `tzset` whenever the
/// wall-clock minute changes, which also covers a clock set backwards.
/// A conversion failure is logged on those re-checks, so at most once a
/// minute, and treated as UTC.
pub const Clock = struct {
    /// UTC second of the last conversion; `never` before the first.
    utc_s: i64 = never,
    offset_s: i32 = 0,

    const never = std.math.minInt(i64);

    pub fn localSeconds(self: *Clock, utc_s: i64) i64 {
        if (utc_s != self.utc_s) self.update(utc_s);
        return utc_s + self.offset_s;
    }

    fn update(self: *Clock, utc_s: i64) void {
        const prev_s = self.utc_s;
        self.utc_s = utc_s;
        const min_s = std.time.s_per_min;
        const zone_check = @divFloor(utc_s, min_s) != @divFloor(prev_s, min_s);
        if (zone_check) tzset();
        const offset_s = utcOffset(utc_s) orelse blk: {
            if (zone_check) log.warn("cannot determine the local time zone; using UTC", .{});
            break :blk 0;
        };
        if (offset_s != self.offset_s and prev_s != never) {
            log.info("UTC offset changed from {d} s to {d} s", .{ self.offset_s, offset_s });
        }
        self.offset_s = offset_s;
    }
};

/// Seconds east of UTC in the system time zone at `utc_s`, or null when the
/// C library cannot convert the time or reports an offset beyond ±26 hours.
pub fn utcOffset(utc_s: i64) ?i32 {
    const timer = std.math.cast(std.c.time_t, utc_s) orelse return null;
    var tm: Tm = undefined;
    _ = localtime_r(&timer, &tm) orelse return null;
    const max_offset_s = 26 * std.time.s_per_hour;
    if (@abs(tm.tm_gmtoff) > max_offset_s) return null;
    return @intCast(tm.tm_gmtoff);
}
