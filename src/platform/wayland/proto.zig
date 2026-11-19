//! Typed Zig view of the vendored Wayland protocol interface table
//! (`proto_tables.c`) plus request opcodes and listener structs for the
//! Wayland backend.

const wl = @import("wl.zig");
const w = @import("wayland");

/// Flag passed to `wl_proxy_marshal_flags` for destructor requests.
pub const marshal_flag_destroy: u32 = 1;

/// Pointers to the static `wl_interface` structs generated in `proto_tables.c`.
pub const Interfaces = extern struct {
    xdg_wm_base: *const wl.Interface,
    xdg_surface: *const wl.Interface,
    xdg_toplevel: *const wl.Interface,
    xdg_decoration_manager: *const wl.Interface,
    xdg_toplevel_decoration: *const wl.Interface,
    fractional_scale_manager: *const wl.Interface,
    fractional_scale: *const wl.Interface,
    viewporter: *const wl.Interface,
    viewport: *const wl.Interface,
    text_input_manager: *const wl.Interface,
    text_input: *const wl.Interface,
    primary_selection_manager: *const wl.Interface,
    primary_selection_device: *const wl.Interface,
    primary_selection_source: *const wl.Interface,
    primary_selection_offer: *const wl.Interface,
    xdg_activation: *const wl.Interface,
    xdg_activation_token: *const wl.Interface,
    xdg_system_bell: *const wl.Interface,
    cursor_shape_manager: *const wl.Interface,
    cursor_shape_device: *const wl.Interface,
};

extern fn rex_wayland_interfaces() *const Interfaces;

/// Returns the static table of vendored Wayland protocol interfaces.
pub fn interfaces() *const Interfaces {
    return rex_wayland_interfaces();
}

pub const display = struct {
    pub const get_registry: u32 = 1;
};

pub const registry = struct {
    pub const bind: u32 = 0;

    pub const Listener = extern struct {
        global: *const fn (?*anyopaque, ?*wl.Proxy, u32, [*c]const u8, u32) callconv(.c) void,
        global_remove: *const fn (?*anyopaque, ?*wl.Proxy, u32) callconv(.c) void,
    };
};

pub const compositor = struct {
    pub const create_surface: u32 = 0;
};

pub const surface = struct {
    pub const destroy: u32 = 0;
    pub const commit: u32 = 6;
};

pub const xdg_wm_base = struct {
    pub const destroy: u32 = 0;
    pub const get_xdg_surface: u32 = 2;
    pub const pong: u32 = 3;

    pub const Listener = extern struct {
        ping: *const fn (?*anyopaque, ?*wl.Proxy, u32) callconv(.c) void,
    };
};

pub const xdg_surface = struct {
    pub const destroy: u32 = 0;
    pub const get_toplevel: u32 = 1;
    pub const ack_configure: u32 = 4;

    pub const Listener = extern struct {
        configure: *const fn (?*anyopaque, ?*wl.Proxy, u32) callconv(.c) void,
    };
};

pub const xdg_toplevel = struct {
    pub const destroy: u32 = 0;
    pub const set_title: u32 = 2;
    pub const set_app_id: u32 = 3;
    pub const set_min_size: u32 = 8;

    pub const state_activated: u32 = 4;

    pub const Listener = extern struct {
        configure: *const fn (?*anyopaque, ?*wl.Proxy, i32, i32, ?*w.wl_array) callconv(.c) void,
        close: *const fn (?*anyopaque, ?*wl.Proxy) callconv(.c) void,
        configure_bounds: *const fn (?*anyopaque, ?*wl.Proxy, i32, i32) callconv(.c) void,
        wm_capabilities: *const fn (?*anyopaque, ?*wl.Proxy, ?*w.wl_array) callconv(.c) void,
    };
};

pub const xdg_decoration_manager = struct {
    pub const destroy: u32 = 0;
    pub const get_toplevel_decoration: u32 = 1;
};

pub const xdg_toplevel_decoration = struct {
    pub const destroy: u32 = 0;
    pub const set_mode: u32 = 1;

    pub const mode_client_side: u32 = 1;
    pub const mode_server_side: u32 = 2;

    pub const Listener = extern struct {
        configure: *const fn (?*anyopaque, ?*wl.Proxy, u32) callconv(.c) void,
    };
};

pub const seat = struct {
    pub const get_pointer: u32 = 0;
    pub const get_keyboard: u32 = 1;
    pub const release: u32 = 3;

    pub const capability_pointer: u32 = 1;
    pub const capability_keyboard: u32 = 2;

    pub const Listener = extern struct {
        capabilities: *const fn (?*anyopaque, ?*wl.Proxy, u32) callconv(.c) void,
        name: *const fn (?*anyopaque, ?*wl.Proxy, [*c]const u8) callconv(.c) void,
    };
};

