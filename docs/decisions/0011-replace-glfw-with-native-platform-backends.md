# 0011: Replace GLFW with native window-system backends behind a Rex-owned platform interface

- Status: accepted
- Date: 2026-11-17
- Deciders: Kbgjtn (maintainer)
- Supersedes: 0001 (decisions 1, 2 and 4); amends 0007 (decision 4)
- Tickets: to be filed; staged plan in the maintainer's private working notes

## Context

ADR 0001 (accepted 2026-11-07) chose GLFW 3.5.1 as the platform implementation and
decided that Rex should own a platform interface with no GLFW outside it. ADR 0007
(2026-11-11) carried out the key part: `Key`, `Modifiers`, bindings and the encoder
now live in a GLFW-free `src/input/`, with translation at the edge in
`renderer/glfw_key.zig`.

What ADR 0001's incremental path has delivered (read from code, 2026-11-17):
GL 3.3 core, GLFW 3.5.1 with runtime X11/Wayland choice and explicit fallback
(`renderer/Window.zig:44-90`), the bell on GLFW's own X connection
(`Window.zig:101-138, 342-366`), X11 PRIMARY, and key translation.

What has not been built: the interface itself. GLFW is still in the public API of
`renderer/Window.zig` (opaque `handle: *c.GLFWwindow` at `:140`, `c.GLFW*fun`
callback setters at `:452-535`, and wrappers named `glfwPollEvents`,
`glfwPostEmptyEvent`, `glfwWaitEvents` at `:382-450`). `App.zig` has roughly sixteen
GLFW sites (C callbacks at `:2545-3512`, clipboard at `:1356, 2985`, `glfwGetKey` at
`:1118, 3368`, event loop at `:1159-1214`) and hands `Window.glfwPostEmptyEvent` to
the driver and `FileWatch` as the wakeup function (`:730, 1536`).
`tool/host.zig:480-570` carries a second set of GLFW callbacks for tool windows.
GLAD is loaded through `glfwGetProcAddress` (`Window.zig:282-287`), so GL
initialization is coupled to GLFW too.

Two facts changed since ADR 0001. First, ADR 0008 introduced separate tool windows,
so the old "single window" assumption (0001, `:20`) is obsolete: the interface must
be multi-window. Second, on 2026-11-17 the maintainer chose **full native backends**
over the interface-only/GLFW-first recommendation. That reverses ADR 0001 decision 1
(keep GLFW as the platform implementation) and v1 priority P4 (alternative backends
only when justified), and retires the role of `renderer/glfw_key.zig` from ADR 0007
decision 4 once GLFW is gone.

Existing draft tickets this ADR absorbs: #6 (Wayland `wl_seat` and input serials —
evidence gathered 2026-11-17) becomes an evidence step rather than a decision gate;
#19 (audible bell on Wayland) moves from GLFW native access to the native Wayland
backend; #7 (macOS/Cocoa build) is done and is the base for the Cocoa backend. Their
findings and acceptance criteria carry forward.

Evidence gathered on 2026-11-17 before acceptance: a throwaway probe on nested
Sway 1.9 bound a Rex-owned `wl_seat` v8 and received real input serials (key event
serial 21, focus-enter serial 19), and text-input-v3 and primary-selection were
bound on that same seat. A second probe created an EGL 1.5 display and GL context
by `dlopen`ing EGL and X11 with no link-time dependency on either. Both are
feasibility results, not implementations. Assumed, not measured: the effort and
performance of the three native backends, and whether a 3.3-core EGL context can
be obtained through GLVND on this host (the probe got a compatibility profile;
`eglCreateContextAttribs*` resolved to null despite `EGL_KHR_create_context`).
No build, test or perf run of Rex itself was performed for this decision.

## Decision

1. **Rex owns `src/platform/`**, a native-free leaf module defining the platform
   interface: window lifecycle, GL context (including the GLAD symbol loader),
   events, text input and preedit, CLIPBOARD and PRIMARY, HiDPI/scale, pointer,
   bell/attention and event-loop wakeup. No backend type, constant or call appears
   outside the backend that implements it.
2. **The interface is multi-window.** `createWindow(options)` returns independent
   windows; the terminal and each tool window consume the same event contract
   (ADR 0008).
3. **Native backends are the v1 platform implementations:** Wayland and X11 on
   Linux/FreeBSD, Cocoa on macOS. The backend is selected at compile time per OS and
   session, with no runtime vtable or dynamic dispatch on hot paths. A forced
   platform that cannot start fails with a clear message; there is no silent
   degradation to a different window system.
