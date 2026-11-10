# 0002: Draw the newest frame shortly before vblank

- Status: accepted
- Date: 2026-11-10
- Deciders: Kbgjtn (maintainer)
- Tickets: draft #22 (this investigation), draft #56 (implementation)

## Context

Under output load, a key still takes about 12 ms from the GLFW callback to
`swapBuffers` returning. #21 brought queued-to-written down to 8.5 µs
median and left this tail. The machine is the one in
`docs/perf/baseline-2026-11.md`: X11, NVIDIA GeForce GTX 1650 SUPER,
2560x1440 at 165 Hz. One refresh is 6.06 ms. `glfwSwapInterval(1)` is set
when the context is created (`src/renderer/Window.zig`).

The #21 trace (`gui-20261110T011559_eba5d33-dirty_ReleaseFast`, 1,000 of
1,000 keys matched) splits the loaded median like this:

| Step | Median |
|---|---|
| key callback -> frame published | 490 µs |
| published -> picked by the GUI | 5.5 ms |
| picked -> frame built -> drawn | 182 + 87 µs |
| drawn -> `swapBuffers` returned | 5.8 ms |
| **key -> swapped** | **12.1 ms** |

770 of 1,000 keys were published within 1 ms of the callback. 993 of 1,000
were first picked 4.5–7.5 ms after the callback, which is one refresh.
921 then waited more than 4 ms in `swapBuffers`. On an idle terminal the
same build picks the frame 11 µs after it is published and `swapBuffers`
returns in about 40 µs, because a swap 50 ms after the previous one finds
the interval already elapsed.

The driver does not queue those frames. `src/driver/triple_buffer.zig` is a
mailbox: publish swaps the fill buffer into one ready slot, and the GUI's
`acquireLatest` takes that slot and drops anything in between. Neither side
blocks on the mailbox.

The extra frame comes from the order of the GUI loop in `App.run`
(`src/App.zig`). Each turn polls the driver, builds and draws, blocks in
`swapBuffers` (`renderFrame`), and only then runs `glfwPollEvents`
(`waitForNextEvent`). A key is delivered in that poll. The worker publishes
its echo a fraction of a millisecond later (`src/driver/threaded.zig`),
which is after `getFrame` has already latched the previous snapshot and
`swapBuffers` is blocking until the next vblank. The echo sits in the
mailbox until the following turn, and that turn's swap waits out another
refresh. Two refreshes, about 12 ms.

What is measured: the stage times above, on X11 with this NVIDIA driver,
and the loop order in the source. What is not measured: Wayland, macOS,
Mesa, and any of the schedules below. Time before the key callback and
after `swapBuffers` returns is still #10.

## Decision

When a frame is going to be drawn, poll input and the driver first, then
wait until shortly before the next vblank, then build, draw, and swap the
newest frame. The wait keeps dispatching window events, so a key typed
during it reaches the worker before the draw. Estimate that vblank from
the clock time the previous `swapBuffers` returned, and correct the
estimate from how long the next swap blocked: a swap that returns
immediately means the draw was late, and a swap that blocks for a whole
refresh means the draw was early.

Keep `glfwSwapInterval(1)`. Do not change the worker loop or the mailbox.
An idle window keeps today's `waitForNextEvent` sleep. The deadline runs
only on a turn that already has something to draw, so a quiet terminal
does not gain a 6 ms sleep between keys.

Draft #56 is that change. It measures the loaded and quiet traces on this
machine. Wayland, macOS, and Mesa stay unmeasured.

## Alternatives considered

- **`glXDelayBeforeSwapNV`.** This is the same late latch, with the driver
  naming the deadline. It is an X11 GLX extension. macOS and Wayland do
  not have it. A portable loop that only needs `swapBuffers` and a clock
  covers the platforms Rex already targets. The extension can replace the
  estimate later on drivers that advertise it.
- **Presentation feedback** (`GLX_OML_sync_control`, Wayland
  `presentation-time`). These name the real vblank instead of estimating
  it from when `swapBuffers` returned. They are per-platform, and the
  return time is already the vblank on the loaded path, which is the path
  that blocks. The estimate is the schedule; a later change can feed it a
  better clock without moving the draw.
- **After a key, wait up to about 1 ms for its echo, then swap
  immediately.** That would catch the same vblank for a typed key, which
  is the whole 12 ms to 6 ms cut. Output that arrives during the rest of
  the frame would still be a refresh late, and the wait is a special case
  on the input path. Latching every drawn frame late covers keys and
  output with one schedule.
- **`glFinish` or a fence after the swap.** Caps how many frames the GPU
  can have queued. The mailbox already keeps one frame, and build plus
  draw is under 0.3 ms, so the GPU is not holding a second frame. The
  extra refresh is the early latch in `App.run`, which a fence does not
  move.
- **Swap interval 0, or adaptive vsync that is allowed to tear.** Drops
  the blocking swap. The idle trace already shows an unlocked swap
  returning in tens of microseconds, and the loaded path would tear or
  run the GUI as fast as it can draw. Not the default.
- **Present through a mailbox that does not block (Wayland immediate /
  mailbox).** Not available on X11 GLX, which is where the 12 ms was
  measured.

## Consequences

- Loaded key-to-swap should fall from about two refreshes to about one,
  because the echo's sub-millisecond publish fits in the wait before
  vblank. The median would sit somewhere inside that refresh, depending
  on when the key arrives. #56 has to measure it. A miss (the draw runs
  past the deadline) costs one extra refresh, which is today's steady
  state.
- Build and draw of a full dirty frame were 0.27 ms median on this GPU.
  The first margin has to be larger than that, with room for a slower
  frame, and the correction from the swap's block time is what keeps it
  honest. A wellbeing overlay or a weaker GPU can need a wider margin.
- The quiet path stays event-driven. Arming the deadline only when a
  frame is already due is what keeps the idle median near 0.24 ms.
- No new allocation on the driver thread. The wait is a sleep on the GUI
  thread.
- Wayland and macOS are expected to behave the same only because the wait
  uses the clock and `swapBuffers`. #56's measurement is still X11 until
  someone runs it elsewhere.