pub const keyboard = struct {
    pub const release: u32 = 0;

    pub const keymap_format_xkb_v1: u32 = 1;
    pub const key_state_released: u32 = 0;
    pub const key_state_pressed: u32 = 1;

    pub const Listener = extern struct {
        keymap: *const fn (?*anyopaque, ?*wl.Proxy, u32, i32, u32) callconv(.c) void,
        enter: *const fn (?*anyopaque, ?*wl.Proxy, u32, ?*wl.Proxy, ?*w.wl_array) callconv(.c) void,
        leave: *const fn (?*anyopaque, ?*wl.Proxy, u32, ?*wl.Proxy) callconv(.c) void,
        key: *const fn (?*anyopaque, ?*wl.Proxy, u32, u32, u32, u32) callconv(.c) void,
        modifiers: *const fn (?*anyopaque, ?*wl.Proxy, u32, u32, u32, u32, u32) callconv(.c) void,
        repeat_info: *const fn (?*anyopaque, ?*wl.Proxy, i32, i32) callconv(.c) void,
    };
};

pub const pointer = struct {
    pub const set_cursor: u32 = 0;
    pub const release: u32 = 1;

    pub const button_state_released: u32 = 0;
    pub const button_state_pressed: u32 = 1;
    pub const axis_vertical: u32 = 0;
    pub const axis_horizontal: u32 = 1;

    pub const Listener = extern struct {
        enter: *const fn (?*anyopaque, ?*wl.Proxy, u32, ?*wl.Proxy, i32, i32) callconv(.c) void,
        leave: *const fn (?*anyopaque, ?*wl.Proxy, u32, ?*wl.Proxy) callconv(.c) void,
        motion: *const fn (?*anyopaque, ?*wl.Proxy, u32, i32, i32) callconv(.c) void,
        button: *const fn (?*anyopaque, ?*wl.Proxy, u32, u32, u32, u32) callconv(.c) void,
        axis: *const fn (?*anyopaque, ?*wl.Proxy, u32, u32, i32) callconv(.c) void,
        frame: *const fn (?*anyopaque, ?*wl.Proxy) callconv(.c) void,
        axis_source: *const fn (?*anyopaque, ?*wl.Proxy, u32) callconv(.c) void,
        axis_stop: *const fn (?*anyopaque, ?*wl.Proxy, u32, u32) callconv(.c) void,
        axis_discrete: *const fn (?*anyopaque, ?*wl.Proxy, u32, i32) callconv(.c) void,
        axis_value120: *const fn (?*anyopaque, ?*wl.Proxy, u32, i32) callconv(.c) void,
        axis_relative_direction: *const fn (?*anyopaque, ?*wl.Proxy, u32, u32) callconv(.c) void,
    };
};

pub const cursor_shape_manager = struct {
    pub const destroy: u32 = 0;
    pub const get_pointer: u32 = 1;
};

pub const cursor_shape_device = struct {
    pub const destroy: u32 = 0;
    pub const set_shape: u32 = 1;

    pub const shape_default: u32 = 1;
    pub const shape_pointer: u32 = 4;
    pub const shape_text: u32 = 9;
};

pub const fractional_scale_manager = struct {
    pub const destroy: u32 = 0;
    pub const get_fractional_scale: u32 = 1;
};

pub const fractional_scale = struct {
    pub const destroy: u32 = 0;

    pub const Listener = extern struct {
        preferred_scale: *const fn (?*anyopaque, ?*wl.Proxy, u32) callconv(.c) void,
    };
};

pub const viewporter = struct {
    pub const destroy: u32 = 0;
    pub const get_viewport: u32 = 1;
};

pub const viewport = struct {
    pub const destroy: u32 = 0;
    pub const set_destination: u32 = 2;
};

pub const text_input_manager = struct {
    pub const destroy: u32 = 0;
    pub const get_text_input: u32 = 1;
};

pub const text_input = struct {
    pub const destroy: u32 = 0;
    pub const enable: u32 = 1;
    pub const disable: u32 = 2;
    pub const commit: u32 = 7;

    pub const Listener = extern struct {
        enter: *const fn (?*anyopaque, ?*wl.Proxy, ?*wl.Proxy) callconv(.c) void,
        leave: *const fn (?*anyopaque, ?*wl.Proxy, ?*wl.Proxy) callconv(.c) void,
        preedit_string: *const fn (?*anyopaque, ?*wl.Proxy, [*c]const u8, i32, i32) callconv(.c) void,
        commit_string: *const fn (?*anyopaque, ?*wl.Proxy, [*c]const u8) callconv(.c) void,
        delete_surrounding_text: *const fn (?*anyopaque, ?*wl.Proxy, u32, u32) callconv(.c) void,
        done: *const fn (?*anyopaque, ?*wl.Proxy, u32) callconv(.c) void,
    };
};

