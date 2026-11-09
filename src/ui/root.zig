//! Domain-agnostic immediate-mode user interface toolkit.
//!
//! Provides reusable atomic layout, border, container, and typography primitives alongside
//! interactive and data-visualization molecules including buttons, modal dialogs, toast
//! notifications, status banners, segmented tab bars, KPI stat cards, sub-pixel progress bars,
//! circular SDF ring gauges, discrete step indicators, and bar charts. All components operate
//! on semantic theme tokens and emit flat 64-byte cache-aligned instance quads for the hardware renderer.

const std = @import("std");

pub const hotspot = @import("hotspot.zig");
pub const Table = hotspot.Table;
pub const Hotspot = hotspot.Hotspot;
pub const Action = hotspot.Action;
pub const Tag = hotspot.Tag;

pub const focus = @import("focus.zig");
pub const FocusGroup = focus.FocusGroup;

pub const rect = @import("Rect.zig");
pub const Rect = rect.Rect;
pub const Padding = rect.Padding;

pub const border = @import("Border.zig");
pub const Border = border.Border;

pub const box = @import("Box.zig");
pub const Box = box.Box;

pub const label = @import("Label.zig");
pub const Label = label.Label;

pub const divider = @import("Divider.zig");
pub const Divider = divider.Divider;

pub const badge = @import("Badge.zig");
pub const Badge = badge.Badge;

pub const kbd = @import("Kbd.zig");
pub const Kbd = kbd.Kbd;

pub const button = @import("Button.zig");
pub const Button = button.Button;

pub const modal = @import("Modal.zig");
pub const Modal = modal.Modal;

pub const toast = @import("Toast.zig");
pub const Toast = toast.Toast;

pub const banner = @import("Banner.zig");
pub const Banner = banner.Banner;

pub const icon = @import("Icon.zig");
pub const Icon = icon;

pub const text = @import("Text.zig");
pub const Text = text;
pub const Drawer = text.Drawer;

pub const progress_bar = @import("ProgressBar.zig");
pub const ProgressBar = progress_bar.ProgressBar;

pub const ring_gauge = @import("RingGauge.zig");
pub const RingGauge = ring_gauge.RingGauge;

pub const step_indicator = @import("StepIndicator.zig");
pub const StepIndicator = step_indicator.StepIndicator;

pub const bar_chart = @import("BarChart.zig");
pub const BarChart = bar_chart.BarChart;

pub const stat_card = @import("StatCard.zig");
pub const StatCard = stat_card.StatCard;

pub const tab_bar = @import("TabBar.zig");
pub const TabBar = tab_bar.TabBar;

test {
    _ = @import("Rect.zig");
    _ = @import("Border.zig");
    _ = @import("Box.zig");
    _ = @import("Label.zig");
    _ = @import("Divider.zig");
    _ = @import("Badge.zig");
    _ = @import("Kbd.zig");
    _ = @import("hotspot.zig");
    _ = @import("focus.zig");
    _ = @import("button_test.zig");
    _ = @import("modal_test.zig");
    _ = @import("toast_test.zig");
    _ = @import("banner_test.zig");
    _ = @import("icon_test.zig");
    _ = @import("Text.zig");
    _ = @import("ProgressBar.zig");
    _ = @import("RingGauge.zig");
    _ = @import("StepIndicator.zig");
    _ = @import("BarChart.zig");
    _ = @import("StatCard.zig");
    _ = @import("TabBar.zig");
    std.testing.refAllDecls(@This());
}
