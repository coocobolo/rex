# 0001: Keep GLFW behind a Rex-owned platform interface, native Wayland by default

- Status: accepted
- Date: 2026-11-07
- Deciders: Kbgjtn (maintainer)
- Tickets: to be linked once the issues exist (drafts 2-7 and 17)

## Context

Rex v1 targets Linux and macOS, and Windows must remain possible. The v1
requirements, decided on 2026-11-06, are:

- Linux on X11 and Wayland, with **native Wayland** required, because
  XWayland doesn't give sharp fractional scaling;
- HiDPI and fractional scaling, tested at 125%, 150% and 175%, including
  moves between monitors with different scales;
- CLIPBOARD and PRIMARY selection on Linux where available;
- an architecture that is IME-ready, even if native IME support arrives
  incrementally;
- a single window;
- OpenGL 3.3 core as the GPU baseline.

Rex uses GLFW 3.5.1 directly since `ecd4470` (2026-11-07), built with the
X11 backend only. GLFW appears in three files:

- `src/renderer/Window.zig`: 46 GLFW calls, and GLFW callback types in its
  API;
- `src/App.zig`: 13 GLFW calls, including the clipboard and the event-loop
  wakeup (`glfwPostEmptyEvent`, `glfwWaitEventsTimeout`);
- `src/input.zig`: no calls, but its API works on GLFW key codes and
  modifier bits (`Modifiers.fromGlfw`), so key bindings and the xterm key
  encoding depend on GLFW's constants.

The upgrade from 3.3.10 to 3.5.1 also showed:

- GLFW has no bell API. Rex rings the bell itself through Xlib
  (`ringBellX11` in `src/renderer/Window.zig`), opening a new X connection
  per bell, and links `libX11` only for that.
- GLFW loads its X11, GL, EGL and Wayland libraries at runtime with
  `dlopen`, so none of them is a link-time dependency. The Linux build
  links only `libX11` (for the bell) and needs glibc 2.34 or later.
- Since 3.4 a binary may contain native access functions for several
  platforms, so code must check `glfwGetPlatform()` before it calls a
  `glfwGetX11*` or `glfwGetWayland*` function.
- On X11, `glfwPostEmptyEvent` now uses a pipe instead of a round trip
  through the X server. Measured in the same session before and after the
  upgrade, idle wakeups and output throughput didn't change.

## Evidence: GLFW 3.5.1 against the requirements

Checked on 2026-11-06 and 2026-11-07 against glfw.org's documentation and
release notes (3.4 and 3.5), the GitHub releases page, PR #2130, and the
GLFW 3.5.1 source (`src/wl_init.c`, `src/wl_window.c`, `src/x11_init.c`,
`src/CMakeLists.txt`, `include/GLFW/glfw3.h`, `include/GLFW/glfw3native.h`).

| Requirement | GLFW 3.5.1 | Since |
|---|---|---|
| Wayland or X11 chosen at runtime in one binary | `GLFW_PLATFORM` init hint, `glfwPlatformSupported`, `glfwGetPlatform`. Prefers Wayland when both are available and honours `XDG_SESSION_TYPE`. | 3.4 |
| Fractional scaling on Wayland | `fractional-scale-v1` with `wp_viewporter`; the framebuffer is rendered at the native fractional size. Without the protocol, the integer scale rounded up. Content-scale and framebuffer-size callbacks fire on scale changes. | 3.4, fixed in 3.5 |
| Framebuffer scaling control | `GLFW_SCALE_FRAMEBUFFER` (Wayland, macOS), allowed by default | 3.4 |
| Wayland decorations | libdecor (loaded at runtime, preferred), then xdg-decoration, then a basic frame | 3.3.9 |
| X11 PRIMARY | `glfwSetX11SelectionString` and `glfwGetX11SelectionString` (main thread only). Rex doesn't use them yet. | 3.3 |
| Wayland primary selection | Not supported: no `zwp_primary_selection` binding | none |
| IME and preedit | Not released: character events only. PR #2130 (text-input v3 and v1, preedit callback) is still open. | none |
| Native access on Wayland | `wl_display`, `wl_output` and `wl_surface` only. `wl_seat` and input-event serials, which primary selection and IME need, are internal. | 3.2-3.5 |
| Bell | No API | none |
| Wayland build | `wayland-scanner` generates code from the protocol XML files in `deps/wayland/` at build time; needs the wayland-client, wayland-cursor, wayland-egl and xkbcommon headers. The libraries themselves are loaded at runtime. | - |

