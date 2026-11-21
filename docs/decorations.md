# Text decorations in Rex

Rex draws underlines, strikethroughs and overlines from SGR 4, 9 and 53, plus
the underline it adds to [OSC 8 links](hyperlinks.md) when `underline = always`.
A program can request any of them:

```sh
printf '\033[4munderlined\033[24m \033[9mstruck\033[29m \033[53moverlined\033[55m\n'
```

Every decoration used to be hard-wired. They are now tuned in the
`[decoration]` section of the config file, with one exception: whether a link
is underlined, which style it uses and when the target tooltip appears stay in
`[hyperlink]`, because they are link policy rather than line geometry. Both
sections feed one effective option, so the frame builder and the renderer draw
the same lines — changing a key cannot make the two disagree (ADR 0014).

Run `rex config defaults` to see every key with its documented default. All
defaults reproduce the original rendering. Changing a key with a live config
reload takes effect on the next frame.

Two conventions apply throughout:

- `_px` suffixes mean a value in logical pixels. Offsets are signed; thickness,
  gap and length values cannot be negative.
- `none` keeps the metric derived from the current font. It does not mean
  "zero": a `*_thickness_px = none` still draws a line, at the width the font
  suggests. A colour of `none` uses the text or underline colour.

## Basics

```toml
[decoration]
skip_ink = true                 # break lines where a descender crosses them
order = over_text               # over_text | under_text
alpha = 1.0                     # opacity of every decoration line
dim = true                      # SGR 2 dim text also dims its lines
blink = true                    # SGR 5 and 6 blinking text also blinks its lines
```

Before: lines were always drawn over the glyphs at full opacity, following the
text's dim and blink state. After: `order = under_text` lets glyphs cover a
line, `alpha = 0.5` makes all lines translucent, and `dim = false` keeps a dim
line at full strength under dim text.

## Ink Skipping

```toml
[decoration]
skip_ink_styles = single, double, curly, dotted, dashed   # or a subset, or none
skip_ink_threshold = 0.25   # glyph coverage counted as ink, 0.0 to 1.0
skip_ink_gap_px = none      # extra clearance; none follows the line thickness
skip_ink_min_segment_px = none  # drop pieces shorter than this; none follows thickness
```

Before: every underline style skipped ink, with a fixed threshold and no extra
clearance. After: `skip_ink_styles = single` limits skipping to single
underlines; `skip_ink_gap_px = 2` widens the gap around descenders;
`skip_ink_min_segment_px = 3` removes short fragments left between them.

## Line Geometry

```toml
[decoration]
underline_offset_px = 0           # vertical shift from the font's position
strikethrough_offset_px = 0
overline_offset_px = 0
underline_thickness_px = none     # none keeps the font's metric
strikethrough_thickness_px = none
overline_thickness_px = none
underline_thickness_scale = 1.0   # multiplies the resolved underline thickness
double_gap_px = none              # gap between a double underline's two lines
```

Before: every line sat at the font's metric with a thickness derived from the
cell. After: `underline_offset_px = 2` lowers underlines,
`underline_thickness_px = 2` pins them to two pixels, and
`underline_thickness_scale = 1.5` thickens them relative to the font. A
positive offset moves a line down; a negative one moves it up.

## Pattern Shapes

```toml
[decoration]
curly_amplitude_px = none    # wave height; none derives it from the cell
curly_wavelength_px = none   # wave period
dot_length_px = none         # dotted on/off lengths
dot_gap_px = none
dash_length_px = none        # dashed on/off lengths
dash_gap_px = none
phase = grid                 # grid | run
```

Before: curly, dotted and dashed geometry was derived from the cell width, and
patterns started at the window's left edge. After: `curly_amplitude_px = 3`
raises the wave, `dash_length_px = 6` and `dash_gap_px = 4` set the dash
rhythm, and `phase = run` restarts the pattern at the first cell of each
decorated run instead of aligning it across rows. `grid` is the default and
keeps patterns lined up from one row to the next.

## Decoration Colors

```toml
[decoration]
underline_color = none       # #RRGGBB, or none for the text/underline color
strikethrough_color = none
overline_color = none
```

Before: lines took the cell's text colour (or the link's underline colour).
After: `underline_color = #ff5f87` fixes every underline to that colour,
including links when `[hyperlink] underline_color = none`. Setting a colour in
`[hyperlink]` overrides this one for the link underline only.

## Link policy

These stay in `[hyperlink]`; see [hyperlinks.md](hyperlinks.md) for the full
list and the tooltip keys.

```toml
[hyperlink]
underline = always           # never | always | hover
underline_style = single     # single | double | curly | dotted | dashed
underline_color = none       # overrides [decoration] underline_color for links
```
