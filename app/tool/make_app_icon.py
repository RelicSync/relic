"""Render every Relic app icon from the brand mark.

The mark is the gold shard from the 2026 design system (the same path
`lib/widgets/relic_mark.dart` paints, and the same gradient baked into
`logo-mark.svg`), set on a rounded cream tile. The tile is deliberate: a bare
gradient shard on transparency all but vanishes against a light Windows
taskbar and loses its silhouette at 16px.

Everything here is generated from the path, never hand-exported. That is the
whole point: a hand-export is how an icon drifts away from its mark.

Outputs, relative to `app/`:

  shared
    assets/app_icon.png                       1024, in-app brand raster
    assets/tray_icon.ico                      tray (16/20/24/32/48/64)

  windows
    windows/runner/resources/app_icon.ico     Windows app icon (16..256)

  android
    android/.../mipmap-*/ic_launcher.png              48/72/96/144/192
    android/.../mipmap-*/ic_launcher_round.png        circular tile, same sizes
    android/.../mipmap-*/ic_launcher_foreground.png   adaptive fg, 2.25x
    android/.../mipmap-*/ic_launcher_monochrome.png   themed-icon silhouette

Usage:  python tool/make_app_icon.py            # every platform
        python tool/make_app_icon.py android    # one or more of:
                                                # shared windows android

Requires Pillow. Re-run this rather than hand-editing the outputs.
"""

from __future__ import annotations

import os
import sys
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

SS = 4  # supersample factor, everywhere


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


# --- the three ways to draw the mark ----------------------------------------


def _mark_mask(px: int) -> tuple[Image.Image, int, int]:
    """The shard's coverage mask at `SS`x, plus the final (w, h) in real px."""
    w, h = round(px * VW / VH), px
    W, H = w * SS, h * SS
    sx, sy = W / VW, H / VH
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).polygon([(x * sx, y * sy) for x, y in flatten()], fill=255)
    return mask, w, h


def render_mark(px: int) -> Image.Image:
    """The gradient-filled shard, `px` tall, on transparency."""
    mask, w, h = _mark_mask(px)
    W, H = mask.size
    sx, sy = W / VW, H / VH

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


def render_silhouette(px: int, rgb: tuple[int, int, int] = (0, 0, 0)) -> Image.Image:
    """The shard as one flat colour, `px` tall, on transparency.

    For places that tint the art themselves (Android themed icons, the macOS
    menu-bar template) and for small sizes where the gradient just muddies.
    """
    mask, w, h = _mark_mask(px)
    out = Image.new("RGBA", mask.size, rgb + (0,))
    out.putalpha(mask)
    return out.resize((w, h), Image.LANCZOS)