## Decision

1. **Keep GLFW as the platform implementation**, at 3.5.1 (done), with both
   X11 and Wayland compiled in.
2. **Rex defines its own platform interface** for windowing, the GL
   context, events, input, text input and IME, clipboard and selection,
   scaling, bell and attention, and event-loop wakeup. GLFW is the first
   implementation. No GLFW type, constant or call appears outside the
   platform layer; this includes the key codes and modifier bits that
   `src/input.zig` uses today.
3. **Native Wayland by default** on Wayland sessions, chosen explicitly
   through `GLFW_PLATFORM`, with an explicit user override to force X11.
   The selected backend is logged and never silently degraded: if the
   Wayland libraries or protocols Rex needs are missing, Rex says so and
   either falls back to X11 explicitly, with a log line, or stops with a
   clear error.
4. **Adapters for capabilities GLFW lacks**, behind the same interface, each
   checking `glfwGetPlatform()` before using native access: X11 PRIMARY
   through GLFW's selection functions; the bell on X11 through GLFW's own X
   connection, with a defined behaviour on other platforms; Wayland primary
   selection and IME through a Rex adapter, subject to a prototype that
   shows we can bind our own `wl_seat`, and get input serials, next to
   GLFW's `wl_display`.
5. **Text input and IME are separate from key events** in Rex's own input
   model: logical and physical keys, modifiers, text, preedit with a cursor
   and selection range, and candidate-window positioning.
6. **Compositor test matrix for Linux v1:** GNOME/Mutter, KDE/KWin and
   Sway/wlroots on Wayland; one X11 session; one compositor without
   fractional-scale-v1. Native Wayland, fractional scaling, clipboard,
   PRIMARY and IME are tested separately.

## Alternatives considered

- **GLFW used directly (status quo):** least work, but GLFW leaks into
  application code (three files, including the key encoding), and the
  missing capabilities have nowhere to go.
- **Native backends only (Wayland, X11, Cocoa):** full control, but a large
  implementation and maintenance cost for requirements GLFW 3.5.1 mostly
  covers already. Not justified by current evidence.
- **Waiting for upstream IME (PR #2130):** the architecture would depend on
  an unmerged pull request with no committed release.
- **XWayland only on Linux:** conflicts with the fractional-scaling
  requirement.

## Consequences

- **Performance:** the interface is a thin layer of direct calls, with the
  backend chosen at compile time per OS and Wayland or X11 chosen at
  runtime by GLFW. No dynamic dispatch on hot paths is expected; this has
  to be checked against the performance baseline
  (`docs/perf/baseline-2026-11.md`) when the interface is extracted.
- **Complexity:** a new platform module; a Wayland protocol build step
  (`wayland-scanner`, or vendored generated code); key and modifier types
  of Rex's own, replacing GLFW's in `src/input.zig`.
- **Dependencies:** the binary has no link-time dependency on Wayland, GL,
  EGL or the X11 extension libraries. `libX11` stays linked only until the
  bell goes through GLFW's connection. Building needs the X11 (and, with
  Wayland, the Wayland) development headers and glibc 2.34 or later.
- **Failure behaviour:** a missing capability, such as no fractional-scale
  or no primary-selection protocol, is reported and degrades to a defined
  fallback (integer scaling, CLIPBOARD only). A missing platform or GL
  context fails at startup with a clear message, as in decision 3.
- **Maintenance in three years:** GLFW is a mature, maintained dependency;
  our own code is limited to the interface and the adapters. If the
  `wl_seat` prototype fails, a new ADR decides between patching GLFW,
  forking it, and writing a native Wayland backend.
- **Incremental path:** OpenGL 3.3 core (done), GLFW 3.5.1 (done,
  `ecd4470`), then the bell through GLFW's connection, then the Wayland
  build, then the platform interface extraction, then the adapters (X11
  PRIMARY, then the Wayland prototype). Rex stays usable at every step.
