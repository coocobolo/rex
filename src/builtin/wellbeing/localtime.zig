//! Local wall-clock time from the C library's time zone database.
//!
//! The wellbeing engines work on local seconds (UTC seconds plus the UTC
//! offset) so that the wind-down window and the day boundary follow the
//! user's clock. The offset comes from `localtime_r`, which honours `TZ`,
//! falls back to `/etc/localtime`, and applies daylight saving time.

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

/// Converts UTC seconds to local seconds, caching the offset until the
/// second changes. A conversion failure is logged once and treated as UTC.
pub const Clock = struct {
    utc_s: i64 = std.math.minInt(i64),
    offset_s: i32 = 0,
    warned: bool = false,

    pub fn localSeconds(self: *Clock, utc_s: i64) i64 {
        if (utc_s != self.utc_s) {
            self.utc_s = utc_s;
            self.offset_s = utcOffset(utc_s) orelse blk: {
                if (!self.warned) {
                    log.warn("cannot determine the local time zone; using UTC", .{});
                    self.warned = true;
                }
                break :blk 0;
            };
        }
        return utc_s + self.offset_s;
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
