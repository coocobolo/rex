# 0006: OSC 52 clipboard: writes allowed, reads refused with an empty reply, by default

- Status: accepted
- Date: 2026-11-11
- Deciders: Kbgjtn (maintainer)
- Tickets: draft #83 (split from #70)

## Context

OSC 52 (`OSC 52 ; Pc ; Pd ST`) lets a program set the clipboard, or read it
when `Pd` is `?`. It is how nvim, tmux and shells copy to the local
clipboard over ssh. Rex parses it but does nothing (`52 => {}` in
`src/term/dispatcher.zig`), and since #70 (`c0864f9`) DA1 no longer
advertises it.

xterm's behaviour, quoted from its control-sequence spec (Patch #411) and
manual page:

- `Pc` lists targets from `c p q s 0-7`; an empty `Pc` means `s 0`, and `s`
  means PRIMARY unless `selectToClipboard` is set (default false).
- Base64 `Pd` becomes the selection; `?` replies with it; "If the second
  parameter is neither a base64 string nor ?, then the selection is
  cleared."
- Both directions are off by default: `allowWindowOps` is false and the
  default `disallowedWindowOps` includes `GetSelection` and `SetSelection`.

What programs send, checked in Neovim 0.12.5
(`runtime/lua/vim/ui/clipboard/osc52.lua`): `c` for the `+` register and
`p` for `*`, never an empty `Pc`. Its paste sends `OSC 52 ; c ; ?` and waits
for the reply: 1 s, then a "Waiting for OSC 52 response" message and 9 s
more. Its reply pattern `52;%w?;` accepts an empty `Pc` and empty data.
What tmux passes as `Pc` was not checked (the `xterm-256color` terminfo
`Ms=\E]52;%p1%s;%p2%s\007` leaves it to the program).

The risks: writes let anything printed to the terminal replace the
clipboard, including `cat` of an untrusted file, so text can be planted for
a later paste. Reads let any program, also one on a remote host, take what
the user copied, passwords included.

Platform limits (ADR 0001): GLFW's clipboard calls are main-thread only,
and GLFW has no Wayland primary selection.

The defaults other terminals use (kitty, Ghostty, Alacritty, WezTerm, foot)
were not verified and are not part of this decision's evidence.

## Decision

1. **Writes are allowed by default, reads refused**: `[clipboard]
   osc52_write = allow | deny` (default `allow`) and `osc52_read = deny |
   allow` (default `deny`), enums applied live on reload. An `ask` value
   comes once Rex has a prompt UI.
2. **A refused read gets an empty reply**, `OSC 52 ; Pc ; ST` in the current
   C1 format, so programs that wait for one (Neovim waits up to 10 s) get an
   empty paste at once. It reveals nothing about the clipboard.
3. **An empty `Pc` and `s` go to CLIPBOARD**, not PRIMARY: the same result
   on X11 and Wayland, and what users mean by copy. `c` is CLIPBOARD; `p` is
   PRIMARY on X11 and ignored with one log line on Wayland; `q` and `0-7`
   are ignored.
4. **At most 1 MiB of decoded data per write**, a compile-time terminal
   option. A larger write is dropped whole and counted, never cut short. A
   read reply follows the same limit.
5. **`Pd` that is neither base64 nor `?` clears the clipboard**, as xterm
   does, when writes are allowed.

The terminal only decodes and reports requests; the policy lives in `App`,
which holds the live config and is the only place that touches the
clipboard.

## Alternatives considered

- **Refuse both by default, as xterm does.** Safest, but OSC 52 then does
  nothing until the user finds the setting, and copying over ssh, the main
  reason the feature exists, fails silently.
- **Allow reads by default.** Lets any program take the clipboard; the cost
  of a leak is too high for a default.
- **Stay silent on a refused read, as xterm does.** Neovim then hangs for up
  to 10 s on every paste; the empty reply avoids that without revealing
  anything.
- **Empty `Pc` and `s` to PRIMARY, as xterm does.** Faithful, but the write
  is lost on Wayland, where GLFW has no primary selection.
- **A 256 KiB limit.** A quarter of the memory, but cuts off copying a large
  file; 1 MiB was preferred.
- **Ignore invalid `Pd`.** Keeps the clipboard when garbled output (`cat` of
  a binary) looks like an OSC 52; xterm compatibility was preferred.

## Consequences

- **Security:** by default any program can replace the clipboard, as in
  most terminals, but none can read it. Users who need remote paste turn
  reads on knowingly.
- **Compatibility:** three documented differences from xterm: writes on by
  default, an empty reply to a refused read, and CLIPBOARD for `s`.
- **Memory:** about 1 MiB in each terminal for the decoded write and 1 MiB
  in `App` for the main-thread copy, allocated at startup; about 1.33 MiB
  of temporary space while building a read reply.
- **Follow-up:** `osc52_read = ask` once a prompt UI exists; Wayland
  PRIMARY through the adapter ADR 0001 plans; DA1 advertises 52 again once
  writes work (#83 stage A).
