#!/usr/bin/env python3
"""Losslessly re-encode the checked-in render baselines.

`UIImage.pngData()` writes valid but poorly-compressed PNGs — a card with
under 4,000 distinct colours comes out at roughly 1.1 bytes per pixel, about
4x larger than it needs to be. That matters because these files are in git:
every re-record adds another full copy to history permanently.

This is safe precisely because `RecurringTaskCardRenderTests` compares
*decoded pixels*, not file bytes. Re-encoding changes the file and not a
single pixel, so the suite keeps passing — which this script verifies before
overwriting anything, rather than assuming.

Run after recording baselines:
    python3 scripts/optimize-render-baselines.py
"""

import pathlib
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required: python3 -m pip install Pillow")

BASELINES = pathlib.Path(__file__).resolve().parent.parent / "NoteForLaterTests" / "RenderBaselines"


def main() -> int:
    paths = sorted(BASELINES.glob("*.png"))
    if not paths:
        sys.exit(f"No baselines found in {BASELINES}")

    before = after = 0
    for path in paths:
        original_bytes = path.stat().st_size
        with Image.open(path) as image:
            pixels = image.convert("RGBA").tobytes()
            # Carry the ICC profile across explicitly (the renders embed a
            # 536-byte one). Dropping it would leave the raw samples untouched
            # — so a naive pixel check here would still say "lossless" — while
            # changing how a colour-managed decoder interprets them, and
            # `UIImage` + `CGContext` is colour-managed. Preserved as hygiene
            # rather than as a fix for any observed failure.
            profile = image.info.get("icc_profile")
            image.save(path, format="PNG", optimize=True, icc_profile=profile)

        # Re-read and confirm the pixels *and* the profile survived. A
        # lossless claim that isn't checked is just a hope, and this script
        # silently corrupting the baselines would take the whole suite's
        # meaning with it.
        with Image.open(path) as roundtripped:
            if roundtripped.convert("RGBA").tobytes() != pixels:
                sys.exit(f"ABORT: re-encoding changed pixels in {path.name}")
            if roundtripped.info.get("icc_profile") != profile:
                sys.exit(f"ABORT: re-encoding changed the ICC profile in {path.name}")

        before += original_bytes
        after += path.stat().st_size
        print(f"  {path.name:<34} {original_bytes / 1024:>8.0f} KB -> {path.stat().st_size / 1024:>6.0f} KB")

    print(f"\nTotal {before / 1024 / 1024:.1f} MB -> {after / 1024 / 1024:.1f} MB "
          f"({100 * (1 - after / before):.0f}% smaller), pixels unchanged.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
