#!/usr/bin/env python3

import argparse
import random
from pathlib import Path


UNICODE_MAX = 0x10FFFF
SURROGATE_START = 0xD800
SURROGATE_END = 0xDFFF


def is_scalar(cp: int) -> bool:
    return not (SURROGATE_START <= cp <= SURROGATE_END)


def random_scalar(rng: random.Random) -> int:
    while True:
        cp = rng.randint(0, UNICODE_MAX)
        if is_scalar(cp):
            return cp


def random_unicode(n: int, rng: random.Random) -> list[int]:
    return [random_scalar(rng) for _ in range(n)]


def small_fixed(n: int, rng: random.Random) -> list[int]:
    representative = [
        ord("A"),
        ord("a"),
        ord("0"),
        ord(" "),
        0x00E9,  # é
        0x03BB,  # λ
        0x0416,  # Ж
        0x4E2D,  # 中
        0x1F600, # 😀
        0x10FFFF,
        0,
        0x7F,
        0x80,
    ]

    values = [representative[i % len(representative)] for i in range(n)]
    rng.shuffle(values)
    return values


def ascii_heavy(n: int, rng: random.Random) -> list[int]:
    values = []

    for _ in range(n):
        p = rng.random()

        if p < 0.90:
            # Common ASCII text and control characters.
            cp = rng.choices(
                population=list(range(0x00, 0x80)),
                weights=[
                    1, 1, 1, 1, 1, 1, 1, 1,
                    1, 1, 1, 1, 1, 1, 1, 1,
                ] * 8,
            )[0]

        elif p < 0.99:
            # Latin-1 and common punctuation/symbols.
            cp = rng.randint(0x80, 0xFF)

        else:
            # Occasional non-Latin text or emoji.
            cp = rng.choice([
                rng.randint(0x370, 0x3FF),    # Greek
                rng.randint(0x400, 0x4FF),    # Cyrillic
                rng.randint(0x4E00, 0x9FFF),  # CJK
                rng.randint(0x1F300, 0x1FAFF),# Emoji
            ])

        if is_scalar(cp):
            values.append(cp)

    return values


def real_text(path: str, n: int, rng: random.Random) -> list[int]:
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    codepoints = [ord(ch) for ch in text if is_scalar(ord(ch))]

    if not codepoints:
        raise ValueError("The input text contains no Unicode scalar values")

    # Sample with replacement so every profile has exactly n entries.
    values = [rng.choice(codepoints) for _ in range(n)]
    rng.shuffle(values)
    return values


def range_boundaries(
    n: int,
    ranges: list[tuple[int, int]],
    rng: random.Random,
) -> list[int]:
    values = []

    for start, end in ranges:
        # Values immediately around each interval.
        candidates = [
            start - 1,
            start,
            start + 1,
            end - 1,
            end,
            end + 1,
        ]

        values.extend(
            cp for cp in candidates
            if 0 <= cp <= UNICODE_MAX and is_scalar(cp)
        )

    # Add random points, including misses and interior values.
    while len(values) < n:
        if rng.random() < 0.7:
            # Around a randomly chosen range boundary.
            start, end = rng.choice(ranges)
            boundary = rng.choice([start, end])
            cp = boundary + rng.randint(-2, 2)
        else:
            cp = random_scalar(rng)

        if 0 <= cp <= UNICODE_MAX and is_scalar(cp):
            values.append(cp)

    rng.shuffle(values)
    return values[:n]


def write_values(path: str, values: list[int]) -> None:
    with open(path, "w", encoding="utf-8") as f:
        for cp in values:
            f.write(f"{cp}\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("-n", type=int, default=1_000_000)
    parser.add_argument("--seed", type=int, default=12345)
    parser.add_argument("--text", help="UTF-8 text file for the real-text profile")
    parser.add_argument("--out", default="corpus")
    args = parser.parse_args()

    rng = random.Random(args.seed)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    # Replace these with the actual ranges used by your lookup table.
    table_ranges = [
        (0x0000, 0x007F),    # Basic Latin
        (0x0080, 0x00FF),    # Latin-1 Supplement
        (0x0370, 0x03FF),    # Greek
        (0x0400, 0x04FF),    # Cyrillic
        (0x4E00, 0x9FFF),    # CJK
        (0x1F300, 0x1FAFF),  # Emoji
    ]

    profiles = {
        "small-fixed": small_fixed(args.n, rng),
        "random-unicode": random_unicode(args.n, rng),
        "ascii-heavy": ascii_heavy(args.n, rng),
        "range-boundaries": range_boundaries(
            args.n, table_ranges, rng
        ),
    }

    if args.text:
        profiles["real-text"] = real_text(args.text, args.n, rng)

    for name, values in profiles.items():
        write_values(out / f"{name}.txt", values)
        print(f"{name}: {len(values):,} values")


if __name__ == "__main__":
    main()