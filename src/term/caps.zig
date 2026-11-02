const std = @import("std");

const log = std.log.scoped(.profile);

/// Features this build can implement. Fixed for a given build.
pub const BuildSupport = struct {
    features: std.enums.EnumSet(Feature),
};

/// Features a selected runtime profile permits.
const Feature = enum {
    decckm,
    left_right_margins,
    rectangular_editing,
    locator,
    sgr_truecolor,
    sgr_colon_subparams,
    osc52,
    kitty_keyboard,
    sixel,
};

/// Format used for transmitted C1 controls.
pub const C1TransmissionFormat = enum(u8) {
    /// 7-bit format.
    seven_bit,
    /// 8-bit format; DECSCL 62;0 also maps here (0 ≡ 2)
    eight_bit,
};

/// DECSCL wire selector values range up to (61..65).
pub const DecsclSelector = enum(u8) {
    level_1 = 61,
    level_2 = 62,
    level_3 = 63,
    level_4 = 64,
    level_5 = 65,
};

pub const DecsclCaps = struct {
    const Flag = enum {
        delete_insert_lines,
        rectangular_editing,
        multi_page,
        locator,
        technical_charset,
        windowing,
        session_management,
        horizontal_margins,
    };

    const Flags = std.EnumSet(Flag);

    const Decscl = struct {
        // Flag features capability under current selected compatiblity behaviour.
        flags: Flags,

        // How the second DECSCL paramter is interpreted for current selector.
        c1_transmission_format: C1TransmissionFormat,

        // Model-specific consequences of selecting current level
    };

    pub const Profiles = std.EnumMap(DecsclSelector, Decscl);

    // An entry means that selector is supported; its value defines behavior.
    profiles: Profiles,
};

pub const Caps = struct {};