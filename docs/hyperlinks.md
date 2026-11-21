# Hyperlinks in Rex

Rex supports [OSC 8](https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda)
terminal hyperlinks. A program can mark text as a link:

```sh
printf '\033]8;;https://example.com\033\\this is a link\033]8;;\033\\\n'
```

The text is underlined and Ctrl+click opens the target. The link travels with
the text through scrolling, reflow, copy and the alternate screen. A plain
newline does not end a link; an explicit `OSC 8 ;; ST` reset or a full reset
(RIS) does.

## Discovering links

- Linked text is underlined and the pointer becomes a hand over it.
- Holding the key set by `show_targets` (Ctrl by default) shows the
  target URI in a tooltip near the pointer. The tooltip never absorbs a click.
- With `underline = hover`, only the link under the pointer is underlined.
  An explicit SGR underline is always drawn, whatever this setting is.

By default, the underline is a single line in the text color; use
`underline_style` and `underline_color` to change it. The tooltip layout is chosen
with `target_style`: `multiline` (narrow card, up to five lines),
`head_tail` (first 40 and last 24 UTF-8 bytes with `…` between), or `wide`
(one line up to 520 px, ellipsized at the edge). Those sizes are defaults;
the `tooltip_*` keys in the Configuration section tune each layout.

## Opening links

Ctrl+click opens the target with the system handler: `xdg-open` on Linux,
`open` on macOS. Pressing Ctrl on press and releasing it over the same cell
activates the link; a drag or a release elsewhere still selects text as usual.
Ctrl+click also works in applications that report mouse events.

Set `open_command` to use a different program. It receives the URI as a
single argument and is never run through a shell, so it cannot contain flags
or shell syntax.

Only the schemes in `schemes` are allowed. The defaults are `http`, `https`
and `mailto`; `file` is off by default and has to be enabled explicitly.
A link with any other scheme is ignored and nothing is spawned.

## Configuration

All settings live in the `[hyperlink]` section of the config file. Run
`rex config defaults` to see every key with its documented default.

```toml
[hyperlink]
enabled = true                 # Ctrl+click and tooltips off when false
underline = always             # never | always | hover
underline_style = single       # single | double | curly | dotted | dashed
show_targets = ctrl            # never | ctrl | cmd | alt | shift | always
target_style = multiline      # multiline | head_tail | wide
underline_color = none         # #RRGGBB, or none for the decoration/text color
tooltip_head_bytes = 40        # head_tail: leading UTF-8 bytes kept
tooltip_tail_bytes = 24        # head_tail: trailing UTF-8 bytes kept
tooltip_line_bytes = 40        # multiline: bytes per line
tooltip_max_lines = 5          # multiline: maximum line count
tooltip_width = 360            # multiline: card width in logical pixels
tooltip_wide_width = 520       # wide: card width in logical pixels
open_command = ""              # empty uses the system handler
schemes = http, https, mailto  # add file to allow local files

[ui]
tooltip_padding_x = 12         # tooltip card padding, in logical pixels
tooltip_padding_y = 8
tooltip_gap = 8                # spacing between the swatch, name and value
```

Changing any of these with a live config reload takes effect on the next
frame. `underline` replaces the earlier boolean setting: write `always` for
`true` and `never` for `false`.

The tooltip dimension keys are gated by `target_style`: only the rows for the
selected layout take effect, and Settings hides the others. `tooltip_head_bytes`
and `tooltip_tail_bytes` apply to `head_tail`; `tooltip_line_bytes`,
`tooltip_max_lines` and `tooltip_width` apply to `multiline`; and
`tooltip_wide_width` applies to `wide`. The three `[ui]` keys set the card's
inner padding and row spacing for every tooltip, not only link targets.
Limits on URI length and link count are below; those are protocol and buffer
limits and cannot be configured.

## Limits

- A URI longer than 1024 bytes, or beyond the OSC payload buffer, is dropped
  whole rather than truncated.
- Up to 1024 links are kept per screen; the current frame snapshot carries at
  most 16 URIs. Links beyond that are drawn but cannot be hovered or opened.
- This is explicit OSC 8 support. Plain-text URLs are not detected, so a URL
  printed without OSC 8 is not clickable.
- Opening a URI starts an external process from untrusted terminal output.
  Keep the scheme allowlist narrow and choose an `open_command` you trust.
