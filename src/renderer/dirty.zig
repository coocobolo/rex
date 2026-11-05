pub const DirtyFlags = packed struct(u8) {
    cells: bool = false,
    selection: bool = false,
    cursor: bool = false,
    scrollbar: bool = false,
    blink: bool = false,
    overlay: bool = false,
    _pad: u2 = 0,

    pub fn any(self: DirtyFlags) bool {
        return @as(u8, @bitCast(self)) != 0;
    }
};
