#!/usr/bin/env python3
"""Mask a square icon as a macOS squircle and inset it so Finder size matches system apps."""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image


# Finder/Dock cell is 1024. System icons sit inside it with air around the squircle.
CONTENT_RATIO = 0.80


def squircle_mask(size: int, exponent: float = 5.0) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    pixels = mask.load()
    mid = (size - 1) / 2.0
    for y in range(size):
        ny = (y - mid) / mid
        ay = abs(ny) ** exponent
        for x in range(size):
            nx = (x - mid) / mid
            if (abs(nx) ** exponent) + ay <= 1.0:
                pixels[x, y] = 255
    return mask


def main() -> None:
    src = Path(sys.argv[1])
    dest = Path(sys.argv[2])
    img = Image.open(src).convert("RGBA")
    if img.size[0] != img.size[1]:
        raise SystemExit(f"expected square, got {img.size}")

    size = img.size[0]
    masked = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    masked.paste(img, (0, 0))
    masked.putalpha(squircle_mask(size))

    inner = max(1, int(round(size * CONTENT_RATIO)))
    glyph = masked.resize((inner, inner), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    origin = (size - inner) // 2
    canvas.paste(glyph, (origin, origin), glyph)

    dest.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(dest, "PNG")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} SRC.png DEST.png")
    main()
