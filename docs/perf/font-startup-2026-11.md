# Shipped font startup (2026-11-09)

The faces are installed under `share/rex/fonts`, not embedded, and Rex does
not use fontconfig. This is the startup cost of that install.

Measured on the working tree at `3ec879a` (ReleaseFast). The machine is the
one in `baseline-2026-11.md`: Ryzen 3 3300X, governor `performance`, NVIDIA
GTX 1650 SUPER, OpenGL 4.6, X11, Ubuntu. Zig 0.16.0. Each run used an empty
home, so no config file was read unless the case wrote one. Time is from
process start until the first `fb=` log line, which is the first resize
after the faces are rasterized. One warmup run, then five. RSS is the
process at that line.

| Case | What it loads | min | median | max | RSS |
| --- | --- | --- | --- | --- | --- |
| builtin | omitted `font.file`, `italic_file`, and `emoji_file`: both Google Sans Code faces and Noto Color Emoji | 297 ms | 307 ms | 334 ms | 123–125 MiB |
| regular only | `file` set to the shipped upright face, `italic_file = none`, `emoji_file = none` | 290 ms | 297 ms | 309 ms | 124–125 MiB |
| explicit three | the same three shipped paths written in the config | 294 ms | 296 ms | 319 ms | 123–125 MiB |

The ranges overlap. Loading the italic face and the emoji face, or resolving
the omitted keys, does not move first-frame time outside the spread of these
runs.

The same no-config run, split on the log lines, five runs after a warmup:

| Point | min | median | max |
| --- | --- | --- | --- |
| Shell spawned (`termio.pty`) | 2.4 ms | 2.5 ms | 2.7 ms |
| Window and GL context (`display scale`) | 167 ms | 167 ms | 173 ms |
| First resize (`fb=`) | 304 ms | 306 ms | 313 ms |

The shell is done in 3 ms. The window and the OpenGL context take about 165 ms. The following 140 ms covers the rasterizer, the atlas warmup, and renderer setup. Warming only the regular ASCII face, instead of all four styles, left that interval the same, so the extra styles are not the cost.

Startup rasterizes ASCII only. A ReleaseFast rasterizer at 14 px, the same
size as the default, was timed on the test fixtures (Noto Sans Mono for the
letter, the same Noto Color Emoji file for U+1F600). Five runs:

| Step | min | median | max |
| --- | --- | --- | --- |
| Open every face | 0.43 ms | 0.45 ms | 0.53 ms |
| Rasterize `A` | 0.24 ms | 0.24 ms | 0.25 ms |
| First raster of U+1F600 | 0.23 ms | 0.24 ms | 0.24 ms |
| Same emoji again | 0.15 ms | 0.15 ms | 0.19 ms |

The first emoji costs about the same as one letter. The 10.8 MB emoji file
is not read through at open.

Installed sizes next to `bin/rex` (14,163,224 bytes):

| File | Bytes |
| --- | --- |
| `GoogleSansCode[wght].ttf` | 126,224 |
| `GoogleSansCode-Italic[wght].ttf` | 132,968 |
| `NotoColorEmoji.ttf` | 10,788,068 |

```sh
zig build -Doptimize=ReleaseFast
# empty HOME, then time until the first fb= line in the log
# regular only: [font] file = <prefix>/share/rex/fonts/GoogleSansCode[wght].ttf,
# italic_file = none, emoji_file = none
```
