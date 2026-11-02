Here's the consolidated design — the merged architecture (Terminal *is* the parser's `Handler`, encoding lives inside it) plus everything the VT-layer analysis contributed as *internal structure*: comptime profiles/config, grouped state sub-objects, lossless param interpretation, explicit reply path, and conformance harness.

# Terminal Layer — Design v3

Status: draft, unimplemented. Items marked **verify** are memory of DEC/xterm behavior — check DEC programmer's reference, ECMA-48, xterm ctlseqs before encoding.

## 1. Architecture — merged, not layered

```
host (pty) ──bytes──► Terminal.feedBytes(bytes)
                          │
                          ├─ ingest: encoding decode → scalar values
                          ├─ parser: Parser(Self, options) — Self IS the Handler
                          │     print(slice) → charset/grapheme → cells
                          │     csiDispatch(final, intermediates, params)
                          │     escDispatch / oscPut|End / hook / unhook ...
                          │
                          ├─ ops.* : cursor / erase / sgr / charset / scroll / modes
                          ├─ dcs / osc dispatch (grow into own modules)
                          ├─ replies: bounded queue → host
                          │
                          └─ screen: primary / alternate grid, cursor, tabs, margins
```

Two layers collapsed into one type. The app calls `term.feedBytes(bytes)`; `Parser`'s `Handler` methods are implemented on `Terminal` itself — exactly your prototype's `Handler` inner struct, but with behavior organized as modules instead of inline switches.

**Why merged wins over `Vt(Term)`:** UTF-8 vs C1 encoding is decided *inside* this struct (the `utf8` field you already have), which determines `Parser`'s options — a separate `Vt` layer can't own that split cleanly. One `feedBytes` entry means backpressure is honest end-to-end. And it removes the `Vt→Term` call indirection from the 80%-dispatcher-cost paths your benchmarks flagged.

**What we keep from the layered design:** everything it contributed becomes *internal* structure — `Caps`, `Config`, grouped `ops`, `replies`, conformance corpus — not a separate type.

## 2. Comptime configuration — this is the "profile layer"

```zig
pub const Caps = struct {
    level: Level,                     // .vt52, .vt100, .vt220, .vt320, .xterm
    utf8: bool = true,                // G0/G1 absorb UTF-8 vs 8-bit C1 as controls — verify
    kitty_keyboard: bool = false,     // CSI u progressive enhancement
    grapheme_clusters: bool = true,   // utf8 vs utf8_extended print paths
    sgr_italic: bool = false, sgr_underline_style: bool = false,
    sgr_colon_subparams: bool = true, // ITU T.416 ':' form
    osc52_clipboard: bool = false,
    max_osc_bytes: usize = 4096,
    max_dcs_bytes: usize = 16384,     // DECRQSS response budget
    max_reply_queue: usize = 64,
};

pub const Config = struct {
    decawm_autowrap: bool = true, decx_cursor_regs: bool = false,
    osc52_read: bool = false,         // read queries → denial response, not data
    // …behavioral toggles
};

pub fn Terminal(comptime caps: Caps, comptime cfg: Config) type
```

`caps`/`cfg` are **comptime**: `Terminal(vt220_caps, cfg)` and `Terminal(xterm_caps, cfg)` monomorphize two types — profile differences compile away to zero-cost branches, same mechanism as `Parser(Handler)`. Profiles are *defined feature sets* (not a numeric ladder — `vt500` vs `xterm` genuinely differ), with `level` only gating the strictly-cumulative parts.

## 3. Internal structure — what grows where

