#!/usr/bin/env python3
"""Generator for app/macos/dmg-background.png (the PNG is checked in).

600x400 points at @2x = 1200x800 px, saved at 144 dpi so Finder draws it at
600x400 points inside the DMG window create-dmg opens at that size. Icons sit
at (150,190) and (450,190), 100pt, per build_release_macos.sh.

Needs Pillow: python3 -m pip install Pillow. Type is the bundled Stack Sans
faces (docs/design/media-style-guide.md), not the system font, so this runs
anywhere. Re-run after editing, eyeball the PNG, commit both files.

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

# 2026 system, light world (docs/design/media-style-guide.md): parchment
# ground, ink headline, muted body, faint captions. The arrow stays quieter
# than the caption text, same hierarchy the old dark art had.
BG = (0xF5, 0xF1, 0xE8)
TEXT = (0x11, 0x11, 0x10)
BODY = (0x5B, 0x5B, 0x57)
MUTED = (0x9C, 0x9C, 0x96)
ARROW = (0x9C, 0x9C, 0x96)

FONTS = Path(__file__).resolve().parent.parent / "assets" / "fonts"


def font(size, weight=400):
    face = "StackSansHeadline.ttf" if weight >= 600 else "StackSansText.ttf"
    f = ImageFont.truetype(FONTS / face, int(size * S))
    try:
        f.set_variation_by_axes([weight])
    except OSError:
        pass  # static face; the file's own weight stands
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
    BODY,
)
center(
    "Dragging into Applications works too. Then opening it from there is on you.",
    330,
    font(12.5, 400),
    MUTED,
)

img.save(OUT, dpi=(72 * S, 72 * S))
print("wrote", OUT, img.size)