4. **GLFW is a temporary migration backend** behind the same interface. It exists
   only so each stage stays buildable and measurable, and is removed from the
   dependency set, build and tree before v1. It is not a shipped platform.
5. **Text and preedit are first-class events**, separate from keys (ADR 0001
   decision 5, ADR 0007). The GLFW migration backend reports empty preedit; Wayland
   fills it from text-input-v3 and Cocoa from `NSTextInputClient`. This is event
   plumbing, not an IME implementation or candidate UI.
6. **Capabilities GLFW lacks are implemented in each native backend**: X11
   selection ownership for CLIPBOARD/PRIMARY and `XBell`, Wayland data-device and
   primary-selection protocols plus `xdg-system-bell-v1` or `gtk_shell1` (#19),
   `NSPasteboard` and `NSBeep` on Cocoa. No backend reaches through another
   platform library for these.
7. **No new link-time dependency on GL, EGL, Wayland or X11 extension libraries.**
   Native libraries are loaded at runtime; generated Wayland protocol code is
   vendored like the other generated tables. Headers, `wayland-scanner`, protocol
   XML and any other new build-time dependency need explicit approval before they
   are added to the repo or CI.
8. **Out of scope:** Win32, a graphics-API rewrite (Metal/Vulkan), full IME candidate
   UI, and audio-bell libraries. Revisit each with evidence and a new ADR.

## Alternatives considered

- **Interface only, GLFW as the shipped backend (recommended in chat, declined):**
  far smaller, keeps a mature dependency, and ADR 0001 already decided it. Rejected
  by the maintainer on 2026-11-17.
- **Keep GLFW for macOS only:** avoids native Cocoa work, but leaves two platform
  models to maintain and keeps GLFW in the dependency set. Rejected with decision 4.
- **Runtime vtable/pluggable backends:** lets a backend be chosen or loaded at run
  time, but adds dispatch cost to event processing; ADR 0001 expects none. Rejected
  unless a measurement shows it is free.
- **Patch or fork GLFW for `wl_seat`/IME/bell (#6's old fork option):** smaller than
  a native backend but owns a fork of a C library and still cannot provide Cocoa or
  a clean multi-window model. Superseded by decision 3.
- **XWayland only:** conflicts with the fractional-scaling requirement (ADR 0001).

## Consequences

- **Problem:** GLFW types leak into `Window.zig`, `App.zig` and `tool/host.zig`, and
  GLFW has no IME, preedit, Wayland PRIMARY or bell API. A Rex-owned interface gives
  those capabilities a home and makes the app window-system agnostic.
- **Performance:** the interface uses compile-time backend selection and a
  fixed-capacity event ring, so no dynamic dispatch or per-event allocation is
  expected. Each backend stage is A/B tested against a fresh baseline of the GLFW
  build recorded at `docs/perf/baseline-2026-11-17-platform-revamp.md`, on
  keystroke-to-pty latency, frame time, idle wakeups and throughput, before it can
  replace the old backend. The baseline is a reference, not a result of this ADR.
- **Complexity:** substantially higher than ADR 0001's plan. Three window systems,
  EGL context management, xkbcommon key translation, Wayland protocols and scanner,
  native clipboard/PRIMARY ownership, IME/preedit on two systems, HiDPI across
  monitors, and a multi-window event model. This is the dominant cost of the choice.
- **Failure behaviour:** a missing native library or protocol is reported once and
  degrades to a defined fallback (e.g. attention-only bell, CLIPBOARD without
  PRIMARY), matching ADR 0001's principle. A missing window system or GL context
  fails at startup with a clear message; no silent fallback for a forced choice.
- **Maintenance in three years:** Rex owns more code but no longer depends on GLFW
  for platform behavior. Wayland protocol churn and compositor differences become
  Rex's responsibility; vendored generated code and a documented compositor matrix
  are the mitigation.
- **Incremental path:** interface plus GLFW behind it first (a useful stopping point
  on its own), then X11, Wayland and Cocoa backends, then GLFW removal. At every
  stage the full suite and the GUI smoke must stay green, with verification and
  diff review before each commit and merge.
- **Breaking changes:** `[window] platform` keeps its `auto|wayland|x11` meaning;
  tool windows keep their ADR 0008 behavior. Config keys do not change in the first
  stage. Removal of GLFW is internal.
