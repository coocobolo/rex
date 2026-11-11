# 0007: Encode keys in a GLFW-free `input/` module that `term/` may import

- Status: accepted
- Date: 2026-11-11
- Deciders: Kbgjtn (maintainer)
- Tickets: draft #82 (split from #70 stage 5)

## Context

xterm answers XTGETTCAP key names (`kcuu1`, `kf1`, ...) by running the
name through its own key encoder with the current modes (`misc.c` do_dcs),
so the reply is exactly what the key would send. Rex answers only
`Co`/`colors`, `RGB` and `TN`/`name` (`requestTermcap` in
`src/term/term.zig`) and reports every key name as unknown, because its
encoder cannot be reached from `term/`.

`src/input.zig` (978 lines at `3c6e0db`) holds four things:

- `Key` (`enum(u16)`) and `Modifiers` (`packed struct(u8)`), which are
  Rex's own types except for their `fromGlfw` and `toGlfw` methods;
- key bindings (`Action`, `Binding`, `default_keymap`, `matchBinding`),
  imported by `config/` and `ui/Kbd.zig`;
- GLFW helpers (`isModifierKey`, `glfwModsToMouseMods`);
- the xterm key encoder (`encodeKey` and the modifyOtherKeys logic), which
  takes GLFW key codes and modifier bits as `c_int` and switches on
  `c.GLFW_KEY_*`.

Three rules meet here. `term/` depends only on `vt/`, `unicode/` and
`color/` and does no I/O. ADR 0001 (decision 2) says no GLFW type, constant
or call appears outside the platform layer, and names the key codes in
`src/input.zig`. The fuzz module builds without native dependencies, yet
`config/keybind.zig` imports `input.zig`, which imports GLFW; that works
only because nothing the fuzz build analyses reaches the GLFW code.

`App.zig`'s key callback already converts each event to `Key` and
`Modifiers` for the UI, then passes the raw GLFW codes to `encodeKey`.

## Decision

1. **A `src/input/` folder with no GLFW and no I/O** holds the key types
   (`Key`, `Modifiers`), the bindings, and the key encoder. The encoder is
   a pure function from a `Key`, `Modifiers` and the encoding modes to
   bytes in a caller's buffer.
2. **`term/` may import `input/` leaf files**, as it imports `unicode/` and
   `color/`. The layering rule becomes: `term/` depends only on `vt/`,
   `unicode/`, `color/` and `input/`. `input/` imports none of `term/`,
   `renderer/`, `driver/` or `App.zig`.
3. **The encoder takes its own modes struct** (cursor keys, keypad,
   modifyOtherKeys level, and whatever else encoding turns out to need).
   `Terminal` fills it from its modes for XTGETTCAP, and `App` fills it
   from the driver's mode snapshot for key presses, so both go through the
   same code with the same inputs.
4. **GLFW key codes and modifier bits are translated at the platform
   edge**, in one file beside `renderer/Window.zig` until the platform
   module of ADR 0001 exists. Nothing in `input/` names GLFW.
5. **XTGETTCAP answers key names through that encoder**, from a table of
   capability name to key and modifiers taken from xterm's `xtermcap.c`.

## Alternatives considered

- **The encoder inside `term/`.** Keeps the layering rule as it is, and the
  encoder could read `Terminal.mode` directly. But `Key` and `Modifiers`
  are shared by bindings, `config/` and `ui/`, which would then import the
  terminal core to name a key, or the types would live apart from the only
  code that gives them meaning on the wire.
- **A second key table in `term/` for XTGETTCAP.** No layering change, but
  two tables that must agree byte for byte in every mode, with nothing to
  keep them in step.
- **`term/` asks the application through the driver.** Keeps the encoder
  outside `term/`, but a pure `term/` would then wait on its caller to
  finish a reply, and one XTGETTCAP request mixes key names with names
  `term/` answers itself.
- **Leave key names unanswered.** Vim, the main user, falls back to
  terminfo. Costs nothing, but ADR 0001 requires the GLFW split anyway,
  and the answers are wrong whenever terminfo and the modes disagree.

## Consequences

- **Layering:** one more leaf dependency for `term/`. CONTRIBUTING.md
  states the new rule. The fuzz module can reach the key types and the
  encoder without native dependencies, by construction instead of by
  lazy analysis.
- **Breaking change inside the repo:** `encodeKey` takes `Key` and
  `Modifiers` instead of `c_int`. Its tests change their inputs, not their
  expected bytes; a differential test over every key, modifier set and
  mode compares the old and the new encoder before the old one is removed.
- **Performance and memory:** none expected. The encoder stays
  allocation-free with a 32-byte caller buffer, and the key callback
  already does the GLFW translation once per event. Not measured; a key
  press is not a hot path next to pty output.
- **Coverage:** a key that GLFW reports and `Key` lacks cannot be encoded.
  The differential test shows whether any such key is encoded today.
- **Open, to verify in the encoder stage:** what xterm sends for keys under
  8-bit controls (S8C1T). Rex's encoder always sends 7-bit sequences; this
  ADR does not decide that behaviour.
- **Follow-up:** the platform module of ADR 0001 takes over the GLFW
  translation file; a Kitty keyboard protocol encoder, if wanted, is a
  second encoder in `input/` behind the same key types.
