const std = @import("std");

const log = std.log.scoped(.freetype);

pub const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/fterrors.h");
    @cInclude("freetype/tttables.h");
    @cInclude("freetype/ftmm.h");
});

pub const FontConfig = @import("Config.zig");
pub const Rasterizer = @import("Rasterizer.zig");
pub const KitFont = @import("KitFont.zig");

comptime {
    std.testing.refAllDecls(@This());
}

test {
    _ = @import("config_test.zig");
    _ = @import("kit_font_test.zig");
}

/// Convert FreeType error code to human-readable string.
pub fn ftErrorString(err: c.FT_Error) []const u8 {
    const msg = c.FT_Error_String(err);
    if (msg == null) return "(unknown freetype error)";
    return std.mem.span(msg);
}

pub const FtError = error{
    Ok,
    CannotOpenResource,
    UnknownFileFormat,
    InvalidFileFormat,
    InvalidArgument,
    InvalidFaceHandle,
    InvalidGlyphIndex,
    InvalidPixelSize,
    InvalidSizeHandle,
    UnimplementedFeature,
    OutOfMemory,
    ArrayTooLarge,
    MissingModule,
    UnknownError,
};

pub fn ftDecode(err: c.FT_Error) FtError {
    return switch (err) {
        c.FT_Err_Ok => error.Ok,
        c.FT_Err_Cannot_Open_Resource => error.CannotOpenResource,
        c.FT_Err_Unknown_File_Format => error.UnknownFileFormat,
        c.FT_Err_Invalid_File_Format => error.InvalidFileFormat,
        c.FT_Err_Invalid_Argument => error.InvalidArgument,
        c.FT_Err_Invalid_Face_Handle => error.InvalidFaceHandle,
        c.FT_Err_Invalid_Glyph_Index => error.InvalidGlyphIndex,
        c.FT_Err_Invalid_Pixel_Size => error.InvalidPixelSize,
        c.FT_Err_Invalid_Size_Handle => error.InvalidSizeHandle,
        c.FT_Err_Unimplemented_Feature => error.UnimplementedFeature,
        c.FT_Err_Out_Of_Memory => error.OutOfMemory,
        c.FT_Err_Array_Too_Large => error.ArrayTooLarge,
        c.FT_Err_Missing_Module => error.MissingModule,
        else => error.UnknownError,
    };
}

pub fn ftCheck(err: c.FT_Error, comptime context: []const u8) FtError!void {
    if (err == 0) return;
    const decoded = ftDecode(err);
    const msg = ftErrorString(err);

    log.err(
        \\FT error in {s}:
        \\message: {s}
        \\type: {t}
        \\code: {}
    ,
        .{ context, msg, decoded, err },
    );

    return decoded;
}

/// Returns true if `face` is a variable font (has an `fvar` table).
pub fn hasMM(face: c.FT_Face) bool {
    return c.FT_HAS_MULTIPLE_MASTERS(face);
}

/// Sets a single named-axis design coordinate (e.g. tag='wght', value=700.0).
/// Builds the full coords array from the face's current defaults, only
/// overriding the axis whose tag matches, then applies it.
pub fn setVarAxis(gpa: std.mem.Allocator, face: c.FT_Face, mm_var: *c.FT_MM_Var, tag: [4]u8, value: f64) !void {
    const n: usize = @intCast(mm_var.num_axis);
    const coords = try gpa.alloc(c.FT_Fixed, n);
    defer gpa.free(coords);

    const want_tag = std.mem.readInt(u32, &tag, .big);

    for (0..n) |i| {
        const axis = mm_var.axis[i];
        coords[i] = if (axis.tag == want_tag)
            @intFromFloat(value * 65536.0) // to 16.16 fixed point
        else
            axis.def; // keep default for every other axis
    }

    try ftCheck(
        c.FT_Set_Var_Design_Coordinates(face, @intCast(n), coords.ptr),
        "FT_Set_Var_Design_Coordinates",
    );
}

