#!/usr/bin/env python3

from pathlib import Path
import json

OUT = Path("./")
OUT.mkdir(parents=True, exist_ok=True)

manifest = []


def write(name: str, data: bytes, description: str):
    path = OUT / name
    path.write_bytes(data)

    entry = {
        "name": name,
        "size": len(data),
        "description": description,
        "hex_prefix": data[:32].hex(" "),
    }
    manifest.append(entry)

    print(f"{name:40s} {len(data):8d} bytes  {description}")


def ascii_data(n: int) -> bytes:
    return b"a" * n


def ascii_with_nonascii(n: int, offset: int, byte: int = 0x80) -> bytes:
    if not 0 <= offset < n:
        raise ValueError(f"offset {offset} outside buffer of {n} bytes")

    data = bytearray(b"a" * n)
    data[offset] = byte
    return bytes(data)


def nonascii_at_end(n: int, distance_from_end: int, byte: int = 0x80) -> bytes:
    offset = n - distance_from_end
    return ascii_with_nonascii(n, offset, byte)


# ---------------------------------------------------------------------------
# 1. Empty
# ---------------------------------------------------------------------------

write(
    "empty.bin",
    b"",
    "Empty input",
)


# ---------------------------------------------------------------------------
# 2. Tiny ASCII: 1–7 bytes
# ---------------------------------------------------------------------------

for n in range(1, 8):
    write(
        f"ascii_{n:02d}.bin",
        ascii_data(n),
        f"{n}-byte ASCII",
    )


# ---------------------------------------------------------------------------
# 3. SWAR/vector boundary sizes
#
# 8–15
# 16–31
# 32/64/128
# ---------------------------------------------------------------------------

for n in range(8, 16):
    write(
        f"ascii_{n:02d}.bin",
        ascii_data(n),
        f"{n}-byte ASCII / 8-byte boundary",
    )

for n in range(16, 32):
    write(
        f"ascii_{n:02d}.bin",
        ascii_data(n),
        f"{n}-byte ASCII / 16-byte boundary",
    )

for n in (32, 64, 128):
    write(
        f"ascii_{n}.bin",
        ascii_data(n),
        f"{n}-byte ASCII / vector boundary",
    )


# ---------------------------------------------------------------------------
# 4. Larger sustained-scan buffers
# ---------------------------------------------------------------------------

for n in (4 * 1024, 64 * 1024):
    write(
        f"ascii_{n // 1024}k.bin",
        ascii_data(n),
        f"{n // 1024} KiB pure ASCII",
    )


# ---------------------------------------------------------------------------
# 5. Non-ASCII at byte 0
# ---------------------------------------------------------------------------

write(
    "nonascii_start_80.bin",
    ascii_with_nonascii(128, 0, 0x80),
    "Non-ASCII/high-bit byte at offset 0",
)

write(
    "nonascii_start_ff.bin",
    ascii_with_nonascii(128, 0, 0xFF),
    "0xFF at offset 0",
)


# ---------------------------------------------------------------------------
# 6. Non-ASCII at byte 1
# ---------------------------------------------------------------------------

write(
    "nonascii_offset_1.bin",
    ascii_with_nonascii(128, 1, 0x80),
    "Non-ASCII/high-bit byte at offset 1",
)


# ---------------------------------------------------------------------------
# 7. Non-ASCII at word/vector boundaries
# ---------------------------------------------------------------------------

for offset in (7, 8, 15, 16):
    write(
        f"nonascii_offset_{offset}.bin",
        ascii_with_nonascii(128, offset, 0x80),
        f"Non-ASCII at offset {offset}",
    )


# ---------------------------------------------------------------------------
# 8. Non-ASCII near the end
# ---------------------------------------------------------------------------

for distance in (1, 2, 4, 8, 16, 32):
    write(
        f"nonascii_tail_{distance}.bin",
        nonascii_at_end(128, distance, 0x80),
        f"Non-ASCII {distance} byte(s) from end",
    )


# ---------------------------------------------------------------------------
# 9. Non-ASCII exactly at the end
#
# Equivalent to distance_from_end=1, but give it an explicit name because
# it is an important benchmark case.
# ---------------------------------------------------------------------------

write(
    "nonascii_exact_end.bin",
    ascii_with_nonascii(128, 127, 0x80),
    "Non-ASCII at final byte",
)


# ---------------------------------------------------------------------------
# 10. High-bit detection patterns
# ---------------------------------------------------------------------------

for value, name in (
    (0x80, "80"),
    (0xFF, "ff"),
):
    # Put the high-bit byte in the middle so the scanner has to do some work.
    data = bytearray(b"a" * 128)
    data[64] = value

    write(
        f"highbit_{name}.bin",
        bytes(data),
        f"0x{value:02X} at offset 64",
    )


# ---------------------------------------------------------------------------
# 11. Unaligned ASCII
#
# The file itself cannot guarantee its address in the executable.
# These files are useful for the corpus, but your Zig benchmark should
# additionally create a padded backing buffer and slice it at offsets
# 1..15 to guarantee unaligned addresses.
# ---------------------------------------------------------------------------

for alignment in range(1, 16):
    # Padding + 128 bytes ASCII.
    data = bytes([0xCC]) * alignment + b"a" * 128

    write(
        f"unaligned_ascii_{alignment}.bin",
        data,
        f"{alignment}-byte prefix padding + 128-byte ASCII",
    )


# ---------------------------------------------------------------------------
# 12. Unaligned non-ASCII
#
# Same idea, but put the terminating byte inside the payload.
# ---------------------------------------------------------------------------

for alignment in range(1, 16):
    payload = bytearray(b"a" * 128)
    payload[64] = 0x80

    data = bytes([0xCC]) * alignment + bytes(payload)

    write(
        f"unaligned_nonascii_{alignment}.bin",
        data,
        f"{alignment}-byte prefix padding + non-ASCII payload",
    )


# ---------------------------------------------------------------------------
# 13. Useful UTF-8 examples
#
# These aren't required for asciiPrefixLen itself, but are useful if you
# extend the benchmark to UTF-8 decoding/validation.
# ---------------------------------------------------------------------------

write(
    "utf8_2byte.bin",
    b"a" * 127 + "é".encode("utf-8"),
    "127 ASCII bytes + 2-byte UTF-8 sequence",
)

write(
    "utf8_3byte.bin",
    b"a" * 127 + "汉".encode("utf-8"),
    "127 ASCII bytes + 3-byte UTF-8 sequence",
)

write(
    "utf8_4byte.bin",
    b"a" * 127 + "😀".encode("utf-8"),
    "127 ASCII bytes + 4-byte UTF-8 sequence",
)


# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

manifest_path = OUT / "manifest.json"
manifest_path.write_text(
    json.dumps(manifest, indent=2) + "\n",
    encoding="utf-8",
)

print()
print(f"Generated {len(manifest)} corpus files.")
print(f"Manifest: {manifest_path}")