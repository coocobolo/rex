# UI kit

The kit draws Rex's own interface: toasts and dialogs in the terminal window
today, whole tool windows later. The decision behind it is ADR 0009
(`docs/decisions/`). This page is the working spec: the model, the components
and how to add one.

The kit imports nothing outside this folder. It does not know about the
terminal, the driver or OpenGL, so it runs in any process and its tests need
no display. Painting is `renderer/KitPainter.zig`; text is measured through
the `text.Measurer` a caller passes in.

## The model

A **surface** is one whole piece of interface: the toast stack, an alert
dialog. It has three parts.

- **State**: one plain struct with everything about the surface, including
  which control is hovered, pressed or focused. Modes are enums or tagged
  unions.
- **`update(state, event)`**: the only function that changes the state, one
  exhaustive switch. It returns whether anything on screen changed. A redraw
  happens only then, or while something is animating.
- **`view(state, tree, theme)`**: writes the surface as a flat array of nodes
  (boxes, texts, icons) into a `tree.Tree`. It is rebuilt from the state every
  time; it never reads the previous view.

A **component** is smaller than a surface and owns nothing. It is:

- a **view function** the surface's view calls with the values to show
  (`button.view(tree, theme, .{ .label = ..., .state = .hovered })`);
- where behaviour is worth sharing, a **helper** the surface's update calls
  (`focus.move`, `dialog.Phase.tick`);
- for what a surface should not have to carry, a slot in a `memory.Table`
  keyed by the node's id (where a toast was last drawn).

There are no widget objects that keep their own state and call back. The
state of a control lives in the surface that shows it, once.

Rules that hold everywhere:

- Nothing allocates in update, view, layout or paint. Buffers are fixed and
  their sizes are checked at compile time (`node_max`, `line_max`); running
  out is an error, never a silently missing node.
- Sizes are logical pixels. They are multiplied by the display scale once and
  snapped to physical pixels in `layout.snap`.
- A component names tokens of `Theme`, never a color or a radius of its own.
- A button is taken when the pointer is let go on it, not when it goes down.
  The toast's close mark and the scrim still act on the press.

## Files

| File | What it holds |
| --- | --- |
| `Theme.zig` | Tokens: colors in a dark and a light variant, radii, the spacing step, control heights, durations |
| `text.zig` | Text styles, the measurer interface, line wrapping |
| `icons.zig` | Code points in the bundled icon font |
| `tree.zig` | The node array a view writes, ids, hit-testing |
| `layout.zig` | Rectangles for every node; logical to physical pixels |
| `memory.zig` | Per-id memory that outlives a rebuild of the view |
| `motion.zig` | The one duration and curve every surface uses |
| `focus.zig` | Keyboard focus order over a row or list |
| `button.zig`, `kbd.zig`, `dialog.zig`, `sidebar.zig`, `popup.zig`, `tabs.zig`, `chart.zig`, `tooltip.zig` | Components |
| `toast.zig`, `alert_dialog.zig` | Surfaces |

## Text

Sizes are logical pixels and do not follow the system font size. A text
is `.proportional` unless it asks for `.tabular`: each ASCII digit then
sits in one cell as wide as the widest digit, and is not kerned.

| Style | Size / line | Weight | Tracking | Used for |
| --- | --- | --- | --- | --- |
| `xs` | 12 / 16 | medium | 0 | key caps, captions |
| `sm` | 14 / 20 | regular | 0 | body text |
| `sm_medium` | 14 / 20 | medium | 0 | buttons, toast titles |
| `base` | 16 / 24 | regular | 0 | settings body |
| `lg_semibold` | 18 / 28 | semibold | 0 | dialog titles |
| `xl_semibold` | 24 / 32 | semibold | 0 | card values |
| `xxl_semibold` | 56 / 64 | semibold | −1 | compact timer |
| `xxxl_semibold` | 80 / 88 | semibold | −2 | timer |

## Layout

A box places its children in a row or a column, with padding around them and
a gap between them, aligned along and across its axis. A width or height is
one of:

| Size | Meaning |
| --- | --- |
| `fit` | As large as the content |
| `fill` | A share of what the parent has left |
| `fixed` | This many pixels |
| `at_most` | This many pixels, or less in a smaller parent |
| `at_least` | As large as the content, but not below this many pixels |
| `fraction` | This fraction of the parent's inner size, from 0 to 1 |

Text wraps to the width it ends up with. There is no scrolling and no
wrapping of rows yet.

A box with `.overflow = .clip` cuts its descendants at its rectangle, for
painting and for hit-testing, and keeps their sizes instead of shrinking the
largest one to fit. The cut is square, also at rounded corners. Clipping
boxes nest up to 8 deep.

Roots are laid out one after another in drawing order, each against the
window. A root can instead be anchored to a node of an earlier root
(`Tree.anchorTo`, at most `tree.anchor_max` per view): it goes below that
node, or above it when there is more room there, stays 8 px inside the
window and is at least as wide as the node.

## Components

### Button (`button.zig`)

