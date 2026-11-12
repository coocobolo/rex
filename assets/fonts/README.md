# Built-in fonts

`zig build` installs these to `<prefix>/share/rex/fonts`, where Rex looks
for faces the config leaves out (`src/config/builtin_font.zig`).
`zig build check-fonts` requires each font's copyright (name-table ID 0)
to be the first line of its OFL file.

Google Sans Code v6.001, the variable upright and italic faces
(`variable/`) and `OFL.txt` of the
[v6.001 release](https://github.com/googlefonts/googlesans-code/releases/download/v6.001/GoogleSansCode-v6.001.zip),
copied unchanged, under the SIL Open Font License 1.1. SHA-256:

```
c9649573afcd966f61096b1e9c3c3115e7b54315ca2adf9839c6f8b17d5f8e1f  GoogleSansCode[wght].ttf
bdf116292f27aca16e2aefb5534042a25f244d3a9187a521ce97fc2117a4a844  GoogleSansCode-Italic[wght].ttf
ff8f4fbc4f1a71c7d4c6481c48dc2b21c43f8dc15872536667fee45c15d20928  OFL-GoogleSansCode.txt
```

To update, replace the files from a new release, update this table and
the version, and run `zig build check-fonts`.

## Inter (the UI font)

Inter 4.1, the variable upright face (`InterVariable.ttf`) and
`LICENSE.txt` of the
[v4.1 release](https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip),
copied unchanged (the license as `OFL-Inter.txt`), under the SIL Open Font
License 1.1. The UI kit sets its text in it (ADR 0009). SHA-256:

```
4989b125924991b90d05b2d16e0e388c48f7d5bb8b30539bbf9c755278d0ccaf  InterVariable.ttf
262481e844521b326f5ecd053e59b98c8b2da78c8ee1bdbb6e8174305e54935a  OFL-Inter.txt
```

Its license file starts "Copyright (c) 2016 ..." with the project URL,
while the font's name table says "Copyright 2016 The Inter Project
Authors"; `check-fonts` compares the two without the "(c)" and the URL.

