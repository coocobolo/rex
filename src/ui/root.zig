//! Immediate-mode user interface subsystem for the Rex terminal emulator.
//!
//! Provides platform-agnostic interactive primitives including buttons, modal dialogs,
//! toast notifications, semantic icon styles, cyclic focus groups, and zero-allocation
//! in-stream hotspot hit-testing. All components operate on semantic theme tokens and
//! emit flat cache-aligned instance quads for the hardware renderer.

const std = @import("std");

pub const hotspot = @import("hotspot.zig");
pub const HotspotTable = hotspot.HotspotTable;
pub const Hotspot = hotspot.Hotspot;
pub const UiAction = hotspot.UiAction;
pub const UiActionTag = hotspot.UiActionTag;

pub const focus = @import("focus.zig");
pub const FocusGroup = focus.FocusGroup;

pub const button = @import("Button.zig");
pub const Button = button.Button;

pub const modal = @import("Modal.zig");
pub const Modal = modal.Modal;

pub const toast = @import("Toast.zig");
pub const Toast = toast.Toast;

pub const icon = @import("Icon.zig");
pub const Icon = icon;

pub const text = @import("Text.zig");
pub const Text = text;
pub const Drawer = text.Drawer;

test {
    _ = @import("hotspot.zig");
    _ = @import("focus.zig");
    _ = @import("Button.zig");
    _ = @import("Modal.zig");
    _ = @import("Toast.zig");
    _ = @import("Icon.zig");
    _ = @import("Text.zig");
    std.testing.refAllDecls(@This());
}