```
src/term/
    terminal.zig      # Terminal(caps, cfg) — holds state, implements Handler
    caps.zig          # Caps, Config, preset profile constants
    screen.zig        # Screen(grid, cursor, scroll region, tabs, attrs)
    ops/
        cursor.zig    # CUP/CUP1, HVP, save/restore (per-screen slots — verify)
        erase.zig     # ED/EL/DECSED/DECSEL, background erase
        sgr.zig       # intensity, colon-subparams, 38:2/38;2 divergence
        charset.zig   # SI/SO, G0–G3 tables, DEC graphics, UTF-8 G tables
        scroll.zig    # DECSTBM margins, scroll ops, alternate-screen switch
        modes.zig     # DECSET/DECRST + standard modes on ModeSet
    proto/
        param.zig     # ParamCursor — lossless iteration over []Parameter
        csi.zig       # private prefix ('?','>','=') + intermediate routing
        esc.zig       # escDispatch finals
        osc.zig       # oscDispatch routing per caps.osc52_clipboard etc.
        dcs.zig       # hook/put/unhook, DECRQSS/XTGETTCAP routing — replaces dcs_buf stubs
        reply.zig     # bounded ReplySink — DCS responses, DA, CPR, DECRPM
        vt52.zig      # deferred; drops if unused — verify
    encoding/
        ingest.zig    # utf8/utf8_extended decode state machine (your fields)
        input.zig     # host→app encoder, kitty keyboard when enabled
    test/
        corpus.zig    # vectors: input → expected ops + replies + recovery
        recording.zig # RecordingTerm — capture-decorator, not an interface
```

### The `ops.*` contract (proto calls, screen never sees ANSI)

`proto/*` modules decode sequence structure; `ops/*` modules own interpretation + state mutation; `screen` knows grids only. Three examples of where that boundary does real work:

- **`proto/param.zig`** — the lossless-param fix. `ParamCursor` iterates `[]Parameter` preserving `separator` (`;` vs `:`) and — critically — distinguishing **omitted vs explicit-`0`** via presence tracking (params are `u15 value` + `separator`; an empty slot must be readable as "absent" not "0" — verify whether `Parameter` needs a `present` bit added). `ESC[38:2::r:g:bm` vs `ESC[38;2;r;g;bm` diverge *here*, and `SGR 0` vs `SGR` (empty list) is resolved by the family handler, not upstream.
- **`ops/sgr.zig`** — applies the interpretation above. `Caps.sgr_colon_subparams` decides whether `:` form is recognized; `sgr_italic`/`sgr_underline_style` gate attribute bits. Defaulting (`CSI 0 m` = reset, `CSI m` = reset) lives here, not in `proto`.
- **`proto/dcs.zig`** — replaces your `dcs_buf`/`unhook` switch stubs with routed dispatch on `intermediates` (`$q` → DECRQSS, `+q` → XTGETTCAP) gated by `caps.level`/`caps.max_dcs_bytes`.

## 4. The `Parser` ↔ `Terminal` contract (what your prototype already proves)

`Terminal` implements `Parser(Handler)`'s methods — with the corrections from the session applied:

- **`print(slice)`** — bytes, not codepoints. The `ingest` state machine (your `utf8`/`utf8_extended`/`codepoint`/`sequence_len` fields) decodes first; `print` receives a slice that may split mid-codepoint or mid-grapheme-cluster across `feedBytes` calls. **Cluster-aware `putChars`/`feedCodepoint` boundary is a bug-class your prototype must pin** — the `grapheme_breaker`/`codepoint_set` path handles it, but `print`/`putChars` must agree on whether a partial cluster buffers or flushes.
- **`csiDispatch(final, intermediates, params)`** — `proto/csi.zig` routes on `intermediates` + private prefix (`?`/`>`/`=`); family handler gets `ParamCursor`, not normalized values.
- **`oscPut`/`oscEnd`/`hook`/`unhook`** — accumulate into `proto`-owned buffers (`osc_buf`/`dcs_buf` already exist), dispatch on terminator. `caps.osc52_clipboard`/`max_osc_bytes`/`max_dcs_bytes` bound it.
- **`params_overflow` / ignore states** — parser enforces `max_params`/`max_intermediates`; the design's "unhandled → count/log" rule applies to sequences `proto` can't route. Silent ignore is a conformance gap — `unhandled.zig` (a counter + optional trace hook) makes it visible.

