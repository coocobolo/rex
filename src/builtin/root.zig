pub const wellbeing = @import("wellbeing/root.zig");
pub const focus = wellbeing.focus;

test {
    _ = @import("wellbeing/wellbeing_test.zig");
}