| | Values |
| --- | --- |
| Variant | `outline`, `primary`, `ghost`, `destructive` |
| Size | `default` (36 px), `sm` (32 px) |
| State | `normal`, `hovered`, `pressed`, `disabled` |
| Also | `focused` draws the ring; `key_cap` shows a key after the label |

The focus ring sits in a slot around the face, so a row does not shift when
the focus moves. The button's id is on that slot. A disabled button is drawn
at half opacity and gets neither hover nor focus from its surface.

### Kbd (`kbd.zig`)

`kbd.view` draws one key cap; `kbd.group` draws several in a row. A key cap
is at least as wide as it is tall. It only displays a key; the caller binds
it.

### Dialog (`dialog.zig`)

`dialog.open` .. `dialog.close` write the scrim and the card. Inside the
card go `dialog.header` (with `dialog.title` and `dialog.description`) and
`dialog.footer` (a row of buttons). What opens a dialog is an event to its
surface. `dialog.Phase` (closed, entering, open, leaving) fades it in and out; a
surface keeps one in its state. The card's width is an upper bound: in a
narrower window it shrinks and keeps a 16 px margin.

### Sidebar (`sidebar.zig`)

The frame of a tool window: sections grouped under headings in a 256 px
column, the pane with the current section beside it, and a button at the top
of the pane that shows and hides the column. A view calls `sidebar.begin`,
writes the section, then `sidebar.end`; the surface keeps a `sidebar.State`.

Below 600 px of width the column is hidden. Shown from there, it lies over
the pane, which is dimmed; a click on the dimmed part or choosing a section
puts it away. Crossing 600 px hands the choice back to the width. Up and
Down move between sections and stop at the ends; Home and End jump to the
first and last.

### Tabs (`tabs.zig`)

A row `control_sm` tall (32 px) filled with `muted`, with 3 px of padding.
The current tab is a face of the height left inside that padding: `background`
in the light theme, and `input` at 30% with an `input` border in the dark
theme. Other labels are `muted_foreground`; the label under the pointer is
`foreground`. Focus draws the ring as that face's border, so the row does
not grow. The surface keeps the current, hovered and focused indexes and
draws the page itself.

### Chart (`chart.zig`)

Three views, each taking its numbers and a mark. `progress` is a `bar` or
a `ring`, `share` is a `bar` or a `donut`, and `days` is a `bar`. The ring
and the donut are arcs: a square whose slices are drawn over it. `days`
draws one column per day at a fixed height, with `part` at the bottom of
`total` and, when a limit is given, a 1 px `border` strip at that value.

### Tooltip (`tooltip.zig`)

A card anchored to a node, written after the page. It has no full-window
layer, and the card has no id, so the page under it still takes hover and
clicks. `tooltip.line` writes an 8 px swatch, a name and a value in `xs`.
The surface decides when the card is open.

### Popup (`popup.zig`)

A card above the page, placed against the control that opened it: the list
of a dropdown, a menu. `popup.open` writes a transparent layer over the
whole window and opens the card, anchored to the control; `popup.item`
writes a row (filled when highlighted, checked when selected); `popup.close`
ends the card. Write it after the page. The card takes the pointer over
itself and the layer everywhere else, so the page gets neither hover nor
clicks while it is open; a press on the layer is the surface's cue to close
it.

## Surfaces

### Toast stack (`toast.zig`)

Up to three toasts at the bottom right, the newest lowest; more wait their
turn. Kinds: `default`, `success`, `info`, `warning`, `err`. A
toast leaves when its time is up; the time stands still while the pointer is
over the stack.

### Alert dialog (`alert_dialog.zig`)

Built from the dialog parts: an optional icon (`Request.media`), a title, an
optional body and one to three actions. An action with role `dismiss`
cancels; one with role `choose` answers.

It interrupts with one question and stays until it is answered. Choosing an
action closes it at once and reports which; dismissing fades it out. The
caller decides what a click on the scrim does.

## Seeing it

`xvfb-run -a zig build -j2 test -Dtest-filter=KitPainter -Dkit-shots=<dir>`
writes frames of every surface as PPM files, among them
`specimen-dark-100` and `specimen-light-100`: every component in every
variant, size and state. Look at the specimen after any change to a
component, and add the new variant to it (`renderer/kit_painter_test.zig`).

## Adding a component

1. Take the name and composition an established component library uses for
   it, so the parts have names people already know.
2. Write it as a view function in its own file, with an `Options` struct and a
   `node_max`. Modes that exclude each other are one enum, not several bools.
3. If it has behaviour several surfaces need, add a helper that a surface's
   update calls. Keep the state in the surface.
4. Test it without a display: build a tree, lay it out, assert the nodes.
5. Add it to the specimen sheet and to the tables above.

## Planned

Specified here when built, in the ticket that first uses them:

- Alert (the config-error banner): an icon, a title, a description and an
  action. It stays in place until its cause is gone, which is what sets it
  apart from a toast.
- For the tool windows: checkbox, switch,
  dropdown (its list is a popup), list row, text input, scroll container.
- A focus order taken from the view, for surfaces with many controls.
