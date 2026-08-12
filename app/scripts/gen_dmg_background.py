#!/usr/bin/env python3
"""Generator for app/macos/dmg-background.png (the PNG is checked in).

600x400 points at @2x = 1200x800 px, saved at 144 dpi so Finder draws it at
600x400 points inside the DMG window create-dmg opens at that size. Icons sit
at (150,190) and (450,190), 100pt, per build_release_macos.sh.

Needs Pillow and the macOS system font: python3 -m pip install Pillow, run on
a Mac. Re-run after editing, eyeball the PNG, commit both files.

The copy leads with double-click, not drag: a double-clicked Relic runs from
the read-only image, offers "Install and reopen" (install_offer.dart), and
ends with the app open in Applications. A drag is a bare Finder copy that
launches nothing, and first-run QA showed users wait on an app that will
never open itself.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parent.parent / "macos" / "dmg-background.png"

S = 2  # @2x
W, H = 600 * S, 400 * S

BG = (0x16, 0x13, 0x0E)
TEXT = (0xEF, 0xE6, 0xD6)
MUTED = (0x8A, 0x80, 0x70)
ARROW = (0x6B, 0x62, 0x54)

SF = "/System/Library/Fonts/SFNS.ttf"


def font(size, weight=400):
    f = ImageFont.truetype(SF, int(size * S))
    # SFNS.ttf axes: Width, Optical Size, GRAD, Weight.
    f.set_variation_by_axes([100, min(96, max(17, size * S)), 400, weight])
    return f


img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)


def center(text, y, f, fill):
    w = d.textbbox((0, 0), text, font=f)[2]
    d.text(((W - w) / 2, y * S), text, font=f, fill=fill)


# Headline above the icon row (icons sit at y=190pt, 100pt tall).
center("Double-click Relic. It installs itself.", 44, font(20, 600), TEXT)

# Arrow across the gap between the two icons (x 250..350pt).
y = 190 * S
d.line([(252 * S, y), (346 * S, y)], fill=ARROW, width=3 * S)
d.polygon(
    [(352 * S, y), (340 * S, y - 8 * S), (340 * S, y + 8 * S)], fill=ARROW
)

# Below the icon row, clear of the icon labels (~y=255pt).
center(
    "Click Install and reopen when Relic asks, and you are done.",
    296,
    font(15, 500),
    TEXT,
)
center(
    "Dragging into Applications works too. Then opening it from there is on you.",
    330,
    font(12.5, 400),
    MUTED,
)

img.save(OUT, dpi=(72 * S, 72 * S))
print("wrote", OUT, img.size)
