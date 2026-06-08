#!/usr/bin/env python3
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw


ICNS_SPECS = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024),
]


def make_rounded_square_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    radius = int(size * 0.19)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def normalize_icon(source_path: Path) -> Image.Image:
    source = Image.open(source_path).convert("RGBA")
    base_size = 1024
    icon = source.resize((base_size, base_size), Image.Resampling.LANCZOS)
    icon.putalpha(make_rounded_square_mask(base_size))
    return icon


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: generate_app_icon.py <source-png> <output-icns>", file=sys.stderr)
        return 2

    source_path = Path(sys.argv[1])
    output_icns = Path(sys.argv[2])
    output_icns.parent.mkdir(parents=True, exist_ok=True)

    icon = normalize_icon(source_path)
    entries = []
    for icon_type, size in ICNS_SPECS:
        resized = icon.resize((size, size), Image.Resampling.LANCZOS)
        png_path = output_icns.with_suffix(f".{icon_type}.png")
        resized.save(png_path, format="PNG")
        entries.append((icon_type.encode("ascii"), png_path.read_bytes()))
        png_path.unlink()

    total_length = 8 + sum(8 + len(data) for _, data in entries)
    with output_icns.open("wb") as file:
        file.write(b"icns")
        file.write(struct.pack(">I", total_length))
        for icon_type, data in entries:
            file.write(icon_type)
            file.write(struct.pack(">I", 8 + len(data)))
            file.write(data)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
