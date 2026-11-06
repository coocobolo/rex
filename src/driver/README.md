# Driver Subsystem

The driver subsystem bridges the in-memory terminal emulation core (`src/term/`), the OS pseudo-terminal (`src/termio/pty.zig`), and the main GUI window loop (`src/App.zig`).

It exposes a polymorphic `Driver(option)` union that dispatches between synchronous single-threaded execution (`SingleDriver`) and asynchronous multi-threaded execution (`ThreadedDriver`) backed by lock-free frame triple-buffering and an atomic input queue.

## Event Systems: Emulation vs Host Domain

Rex maintains a strict separation between terminal emulation events and host platform events.

| Property | Emulation Domain (`term.Events`) | Host Presentation Domain (`driver.Events`) |
| --- | --- | --- |
| **File location** | `src/term/term.zig` | `src/driver/events.zig` |
| **Producer** | Byte stream parser (`vt.Parser`) | PTY background thread / OS file descriptor |
| **Consumer** | Driver event accumulation loops | GUI event loop (`App.run()`) |
| **Scope** | Pure in-memory ANSI/VT escape sequences | Host OS processes, rendering triggers, and synchronization |
| **Thread safety** | Unsynchronized, single-thread state machine | 64-byte aligned atomic bitset (`IntegerSet.Atomic`) |
| **Payload layout** | Packed 32-bit `EventSet` + `Resize` (8 B) | Packed 32-bit `EventSet` + `Resize` (8 B) |

### Why They Must Not Be Unified Into One Monolith

1. **Domain boundary:** `Terminal` is a pure in-memory state machine. It can be fed from tests, network streams, or static recordings. It must never depend on OS processes (`child_closed`), PTY file descriptors, or GUI redraw scheduling (`had_data`).
2. **Lifecycle difference:** Terminal events are produced inside `Terminal.feed()` by parsing incoming bytes. Host events are produced by OS kernel signals, poll timeouts, or child process termination.
3. **Atomic exchange:** The driver packages both sets into a single 32-bit word (`EventSet`) so cross-thread synchronization requires only one atomic instruction.

## Event Bits Reference

All driver events are declared in `src/driver/events.zig` inside a packed 32-bit structure (`EventBits`) wrapped by `IntegerSet(EventBits)`.

| Bit | Field | Category | Description |
| --- | --- | --- | --- |
| `0` | `bell` | Emulation | ASCII `\x07` (`BEL`) arrived; triggers an audible chime or visual bell alert. |
| `1` | `title` | Emulation | `OSC 0` or `2` updated the window title; double-buffered across threads. |
| `2` | `icon_name` | Emulation | `OSC 1` changed the window icon name. |
| `3` | `cursor_color` | Emulation | `OSC 12` changed the active cursor color. |
| `4` | `selection_reset` | Emulation | Screen buffer swap or `RIS` reset invalidating current selection highlight. |
| `5` | `hard_reset` | Emulation | `RIS` (`\x1bc`) executed; resets screen buffers, modes, and viewport positions. |
| `6` | `child_closed` | Host / OS | PTY slave exited or returned `EIO`/`EOF`; signals the GUI loop to exit. |
| `7` | `had_data` | Presentation | Bytes read from PTY or fresh frame ready; marks window `needs_redraw = true`. |
| `8` | `resize` | Transport | Internal transport bit indicating an atomic resize payload is queued. |
| `9..31` | `_pad` | Padding | Reserved bits for future expansion; ignored by `IntegerSet` logic. |

## Driver Flavors

| Characteristic | `SingleDriver` (`single.zig`) | `ThreadedDriver` (`threaded.zig`) |
| --- | --- | --- |
| **Execution Model** | Synchronous on GUI thread | Dedicated background worker thread |
| **Frame Transfer** | Direct pointer copy into `frame_snapshot` | Lock-free lockless `TripleBuffer` |
| **Event Transport** | Direct stack-allocated value transfer | Cache-aligned `EventSet.Atomic` (`align(64)`) |
| **Input Delivery** | Immediate write to PTY file descriptor | Lock-free bounded ring buffer (`InputQueue`) |
| **Primary Target** | Deterministic unit tests and debug harnesses | High-framerate, multi-core interactive GUI execution |

## Architectural Invariants

Check each modification against these rules:

- **Single atomic transfer.** Terminal and host events must share one 32-bit `EventSet`. A single atomic swap (`swap(0, .acquire)`) transfers all state in one CPU instruction, eliminating tearing and cache-line contention.
- **Flat layouts with zero allocations.** Resizing, polling, and frame swaps must never allocate on the heap. Frame snapshots and triple buffers are embedded directly into driver structs.
- **Cache line isolation.** Cross-thread atomic variables (`shared_events`, `shared_modes`, `shared_resize`) must be aligned to 64 bytes (`align(64)`) to eliminate false sharing.
- **Branchless event accumulation.** Drivers accumulate VT events via `dst.accumulateTerm(src)`, which uses `IntegerSet.setUnion` for a single-cycle bitwise `OR`.
- **Title double-buffering.** Title strings are double-buffered (`shared_title: [2][max_title_len]u8`) and synchronized via an atomic index (`shared_title_idx`) with acquire/release semantics.
