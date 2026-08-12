#!/usr/bin/env bash
# Regenerate the macOS app icon set from the master Relic art.
#
#   app/scripts/make_macos_icon.sh
#
# Writes app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png.
# Requires python3 with Pillow (pip3 install --user pillow).
#
# WHY THIS EXISTS
# ---------------
# A macOS app icon is not a full-bleed square like the iOS one. Big Sur and
# later draw every app icon as a rounded square that sits inside a transparent
# margin, with a soft drop shadow underneath. Dropping the full-bleed iOS art
# straight into the icon set makes Relic render oversized and sharp cornered
# next to every native app in the Dock, so this script rebuilds the art to the
# real macOS grid.
#
# Every constant below was measured off a stock Apple icon rather than guessed
# (/System/Library/CoreServices/Automator Application Stub.app, whose icon is a
# plain squircle at all ten sizes):
#
#   * Content square per canvas size - Apple does NOT scale the margin
#     proportionally; small sizes get relatively more padding. See GRID below.
#   * Corner radius = 0.225 x the content square (185.4 on the 824 square at
#     1024). Fitting Apple's own mask, a plain circular rounded rect at this
#     radius tracks it to 0.95px RMS / 2.5px max at 1024 - closer than either a
#     superellipse (n=5) or a Figma-style continuous corner.
#   * Drop shadow = pure black at 25% opacity, gaussian sigma 16.25 and y
#     offset +8 at 1024 (both scaled by the content square at other sizes).
#     Fitting those three numbers to Apple's alpha ramp lands within 0.35/255.
#
# The diamond is scaled to the same fraction of the content square that it
# occupies on the iOS icon (569/1024), so the two platforms read identically.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="$(dirname "$here")"

python3 - "$app" <<'PY'
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

APP = Path(sys.argv[1])
SRC = APP / "assets" / "beautiful-icon.png"
OUT = APP / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"

# RelicColors.dark.base (app/lib/theme/tokens.dart), the same value the iOS
# icon and website icon.png use behind the diamond.
BASE = (0x16, 0x13, 0x0E, 255)

# canvas -> content square, straight off Apple's own icon set.
GRID = {16: 10, 32: 24, 64: 50, 128: 102, 256: 204, 512: 410, 1024: 824}

RADIUS_RATIO = 0.225       # corner radius / content square
SHADOW_ALPHA = 64          # /255, pure black
SHADOW_SIGMA = 16.25 / 824  # per unit of content square
SHADOW_DY = 8.0 / 824
GEM_WIDTH = 569 / 1024     # diamond width / content square (matches iOS)
GEM_CY = 511 / 1024        # diamond centre, as a fraction of the square

SS = 8  # supersampling for the rounded-rect mask


def squircle_mask(square: int, size: int, off: float) -> Image.Image:
    """Antialiased mask of the content square, centred on a `size` canvas."""
    m = Image.new("L", (size * SS, size * SS), 0)
    d = ImageDraw.Draw(m)
    x0, y0 = off * SS, off * SS
    d.rounded_rectangle(
        [x0, y0, x0 + square * SS - 1, y0 + square * SS - 1],
        radius=RADIUS_RATIO * square * SS,
        fill=255,
    )
    # BOX = exact area averaging: proper coverage antialiasing on the corner
    # curves with no ringing, and the pixel-aligned straight edges stay hard,
    # exactly as Apple's own mask does.
    return m.resize((size, size), Image.BOX)


def build(size: int, gem: Image.Image) -> Image.Image:
    square = GRID[size]
    off = (size - square) / 2.0
    mask = squircle_mask(square, size, off)

    # Shadow: the content square, blurred, nudged down, at 25% black.
    sigma = SHADOW_SIGMA * square
    dy = SHADOW_DY * square
    pad = int(max(8, sigma * 6))
    big = Image.new("L", (size + 2 * pad, size + 2 * pad), 0)
    big.paste(mask, (pad, pad))
    if sigma > 0:
        big = big.filter(ImageFilter.GaussianBlur(sigma))
    big = big.transform(
        big.size, Image.AFFINE, (1, 0, 0, 0, 1, -dy), resample=Image.BICUBIC
    )
    shadow_a = big.crop((pad, pad, pad + size, pad + size)).point(
        lambda v: v * SHADOW_ALPHA // 255
    )
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.putalpha(shadow_a)

    # The rounded square itself.
    plate = Image.new("RGBA", (size, size), BASE)
    plate.putalpha(mask)

    # The diamond, resampled once from the 291px master.
    bbox = gem.getchannel("A").getbbox()
    gw = bbox[2] - bbox[0]
    scale = (GEM_WIDTH * square) / gw
    art = gem.resize(
        (max(1, round(gem.width * scale)), max(1, round(gem.height * scale))),
        Image.LANCZOS,
    )
    # Keep the diamond's own centre, not the source canvas centre, on target.
    cx_src = (bbox[0] + bbox[2]) / 2 * scale
    cy_src = (bbox[1] + bbox[3]) / 2 * scale
    tx = off + square / 2.0
    ty = off + GEM_CY * square
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    layer.paste(art, (round(tx - cx_src), round(ty - cy_src)), art)
    # Clip the art to the squircle so nothing can bleed past the corners.
    layer.putalpha(Image.composite(layer.getchannel("A"),
                                   Image.new("L", (size, size), 0), mask))
    plate.alpha_composite(layer)

    canvas.alpha_composite(plate)
    return canvas


def main() -> None:
    gem = Image.open(SRC).convert("RGBA")
    for size in sorted(GRID):
        img = build(size, gem)
        path = OUT / f"app_icon_{size}.png"
        img.save(path, "PNG", optimize=True)
        print(f"wrote {path.relative_to(APP.parent)} {size}x{size}")


main()
PY
