//! Platform events and the bounded ring that carries them from a backend to
//! the application. Native-free: no backend type, I/O or allocation reaches
//! this file. ADR 0011 decision 5 keeps text and preedit separate from keys.

const std = @import("std");

const Key = @import("../input/key.zig").Key;
const Modifiers = @import("../input/key.zig").Modifiers;
const Window = @import("Window.zig");

/// Key press, release or auto-repeat. GLFW reports repeat as a press today;
/// the distinction is kept so a native backend can report it precisely.
pub const Action = enum { press, release, repeat };

/// The mouse buttons a backend can report.
pub const MouseButton = enum { left, middle, right };

/// A key transition on a window, with the modifiers held at that moment.
pub const KeyEvent = struct {
    window: Window,
    key: Key,
    mods: Modifiers,
    action: Action,
};

/// A printable codepoint delivered separately from its key event.
pub const TextEvent = struct {
    window: Window,
    codepoint: u21,
};

/// Preedit text with a cursor and selection range, in bytes. A backend with
/// no IME emits nothing; the fixed buffer keeps it allocation-free. 32 bytes
/// fit ten 3-byte CJK characters; a longer preedit is dropped whole, never
/// truncated. Keeping this variant small keeps every event small.
pub const PreeditEvent = struct {
    window: Window,
    text: [32]u8 = undefined,
    len: u8 = 0,
    cursor: u8 = 0,
    selection: u8 = 0,
};

/// A mouse button transition, with the modifiers held at that moment.
pub const MouseButtonEvent = struct {
    window: Window,
    button: MouseButton,
    action: Action,
    mods: Modifiers,
};

/// Position in logical pixels, as the backend reports it.
pub const CursorPosEvent = struct {
    window: Window,
    x: f64,
    y: f64,
};

/// Wheel movement in logical pixels, positive right and down.
pub const ScrollEvent = struct {
    window: Window,
    dx: f64,
    dy: f64,
};

/// Whether the pointer entered or left the window.
pub const CursorEnterEvent = struct {
    window: Window,
    entered: bool,
};

/// Whether the window gained or lost input focus.
pub const FocusEvent = struct {
    window: Window,
    focused: bool,
};

/// The drawable size in pixels after a resize.
pub const FramebufferSizeEvent = struct {
    window: Window,
    width: u32,
    height: u32,
};

/// The scale from logical to device pixels reported by the backend.
pub const ContentScaleEvent = struct {
    window: Window,
    x: f32,
    y: f32,
};

/// A request from the window system to close the window.
pub const CloseEvent = struct {
    window: Window,
};

/// An event from a backend. Every variant names the window it belongs to.
pub const Event = union(enum) {
    key: KeyEvent,
    text: TextEvent,
    preedit: PreeditEvent,
    mouse_button: MouseButtonEvent,
    cursor_pos: CursorPosEvent,
    scroll: ScrollEvent,
    cursor_enter: CursorEnterEvent,
    focus: FocusEvent,
    framebuffer_size: FramebufferSizeEvent,
    content_scale: ContentScaleEvent,
    close: CloseEvent,
};

/// Power of two, so the indices wrap with a mask. Fixed storage keeps event
/// delivery allocation-free; a backend never pushes into a full ring.
pub const capacity = 256;

/// `read` and `len` are the only mutable state; the write index is derived,
/// so the ring cannot disagree with itself about how full it is.
pub const Ring = struct {
    events: [capacity]Event = undefined,
    read: u16 = 0,
    len: u16 = 0,
    /// Events dropped because the ring was full. The consumer logs and
    /// resets it once per drain, so a burst cannot spam the log.
    dropped: u32 = 0,

    fn writeIndex(self: *const Ring) u16 {
        return (self.read + self.len) & (capacity - 1);
    }

    /// The number of events waiting to be drained.
    pub fn count(self: *const Ring) usize {
        return self.len;
    }

    /// Drops the newest event when full. Key and text events are more
    /// important than pointer noise, but coalescing is a later measurement,
    /// not part of this interface.
    pub fn push(self: *Ring, event: Event) void {
        if (self.len == capacity) {
            self.dropped += 1;
            return;
        }
        self.events[self.writeIndex()] = event;
        self.len += 1;
    }

    /// Copies the oldest event into `out` and advances the ring. `Event` is
    /// 56 bytes, so the copy is explicit at the call site instead of hidden
    /// in a returned value.
    pub fn next(self: *Ring, out: *Event) bool {
        if (self.len == 0) return false;
        out.* = self.events[self.read];
        self.read = (self.read + 1) & (capacity - 1);
        self.len -= 1;
        return true;
    }

    /// Returns the number dropped since the last drain and clears the counter.
    pub fn takeDropped(self: *Ring) u32 {
        const n = self.dropped;
        self.dropped = 0;
        return n;
    }
};
