//! Optional per-stage input latency tracing, built with `-Dtrace-latency`.
//!
//! A traced key gets a sequence number when its bytes are sent to the
//! driver, and each stage it passes records a `CLOCK_MONOTONIC` timestamp
//! in that key's `Record`. On exit the records are written as CSV.
//!
//! Matching assumes one key in flight: the first pty read after a key's
//! bytes are written counts as that key's echo. A key that is still
//! waiting when the next one is written keeps zeros in its later stages
//! and counts as unmatched. Drive it with keys spaced further apart than
//! one round trip (the harness waits between keys).
//!
//! Threads: the GUI thread writes the `key`, `queued`, `picked`, `drawn`
//! and `swapped` columns, the driver worker writes `written`, `echoed` and
//! `published`. They write different fields, so no locking is needed.
//! `input_seq` hands a sequence number from the GUI to the worker, and the
//! worker hands it back with each published frame through the triple
//! buffer's slot ownership (see `ThreadedDriver`). A record is reused
//! after `capacity` keys; that only collides with a stage still being
//! written if 4096 keys are in flight, which the one-in-flight rule rules
//! out. The CSV is read only after the worker thread has been joined.
//!
//! The types here are always compiled so their tests run in every build;
//! the hooks in the driver and `App` exist only when `enabled`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Whether this build records latency (`-Dtrace-latency`).
pub const enabled = @import("build_options").trace_latency;

/// The trace a driver writes to: a `*Trace` when tracing is built in,
/// nothing otherwise.
pub const Handle = if (enabled) ?*Trace else void;
/// A `Handle` that traces nothing, for drivers created without a trace.
pub const none: Handle = if (enabled) null else {};

/// The points a traced key passes, in order. The names are the CSV
/// column names.
pub const Stage = enum(u3) {
    /// GLFW key callback for the press (t0).
    key,
    /// Bytes pushed onto the driver's `InputQueue` (t1).
    queued,
    /// All of the key's bytes accepted by the pty (t2, worker).
    written,
    /// First pty read after the write returned (t3, worker).
    echoed,
    /// A frame containing that read published (t4, worker).
    published,
    /// `renderFrame` took that frame (t5a).
    picked,
    /// Draw calls for it submitted, before `swapBuffers` (t5b).
    drawn,
    /// `swapBuffers` returned; includes the vsync wait (t6).
    swapped,
};

pub const stage_count = @typeInfo(Stage).@"enum".fields.len;

/// Number of keys kept; older ones are overwritten.
pub const capacity = 4096;

/// One traced key. A zero timestamp means the stage wasn't reached.
pub const Record = struct {
    /// 0 marks an unused slot; sequence numbers start at 1.
    seq: u32 = 0,
    t: [stage_count]u64 = @splat(0),
};

/// Nanoseconds on the clock every stage uses.
pub fn now(io: Io) u64 {
    return @intCast(Io.Clock.awake.now(io).toNanoseconds());
}