def _square(size: int, mark: Image.Image) -> Image.Image:
    """`mark` centred on a transparent `size` square."""
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(mark, ((size - mark.width) // 2, (size - mark.height) // 2))
    return canvas


def render_bare(size: int, mark_height: float, flat: bool = False) -> Image.Image:
    """The shard alone on a transparent `size` square.

    `mark_height` is the shard's height as a fraction of the canvas edge, so
    callers size against a masked safe zone rather than against the art.
    """
    px = max(1, round(size * mark_height))
    return _square(size, render_silhouette(px) if flat else render_mark(px))


def render_icon(size: int,
                radius: float = TILE_RADIUS,
                mark_height: float = MARK_HEIGHT,
                inset: float = 0.0) -> Image.Image:
    """The full icon: the shard centred on a rounded cream tile.

    `radius` and `mark_height` are fractions of the *tile* edge (`radius=0.5`
    gives a circle; `radius=0.0` a hard square). `inset` is the fraction of the
    canvas edge left blank on each side, for platforms that want the art to sit
    inside a margin grid rather than bleed to the edge.
    """
    S = size * SS
    pad = round(S * inset)
    edge = S - 2 * pad

    tile = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(tile).rounded_rectangle(
        [pad, pad, pad + edge - 1, pad + edge - 1],
        radius=int(edge * radius), fill=TILE + (255,))
    tile = tile.resize((size, size), Image.LANCZOS)

    mark = render_mark(max(1, round(size * (1 - 2 * inset) * mark_height)))
    tile.alpha_composite(mark, ((size - mark.width) // 2, (size - mark.height) // 2))
    return tile


# --- Android ----------------------------------------------------------------

# Density buckets, keyed by the launcher icon's edge in px.
ANDROID_DENSITIES = {
    "mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192,
}

# An adaptive icon is drawn on a 108dp canvas of which only the centre 72dp is
# guaranteed to survive the launcher's mask, so the foreground is 2.25x the
# nominal icon and the art has to live inside that inner two thirds.
ADAPTIVE_SCALE = 108 / 48
ADAPTIVE_SAFE = 72 / 108

# The shard's height as a fraction of the 108dp canvas. 0.60 of the visible
# 72dp keeps the adaptive icon reading at the same weight as the legacy tile,
# and leaves the whole shard well inside the safe circle under any mask.
ADAPTIVE_MARK = MARK_HEIGHT * ADAPTIVE_SAFE


# --- platform emitters ------------------------------------------------------
#
# One function per platform, each taking the `out()` path helper from main().
# Adding a platform means adding an emitter and a line in PLATFORMS; nothing
# above this comment should need to change.
#
# Apple slots in here as `emit_ios()` and `emit_macos()`. Both are `render_icon`
# calls with different arguments, and the two sets of rules are opposites:
#
#   iOS / iPadOS  full-bleed square, corners NOT pre-rounded (iOS masks its
#                 own, and a baked corner renders as a visible double corner),
#                 and NO alpha channel at all (the App Store rejects it). So:
#                 `render_icon(s, radius=0.0).convert("RGB")`.
#   macOS         the opposite. macOS does not mask, so corners are baked in at
#                 a 0.225 radius ratio, and the art sits inside Apple's margin
#                 grid ({16:10, 32:24, 64:50, 128:102, 256:204, 512:410,
#                 1024:824}) rather than filling the canvas. So:
#                 `render_icon(s, radius=0.225, inset=(1 - grid[s] / s) / 2)`.
#
# Both write into `.xcassets` folders that also need a `Contents.json`; that
# file is metadata, not art, and belongs next to the emitter that writes it.


def emit_shared(out) -> None:
    render_icon(1024).save(out("assets", "app_icon.png"))
    print("assets/app_icon.png")

    tray = [16, 20, 24, 32, 48, 64]
    render_icon(64).save(out("assets", "tray_icon.ico"), sizes=[(s, s) for s in tray])
    print("assets/tray_icon.ico", tray)


def emit_windows(out) -> None:
    win = [16, 24, 32, 48, 64, 128, 256]
    render_icon(256).save(out("windows", "runner", "resources", "app_icon.ico"),
                          sizes=[(s, s) for s in win])
    print("windows/runner/resources/app_icon.ico", win)


def emit_android(out) -> None:
    res = ("android", "app", "src", "main", "res")
    for bucket, size in ANDROID_DENSITIES.items():
        mip = res + (f"mipmap-{bucket}",)
        fg = round(size * ADAPTIVE_SCALE)

        # Legacy launcher icon: the same rounded cream tile the desktop ships.
        render_icon(size).save(out(*mip, "ic_launcher.png"))
        # Round-icon launchers get a real circle, not a rounded square.
        render_icon(size, radius=0.5).save(out(*mip, "ic_launcher_round.png"))
        # Adaptive foreground: the bare shard on transparency. The cream comes
        # from @color/ic_launcher_background, so the tile must NOT be baked in
        # here or the mask clips it into a smaller square.
        render_bare(fg, ADAPTIVE_MARK).save(out(*mip, "ic_launcher_foreground.png"))
        # Themed (Android 13+) icons: the same geometry, flat, system-tinted.
        render_bare(fg, ADAPTIVE_MARK, flat=True).save(
            out(*mip, "ic_launcher_monochrome.png"))

        print(f"android mipmap-{bucket}", size, "fg", fg)


PLATFORMS = {
    "shared": emit_shared,
    "windows": emit_windows,
    "android": emit_android,
}


def main(argv: list[str]) -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    app = os.path.dirname(here)

    def out(*parts: str) -> str:
        p = os.path.join(app, *parts)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        return p

    wanted = argv or list(PLATFORMS)
    unknown = [a for a in wanted if a not in PLATFORMS]
    if unknown:
        sys.exit(f"unknown platform(s): {', '.join(unknown)}\n"
                 f"choose from: {', '.join(PLATFORMS)}")

    for name in wanted:
        PLATFORMS[name](out)


if __name__ == "__main__":
    main(sys.argv[1:])