pub const data_device_manager = struct {
    pub const create_data_source: u32 = 0;
    pub const get_data_device: u32 = 1;
};

pub const data_device = struct {
    pub const set_selection: u32 = 1;
    pub const release: u32 = 2;

    pub const Listener = extern struct {
        data_offer: *const fn (?*anyopaque, ?*wl.Proxy, ?*wl.Proxy) callconv(.c) void,
        enter: *const fn (?*anyopaque, ?*wl.Proxy, u32, ?*wl.Proxy, i32, i32, ?*wl.Proxy) callconv(.c) void,
        leave: *const fn (?*anyopaque, ?*wl.Proxy) callconv(.c) void,
        motion: *const fn (?*anyopaque, ?*wl.Proxy, u32, i32, i32) callconv(.c) void,
        drop: *const fn (?*anyopaque, ?*wl.Proxy) callconv(.c) void,
        selection: *const fn (?*anyopaque, ?*wl.Proxy, ?*wl.Proxy) callconv(.c) void,
    };
};

pub const data_source = struct {
    pub const offer: u32 = 0;
    pub const destroy: u32 = 1;

    pub const Listener = extern struct {
        target: *const fn (?*anyopaque, ?*wl.Proxy, [*c]const u8) callconv(.c) void,
        send: *const fn (?*anyopaque, ?*wl.Proxy, [*c]const u8, i32) callconv(.c) void,
        cancelled: *const fn (?*anyopaque, ?*wl.Proxy) callconv(.c) void,
        dnd_drop_performed: *const fn (?*anyopaque, ?*wl.Proxy) callconv(.c) void,
        dnd_finished: *const fn (?*anyopaque, ?*wl.Proxy) callconv(.c) void,
        action: *const fn (?*anyopaque, ?*wl.Proxy, u32) callconv(.c) void,
    };
};

pub const data_offer = struct {
    pub const receive: u32 = 1;
    pub const destroy: u32 = 2;

    pub const Listener = extern struct {
        offer: *const fn (?*anyopaque, ?*wl.Proxy, [*c]const u8) callconv(.c) void,
        source_actions: *const fn (?*anyopaque, ?*wl.Proxy, u32) callconv(.c) void,
        action: *const fn (?*anyopaque, ?*wl.Proxy, u32) callconv(.c) void,
    };
};

pub const primary_selection_manager = struct {
    pub const create_source: u32 = 0;
    pub const get_device: u32 = 1;
    pub const destroy: u32 = 2;
};

pub const primary_selection_device = struct {
    pub const set_selection: u32 = 0;
    pub const destroy: u32 = 1;

    pub const Listener = extern struct {
        data_offer: *const fn (?*anyopaque, ?*wl.Proxy, ?*wl.Proxy) callconv(.c) void,
        selection: *const fn (?*anyopaque, ?*wl.Proxy, ?*wl.Proxy) callconv(.c) void,
    };
};

pub const primary_selection_source = struct {
    pub const offer: u32 = 0;
    pub const destroy: u32 = 1;

    pub const Listener = extern struct {
        send: *const fn (?*anyopaque, ?*wl.Proxy, [*c]const u8, i32) callconv(.c) void,
        cancelled: *const fn (?*anyopaque, ?*wl.Proxy) callconv(.c) void,
    };
};

pub const primary_selection_offer = struct {
    pub const receive: u32 = 0;
    pub const destroy: u32 = 1;

    pub const Listener = extern struct {
        offer: *const fn (?*anyopaque, ?*wl.Proxy, [*c]const u8) callconv(.c) void,
    };
};

pub const xdg_activation = struct {
    pub const destroy: u32 = 0;
    pub const get_activation_token: u32 = 1;
    pub const activate: u32 = 2;
};

pub const xdg_activation_token = struct {
    pub const set_serial: u32 = 0;
    pub const set_app_id: u32 = 1;
    pub const set_surface: u32 = 2;
    pub const commit: u32 = 3;
    pub const destroy: u32 = 4;

    pub const Listener = extern struct {
        done: *const fn (?*anyopaque, ?*wl.Proxy, [*c]const u8) callconv(.c) void,
    };
};

pub const xdg_system_bell = struct {
    pub const destroy: u32 = 0;
    pub const ring: u32 = 1;
};