/// Fetches the MM/variation descriptor for a variable face.
/// Caller must free with `c.FT_Done_MM_Var(library, mm_var)`.
pub fn getMMVar(ft_library: c.FT_Library, face: c.FT_Face) FtError!*c.FT_MM_Var {
    var mm_var: [*c]c.FT_MM_Var = undefined;
    try ftCheck(c.FT_Get_MM_Var(face, &mm_var), "FT_Get_MM_Var");
    _ = ft_library;
    return mm_var;
}

/// Creates and returns a FreeType library instance.
pub fn initFreeType() FtError!c.FT_Library {
    var lib: c.FT_Library = undefined;
    try ftCheck(c.FT_Init_FreeType(&lib), "FT_Init_FreeType");
    return lib;
}

/// Loads a FreeType face and selects the requested size.
///
/// Scalable fonts use FT_Set_Pixel_Sizes().
/// Bitmap/color emoji fonts use the closest available fixed strike.
pub fn initFace(ft_library: c.FT_Library, path: [*:0]const u8, pixel_height: u32) FtError!c.FT_Face {
    var face: c.FT_Face = undefined;
    try ftCheck(c.FT_New_Face(ft_library, path, 0, &face), "FT_New_Face");

    // Variable (MM/gvar) fonts are scalable outlines; never route them through
    // the bitmap-strike selection path even if the face also reports fixed sizes.
    if (face.*.num_fixed_sizes > 0 and !hasMM(face)) {
        const strike = bestStrikeIndex(face, pixel_height);
        try ftCheck(c.FT_Select_Size(face, strike), "FT_Select_Size");
    } else {
        try ftCheck(c.FT_Set_Pixel_Sizes(face, 0, pixel_height), "FT_Set_Pixel_Sizes");
    }

    return face;
}

pub fn doneFreeType(ft_library: c.FT_Library) FtError!void {
    try ftCheck(c.FT_Done_FreeType(ft_library), "FT_Done_FreeType");
}

pub fn doneFace(ft_face: c.FT_Face) FtError!void {
    try ftCheck(c.FT_Done_Face(ft_face), "FT_Done_Face");
}

pub fn loadChar(ft_face: c.FT_Face, ch: u21, load_flags: c.FT_Int32) FtError!void {
    try ftCheck(c.FT_Load_Char(ft_face, @intCast(ch), load_flags), "FT_Load_Char");
}

pub fn fontUnitsToPixels(units: i32, scale: c.FT_Fixed) f32 {
    // Ft_MulFix(units, scale) 26.6 fixed point, divide by 64 for pixels
    return @as(f32, @floatFromInt(c.FT_MulFix(units, scale))) / 64.0;
}

pub fn bestStrikeIndex(ft_face: c.FT_Face, pixel_height: u32) c_int {
    // If num_fixed_sizes == 0, then returning 0 does not mean
    // strike 0 exists. It just returns an index value of 0.
    // Then calling _ = c.FT_Select_Size(face, 0);
    // when face.*.num_fixed_sizes == 0 is invalid and
    // FreeType will typically return an error such as FT_Err_Invalid_Argument.
    if (ft_face == null or ft_face.*.num_fixed_sizes == 0) return 0;

    const count: usize = @intCast(ft_face.*.num_fixed_sizes);
    var best_index: c_int = 0;
    var best_diff: u32 = std.math.maxInt(u32);

    for (0..count) |i| {
        const size = ft_face.*.available_sizes[i];

        // FT_Bitmap_Size.height is in pixels
        const strike_height: u32 = @intCast(size.height);
        const diff =
            if (strike_height > pixel_height)
                strike_height - pixel_height
            else
                pixel_height - strike_height;
        if (diff < best_diff) {
            best_diff = diff;
            best_index = @intCast(i);
        }
    }

    return best_index;
}

/// Helpers: For debugging emoji fonts, it's often useful to print all available strikes.
pub fn dumpStrikes(face: c.FT_Face) void {
    const count: usize = @intCast(face.*.num_fixed_sizes);

    for (0..count) |i| {
        const s = face.*.available_sizes[i];

        std.debug.print(
            "strike[{d}] width={d} height={d} x_ppem={d} y_ppem={d}\n",
            .{ i, s.width, s.height, s.x_ppem, s.y_ppem },
        );
    }
}
