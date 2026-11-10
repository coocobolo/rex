# Test fonts

Rasterizer and atlas fixtures. Google Sans Code, the built-in text face,
lives in `assets/fonts`. `zig build check-fonts` reads each name table and
requires its copyright to be the first line of the OFL file for that
family. Replacing a file here without the matching `OFL-*.txt` fails that
step.

The copyright line of each `OFL-*.txt` is name-table ID 0 of the files it
covers. The rest is the SIL Open Font License 1.1.

| File | Family | Version | License |
| --- | --- | --- | --- |
| `NotoSansMono-Regular.ttf` | Noto Sans Mono | 2.006 | `OFL-NotoSansMono.txt` |
| `NotoSansMono-Bold.ttf` | Noto Sans Mono | 2.006 | `OFL-NotoSansMono.txt` |
| `NotoSans-Italic.ttf` | Noto Sans | 2.015 | `OFL-NotoSans.txt` |
| `NotoSans-BoldItalic.ttf` | Noto Sans | 2.015 | `OFL-NotoSans.txt` |
| `NotoColorEmoji.ttf` | Noto Color Emoji | 2.047 | `OFL-NotoColorEmoji.txt` |

The Noto Sans italics are the hinted static faces
(`NotoSans/hinted/ttf/`) and `OFL.txt` of the
[NotoSans-v2.015 release](https://github.com/notofonts/latin-greek-cyrillic/releases/download/NotoSans-v2.015/NotoSans-v2.015.zip),
copied unchanged. SHA-256:

```
467e3f89eeca4108bb8710a2b9e0cf2281ac56d5b0609211a83776d0505eecb5  NotoSans-Italic.ttf
1b602a9d6353be42c91df097a4857b69fa2696f26703d7a33b54a15d87c2622c  NotoSans-BoldItalic.ttf
cee9892f9f0cc8fe882c9e9537ee6a89621d86ee7ceaf70b02e2b2b1c25c061a  OFL-NotoSans.txt
```

`NotoColorEmoji.ttf` is also installed next to the built-in text face
(`share/rex/fonts/` via the build). One copy lives here so the tests and
the install share the same bytes.
