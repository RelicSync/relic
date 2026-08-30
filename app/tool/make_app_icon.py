"""Render the Relic app icon from the brand mark.

The mark is the gold shard from the 2026 design system (the same path
`lib/widgets/relic_mark.dart` paints, and the same gradient baked into
`logo-mark.svg`), set on a rounded cream tile. The tile is deliberate: a bare
gradient shard on transparency all but vanishes against a light Windows
taskbar and loses its silhouette at 16px.

Outputs, relative to `app/`:

    assets/app_icon.png                     1024, in-app brand raster
    assets/tray_icon.ico                    tray (16/20/24/32/48/64)
    windows/runner/resources/app_icon.ico   Windows app icon (16..256)

Usage:  python tool/make_app_icon.py

Requires Pillow. Re-run this rather than hand-editing the outputs.
"""

from __future__ import annotations

import os
from PIL import Image, ImageDraw

# --- the mark, in its 148x150 viewBox ---------------------------------------

VW, VH = 148.0, 150.0

# (kind, points). 'L' is a line to a point; 'C' is a cubic with two controls
# and an end point. Transcribed from logo-mark.svg.
START = (27.4388, 140.916)
SEGMENTS = [
    ("L", [(132.709, 140.969)]),
    ("C", [(140.828, 140.973), (146.838, 133.421), (145.013, 125.51)]),
    ("L", [(121.339, 22.9363)]),
    ("C", [(120.235, 18.1532), (116.458, 14.4442), (111.656, 13.4276)]),
    ("L", [(80.9218, 6.92219)]),
    ("C", [(76.2452, 5.93228), (71.4106, 7.66958), (68.4338, 11.4098)]),
    ("L", [(52.6439, 31.2487)]),
    ("L", [(20.1246, 72.1069)]),
    ("L", [(4.33476, 91.9458)]),
    ("C", [(1.35791, 95.686), (0.749738, 100.787), (2.76379, 105.122)]),
    ("L", [(15.9997, 133.613)]),
    ("C", [(18.0679, 138.064), (22.53, 140.913), (27.4388, 140.916)]),
]

# The gradient the asset ships with, along (30,20) -> (130,140) in viewBox units.
GRADIENT = [(0.0, (0xFF, 0xE2, 0x4A)), (0.5, (0xFF, 0xCE, 0x06)), (1.0, (0xF2, 0xA9, 0x3B))]
GRAD_FROM, GRAD_TO = (30.0, 20.0), (130.0, 140.0)

TILE = (0xF7, 0xF2, 0xE7)  # cream, the app's own surface
TILE_RADIUS = 0.20  # fraction of the tile edge
MARK_HEIGHT = 0.60  # fraction of the tile edge


def flatten(steps: int = 48) -> list[tuple[float, float]]:
    """The outline as a polygon, cubics flattened to line segments."""
    pts = [START]
    cur = START
    for kind, ps in SEGMENTS:
        if kind == "L":
            cur = ps[0]
            pts.append(cur)
        else:
            p0, (p1, p2, p3) = cur, ps
            for i in range(1, steps + 1):
                t = i / steps
                u = 1 - t
                x = (u * u * u * p0[0] + 3 * u * u * t * p1[0]
                     + 3 * u * t * t * p2[0] + t * t * t * p3[0])
                y = (u * u * u * p0[1] + 3 * u * u * t * p1[1]
                     + 3 * u * t * t * p2[1] + t * t * t * p3[1])
                pts.append((x, y))
            cur = p3
    return pts


def sample(t: float) -> tuple[int, int, int]:
    """Colour at position `t` (0..1) along the gradient."""
    t = min(1.0, max(0.0, t))
    for (t0, c0), (t1, c1) in zip(GRADIENT, GRADIENT[1:]):
        if t <= t1:
            f = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
            return tuple(round(a + (b - a) * f) for a, b in zip(c0, c1))
    return GRADIENT[-1][1]


def render_mark(px: int) -> Image.Image:
    """The gradient-filled shard, `px` tall, on transparency."""
    ss = 4  # supersample
    w, h = round(px * VW / VH), px
    W, H = w * ss, h * ss
    sx, sy = W / VW, H / VH

    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).polygon([(x * sx, y * sy) for x, y in flatten()], fill=255)

    # The gradient, projected onto the (30,20) -> (130,140) axis.
    grad = Image.new("RGB", (W, H))
    ax, ay = GRAD_FROM[0] * sx, GRAD_FROM[1] * sy
    bx, by = GRAD_TO[0] * sx, GRAD_TO[1] * sy
    dx, dy = bx - ax, by - ay
    span = dx * dx + dy * dy
    px_map = grad.load()
    for y in range(H):
        for x in range(W):
            px_map[x, y] = sample(((x - ax) * dx + (y - ay) * dy) / span)

    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    return out.resize((w, h), Image.LANCZOS)


def render_icon(size: int) -> Image.Image:
    """The full icon: the shard centred on a rounded cream tile."""
    ss = 4
    S = size * ss

    tile = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    corner = ImageDraw.Draw(tile)
    corner.rounded_rectangle([0, 0, S - 1, S - 1],
                            radius=int(S * TILE_RADIUS),
                            fill=TILE + (255,))
    tile = tile.resize((size, size), Image.LANCZOS)

    mark = render_mark(max(1, round(size * MARK_HEIGHT)))
    tile.alpha_composite(mark, ((size - mark.width) // 2, (size - mark.height) // 2))
    return tile


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    app = os.path.dirname(here)

    def out(*parts: str) -> str:
        p = os.path.join(app, *parts)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        return p

    render_icon(1024).save(out("assets", "app_icon.png"))
    print("assets/app_icon.png")

    tray = [16, 20, 24, 32, 48, 64]
    render_icon(64).save(out("assets", "tray_icon.ico"),
                         sizes=[(s, s) for s in tray])
    print("assets/tray_icon.ico", tray)

    win = [16, 24, 32, 48, 64, 128, 256]
    render_icon(256).save(out("windows", "runner", "resources", "app_icon.ico"),
                          sizes=[(s, s) for s in win])
    print("windows/runner/resources/app_icon.ico", win)


if __name__ == "__main__":
    main()