## 5. Reply path — explicit, bounded, testable

```zig
// inside Terminal
replies: ReplyQueue,   // bounded ArrayList of pending response bytes

// proto/dcs.zig pushes; host drains:
pub fn takeReplies(self: *Self, buf: []u8) usize
```

DECRQSS, DA (`CSI ? … c` / `CSI > … c`), CPR, DECRPM, XTGETTCAP all enqueue here. Bounded (`caps.max_reply_queue`) so a hostile producer can't grow it unboundedly — same discipline as `max_params`. `RecordingReplySink` in tests captures without a real host.

## 6. Conformance harness — the part that makes this a compliance layer

Two test surfaces, both running through `Terminal` itself:

- **`RecordingTerm`** — capture-decorator implementing the same comptime `Term` method set. Not a vtable: `Terminal`'s ops are comptime-dispatched anyway, so the recorder is a `Terminal` instantiation whose `ops` append to a list. Assert: `input bytes → expected op sequence + expected replies`.
- **`corpus.zig`** — vectors tagged by `caps.level` so the same input is asserted to diverge correctly: `CSI ? 25 h` applies under `xterm`/`vt500`, is ignored under `vt52`. Each vector carries: input, expected ops, expected reply bytes, **malformed-recovery expectations** (`CAN`/`SUB` abort — verify CAN-only vs CAN+SUB), and **split-at-every-byte-boundary** variants (your parser's chunk-boundary safety is a `Terminal` contract via `feedBytes`).

## 7. Encoding — folded in, not a layer

Your prototype's fields (`utf8`, `utf8_extended`, `codepoint`, `sequence_len`, `wcwidth_ambiguous_width`, `last_important_utf8`…) stay inside `Terminal` — that's correct. The design additions:

- `caps.utf8` selects whether 8-bit C1 bytes (`0x80–0x9F`) are controls (mode B) or UTF-8 continuation bytes (mode A) — the `Parser` option is set from it at init, **never switched mid-stream** (the earlier contradiction).
- `caps.grapheme_clusters` selects `utf8` vs `utf8_extended` ingest — the `grapheme_breaker`/`codepoint_set` path only exists in the extended variant.
- **Charset/print path**: `ops/charset.zig` holds G0–G3 + SI/SO; `print` has a fast path when G0 is plain ASCII so charset mapping costs nothing in the common case — the `printText` fast-path idea survives, relocated to `print`'s head.
- **Input encoding** (`encoding/input.zig`) is separate: host→app keys, kitty keyboard when `caps.kitty_keyboard`. Out of Parser's scope entirely.

## 8. Policy decisions (locked unless noted)

- **Invalid-in-UTF-8 → `CAN` abort only**, not CAN+SUB — pending verify against DEC reference.
- **APC accepted-and-dropped** — no Parser option; `sos_pm_apc_string` consumes, proto does nothing. Not a `Caps` field.
- **Single-push CSI u**: kitty enhancement via one mechanism, `caps.kitty_keyboard` gated.
- **DECRQSS response cap** = `caps.max_dcs_bytes` — the reply queue is bounded, so a large DCS response must fit or be refused cleanly.
- **`feedBytes` signature stays one-shot** — consumed-count form only if `feed_string_events` produces a real payload.
- **VT52 deferred** — `vt52.zig` stub stays out until a target profile demands it; if it never lands, `Caps.level` drops `.vt52`.
- **UTF-8-mode encode/decode cost** — measure before committing to the split ingest design permanently.

## 9. Build order — vertical slice, not data-first

1. `caps.zig` + `Config` presets + `ParamCursor` (no behavior yet — the lossless-param primitive everything else needs)
2. `terminal.zig` skeleton: `Screen` grid, `print`/`putChars` + C0 execute (`\r\n\b\t`, LNM), `encoding/ingest.zig` UTF-8 path
3. `ops/cursor.zig` (CUP/CUP1/HVP) + `ops/erase.zig` (ED/EL/DECSED) + `ops/sgr.zig` (basic attrs)
4. First screen-level test: bytes in → grid + attrs out, sourced from esctest/vttest
5. `RecordingTerm` + `corpus.zig` harness, tagged by `Caps` — includes `private_prefix` and colon-param vectors from day one
6. `proto/dcs.zig` + `reply.zig` (DECRQSS, DA, CPR)
7. `ops/charset.zig` (G0–G3, SI/SO, DEC graphics) + `scroll.zig` + `modes.zig`
8. Extensions (OSC 52, kitty keyboard) behind `caps` switches; `encoding/input.zig` last

## 10. What the merged design gives up — honestly

- **Protocol/screen separation for testing.** Without a `Vt` type, you can't unit-test "does `CSI 4;20H` route correctly" without instantiating a `Screen`. Mitigated by `RecordingTerm` capturing ops — the routing is still observable — but grid assertions always come along. Acceptable: your corpus harness asserts screens anyway.
- **`Vt`-as-library reuse.** If a second consumer ever wants "ANSI events without a terminal" (e.g., a transcript parser), the merged `Terminal` is too heavy to reuse. If that need appears, extract `proto/*` into a separate type later — the module boundaries are drawn so it can happen.
- **A second `feedBytes` layer's isolation.** `Ingest` and `Parser` state both live in `self` — chunked-input bugs (split codepoints, split sequences) now have one owner, which is good, but also means a partial-write bug corrupts screen state in ways a layered design would contain.

## 11. Carry-over: `Parser`-side facts this design depends on

- `Parameter` is `{value: u15, separator}` — `present` bit TBD (open item below)
- `params_overflow`/`max_params`/`max_intermediates` enforced by Parser; `sgr_overflow` checksum proves truncation is strict
- `oscPut`/`dcsPut` are per-byte today — if `dcsPutSlice`/`oscPutSlice` batch APIs land later, `proto/dcs.zig`/`osc.zig` is where they plug in (revisit when the handler contract is real, per earlier decision)
- `feed_byte`/`scanUntil`/`feedParamRun` are done — no VT-layer work should re-open them

## 12. Open items to verify

- `Parameter.present` — needed only if any function actually diverges on omitted-vs-`0` (the ParamCursor design assumes it may; confirm before adding a bit to the param array)
- DEC feature→level mapping, exact DECSCL effect
- `CSI s`/`CSI u` target-profile behavior
- High byte inside CSI/ESC/DCS-param in UTF-8 mode: `CAN`-abort vs ignore; whether `U+0080..U+009F` act as C1
- Encoding-switching sequences; what RIS/DECSTR reset encoding to
- CAN-only vs CAN+SUB abort
- Whether VT52 is needed at all
- utf8-mode ingest cost (section 7 measurement)

## What changed vs. the layered v2

| v2 (layered) | v3 (merged) |
|---|---|
| `Vt(Term)` separate struct | `Terminal(caps, cfg)` — Parser's `Handler` directly |
| `Ingest` standalone | `ingest` fields inside `Terminal` |
| `ops.zig` comptime contract | `ops/*` modules called by `proto/*` — same inlining, no separate type |
| `ParamCursor` on `Vt` | `proto/param.zig` — same logic, one level in |
| `ReplySink` injected | `replies` queue inside `Terminal`, drained by host |
| `feedStringEvents`/`feedResidue` tailwork | none — `feedBytes` is the only entry |
| VT52 behind `caps.level` | same, deferred harder |

The substance — caps, lossless params, reply bounds, conformance corpus, CAN-only abort, profile-gated extensions — survives intact; only the packaging changed, and the packaging now matches your prototype's proven shape.