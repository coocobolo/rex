# Test fonts

Rasterizer and atlas fixtures that live in this directory. Google Sans
Code, the built-in text face, and the Noto Sans italics are `zig fetch`
dependencies in `build.zig.zon`. `zig build check-fonts` reads each name
table and requires its copyright to be the first line of the OFL file for
that family. Replacing a file here without the matching `OFL-*.txt` fails
that step.

Noto Sans italic and bold italic are the hinted static faces from Noto
Sans v2.015 (`noto_sans`). Tests open those package files. The copyright
line of each `OFL-*.txt` is name-table ID 0 of the files it covers. The
rest is the SIL Open Font License 1.1.

| File | Family | Version | License |
| --- | --- | --- | --- |
| `NotoSansMono-Regular.ttf` | Noto Sans Mono | 2.006 | `OFL-NotoSansMono.txt` |
| `NotoSansMono-Bold.ttf` | Noto Sans Mono | 2.006 | `OFL-NotoSansMono.txt` |
| `NotoColorEmoji.ttf` | Noto Color Emoji | 2.047 | `OFL-NotoColorEmoji.txt` |

`NotoColorEmoji.ttf` is also installed next to the built-in text face
(`share/rex/fonts/` via the build). One copy lives here so the tests and
the install share the same bytes.