/// The shared record table plus the GUI thread's bookkeeping. Created by
/// the app, which owns it and destroys it after the driver.
pub const Trace = struct {
    /// Latest sequence number whose bytes the GUI sent. Written by the GUI
    /// thread before it pushes the bytes, read by the worker.
    input_seq: std.atomic.Value(u32) align(64) = .init(0),

    /// Heap-allocated, `capacity` entries, indexed by `seq % capacity`.
    records: *[capacity]Record,

    // GUI thread only from here on.

    /// Last sequence number handed out.
    next_seq: u32 = 0,
    /// Time of a key press whose bytes haven't been sent yet. Cleared after
    /// each batch of events, so a press that sends nothing doesn't lend its
    /// time to a later character.
    pending_key: u64 = 0,
    /// Sequence number of the newest frame `renderFrame` has taken.
    last_picked: u32 = 0,
    /// A taken frame that hasn't been drawn yet.
    pending_draw: u32 = 0,

    pub fn create(gpa: Allocator) Allocator.Error!*Trace {
        const records = try gpa.create([capacity]Record);
        errdefer gpa.destroy(records);
        records.* = @splat(.{});
        const self = try gpa.create(Trace);
        self.* = .{ .records = records };
        return self;
    }

    pub fn destroy(self: *Trace, gpa: Allocator) void {
        gpa.destroy(self.records);
        gpa.destroy(self);
    }

    fn record(self: *Trace, seq: u32) *Record {
        return &self.records[seq % capacity];
    }

    /// Records `stage` for `seq`. Each thread calls it only for its own
    /// stages (see the file comment).
    pub fn stamp(self: *Trace, seq: u32, stage: Stage, t: u64) void {
        std.debug.assert(seq != 0);
        self.record(seq).t[@intFromEnum(stage)] = t;
    }

    // GUI thread.

    /// A key was pressed; its bytes may follow from the key or the char
    /// callback.
    pub fn keyPressed(self: *Trace, t: u64) void {
        self.pending_key = t;
    }

    /// The GUI finished handling a batch of window events.
    pub fn eventsHandled(self: *Trace) void {
        self.pending_key = 0;
    }

    /// Starts tracing bytes about to be pushed to the driver: assigns the
    /// next sequence number, stamps `key` (the pending press, or `t` for
    /// text without a press such as input-method commits) and publishes the
    /// number to the worker. Stamp `queued` once the push succeeded.
    pub fn beginSend(self: *Trace, t: u64) u32 {
        self.next_seq +%= 1;
        if (self.next_seq == 0) self.next_seq = 1;
        const seq = self.next_seq;
        const rec = self.record(seq);
        rec.* = .{ .seq = seq };
        rec.t[@intFromEnum(Stage.key)] = if (self.pending_key != 0) self.pending_key else t;
        self.pending_key = 0;
        self.input_seq.store(seq, .release);
        return seq;
    }

    /// `renderFrame` took a frame whose newest echo belongs to `seq`
    /// (0: none). Stamps `picked` the first time a sequence number shows up.
    pub fn framePicked(self: *Trace, seq: u32, t: u64) void {
        if (seq == 0 or seq == self.last_picked) return;
        self.last_picked = seq;
        self.pending_draw = seq;
        self.stamp(seq, .picked, t);
    }

    /// Draw calls were submitted. Returns the sequence number to stamp
    /// `swapped` for after `swapBuffers`, or 0.
    pub fn frameDrawn(self: *Trace, t: u64) u32 {
        const seq = self.pending_draw;
        if (seq == 0) return 0;
        self.pending_draw = 0;
        self.stamp(seq, .drawn, t);
        return seq;
    }

    /// Writes every used record, oldest first, as CSV with a header line.
    /// Call only after the worker thread has stopped.
    pub fn writeCsv(self: *const Trace, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll("seq");
        inline for (@typeInfo(Stage).@"enum".fields) |field| {
            try w.writeAll("," ++ field.name);
        }
        try w.writeByte('\n');

        // The slot after the newest record holds the oldest one once the
        // table has wrapped.
        var i: usize = 0;
        while (i < capacity) : (i += 1) {
            const rec = &self.records[(self.next_seq +% 1 +% i) % capacity];
            if (rec.seq == 0) continue;
            try w.print("{d}", .{rec.seq});
            for (rec.t) |t| try w.print(",{d}", .{t});
            try w.writeByte('\n');
        }
    }

    /// Writes the CSV to `path`, replacing the file and creating its
    /// directory if needed. Call only after the worker thread has stopped.
    pub fn writeFile(self: *const Trace, io: Io, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
        const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var fw = file.writer(io, &buffer);
        self.writeCsv(&fw.interface) catch |err| switch (err) {
            error.WriteFailed => return fw.err.?,
        };
        fw.interface.flush() catch return fw.err.?;
    }
};

/// The worker thread's side of the matching. Lives on the worker's stack.
pub const Worker = struct {
    /// Last `input_seq` seen.
    seen: u32 = 0,
    /// Bytes for this key are queued but not all written yet.
    awaiting_write: u32 = 0,
    /// Written; the next pty read is its echo.
    awaiting_echo: u32 = 0,
    /// Newest key whose echo has been read; tagged on published frames.
    echoed: u32 = 0,
    /// Newest key whose echo was in a published frame.
    published: u32 = 0,

    /// After the input queue was drained.
    pub fn inputHandled(self: *Worker, trace: *Trace) void {
        const seq = trace.input_seq.load(.acquire);
        if (seq == self.seen) return;
        self.seen = seq;
        // A key still waiting to be written is superseded: unmatched.
        self.awaiting_write = seq;
    }

    /// After a flush; `drained` is whether every queued byte was written.
    pub fn flushed(self: *Worker, trace: *Trace, drained: bool, t: u64) void {
        if (self.awaiting_write == 0 or !drained) return;
        trace.stamp(self.awaiting_write, .written, t);
        self.awaiting_echo = self.awaiting_write;
        self.awaiting_write = 0;
    }

    /// The first pty read of a batch returned data at `t`.
    pub fn read(self: *Worker, trace: *Trace, t: u64) void {
        if (self.awaiting_echo == 0) return;
        trace.stamp(self.awaiting_echo, .echoed, t);
        self.echoed = self.awaiting_echo;
        self.awaiting_echo = 0;
    }

    /// A frame tagged with `echoed` was published at `t`.
    pub fn framePublished(self: *Worker, trace: *Trace, t: u64) void {
        if (self.echoed == 0 or self.echoed == self.published) return;
        self.published = self.echoed;
        trace.stamp(self.echoed, .published, t);
    }
};
