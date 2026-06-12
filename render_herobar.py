#!/usr/bin/env python3
"""
Ultracode herobar wallpaper — faithful recreation of the Claude Code "ultracode"
shimmer bar as a centered hero element.

Output: /Users/williansaez/GitHub/Wallpaper/variant_herobar.png  (3024x1964)
Rendered at 2x supersample, LANCZOS downscale.
"""

import math
import random

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------
FINAL_W, FINAL_H = 3024, 1964
SS = 2
W, H = FINAL_W * SS, FINAL_H * SS

OUT_PATH = "/Users/williansaez/GitHub/Wallpaper/variant_herobar.png"

BG_TOP = (0x23, 0x21, 0x26)
BG_BOTTOM = (0x1B, 0x19, 0x1E)
BAR_FILL = (0x2A, 0x27, 0x2E)
BAR_EDGE_HI = (0x4A, 0x44, 0x55)

KNOB_FILL = (0xEE, 0xE9, 0xFB)
KNOB_RING = (0x8B, 0x78, 0xE8)

# Palette ramp (sampled stops)
RAMP = [
    (0.00, (0x34, 0x31, 0x3A)),
    (0.18, (0x3D, 0x39, 0x46)),
    (0.38, (0x56, 0x50, 0x6B)),
    (0.55, (0x6F, 0x65, 0x90)),
    (0.72, (0x9C, 0x8F, 0xD0)),
    (0.87, (0xB9, 0xAE, 0xE8)),
    (1.00, (0xCF, 0xC6, 0xF2)),
]


def ramp_color(t):
    t = max(0.0, min(1.0, t))
    for i in range(len(RAMP) - 1):
        t0, c0 = RAMP[i]
        t1, c1 = RAMP[i + 1]
        if t <= t1:
            f = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
            return tuple(int(round(c0[k] + (c1[k] - c0[k]) * f)) for k in range(3))
    return RAMP[-1][1]


def scale_color(c, f):
    return tuple(max(0, min(255, int(round(v * f)))) for v in c)


# ----------------------------------------------------------------------------
# Value noise (smooth, spatially correlated)
# ----------------------------------------------------------------------------
def value_noise(cols, rows, period, seed):
    rng = random.Random(seed)
    gw = cols // period + 3
    gh = rows // period + 3
    grid = [[rng.random() for _ in range(gw)] for _ in range(gh)]
    out = [[0.0] * cols for _ in range(rows)]
    for r in range(rows):
        fy = r / period
        y0 = int(fy)
        ty = fy - y0
        sy = ty * ty * (3 - 2 * ty)
        for c in range(cols):
            fx = c / period
            x0 = int(fx)
            tx = fx - x0
            sx = tx * tx * (3 - 2 * tx)
            v00 = grid[y0][x0]
            v10 = grid[y0][x0 + 1]
            v01 = grid[y0 + 1][x0]
            v11 = grid[y0 + 1][x0 + 1]
            out[r][c] = (v00 * (1 - sx) + v10 * sx) * (1 - sy) + (
                v01 * (1 - sx) + v11 * sx
            ) * sy
    return out


def octave_noise(cols, rows, seed):
    n1 = value_noise(cols, rows, 9, seed)
    n2 = value_noise(cols, rows, 3, seed + 7919)
    out = [[0.0] * cols for _ in range(rows)]
    for r in range(rows):
        for c in range(cols):
            out[r][c] = 0.65 * n1[r][c] + 0.35 * n2[r][c]
    return out


# ----------------------------------------------------------------------------
# Rounded-pill containment test
# ----------------------------------------------------------------------------
def point_in_round_rect(px, py, x0, y0, x1, y1, rad):
    if px < x0 or px > x1 or py < y0 or py > y1:
        return False
    cx = min(max(px, x0 + rad), x1 - rad)
    cy = min(max(py, y0 + rad), y1 - rad)
    dx, dy = px - cx, py - cy
    return dx * dx + dy * dy <= rad * rad


def rect_in_round_rect(rx0, ry0, rx1, ry1, x0, y0, x1, y1, rad):
    return all(
        point_in_round_rect(px, py, x0, y0, x1, y1, rad)
        for px, py in ((rx0, ry0), (rx1, ry0), (rx0, ry1), (rx1, ry1))
    )


# ----------------------------------------------------------------------------
# 1. Background: radial gradient #232126 -> #1b191e with dithering (no banding)
# ----------------------------------------------------------------------------
def make_background():
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    cx, cy = W / 2.0, H * 0.46
    dx = (xx - cx) / (W * 0.62)
    dy = (yy - cy) / (H * 0.62)
    d = np.sqrt(dx * dx + dy * dy)
    d = np.clip(d, 0.0, 1.0)
    d = d * d * (3 - 2 * d)  # smoothstep falloff

    img = np.empty((H, W, 3), dtype=np.float32)
    for k in range(3):
        img[:, :, k] = BG_TOP[k] + (BG_BOTTOM[k] - BG_TOP[k]) * d

    # Subtle dither to kill banding
    rng = np.random.default_rng(42)
    img += rng.uniform(-0.75, 0.75, size=(H, W, 1)).astype(np.float32)
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")


# ----------------------------------------------------------------------------
# Geometry (all in supersampled px)
# ----------------------------------------------------------------------------
BAR_W = int(0.72 * W)
BAR_H = int(0.09 * H)
BAR_X0 = (W - BAR_W) // 2
BAR_Y0 = (H - BAR_H) // 2
BAR_X1 = BAR_X0 + BAR_W
BAR_Y1 = BAR_Y0 + BAR_H
BAR_RAD = BAR_H // 2

CELL = 14 * SS
GAP = 4 * SS
PITCH = CELL + GAP
CELL_RAD = int(round(0.28 * CELL))

ROWS = 7
GRID_H = ROWS * PITCH - GAP
GRID_TOP = BAR_Y0 + (BAR_H - GRID_H) // 2

# Knob geometry (right end of bar)
KNOB_W = int(BAR_H * 0.34)
KNOB_H = int(BAR_H * 0.64)
KNOB_MARGIN = int(BAR_H * 0.18)
KNOB_X1 = BAR_X1 - KNOB_MARGIN
KNOB_X0 = KNOB_X1 - KNOB_W
KNOB_Y0 = BAR_Y0 + (BAR_H - KNOB_H) // 2
KNOB_Y1 = KNOB_Y0 + KNOB_H
KNOB_RAD = KNOB_W // 2

CELL_REGION_X0 = BAR_X0 + 6 * SS
CELL_REGION_X1 = KNOB_X0 - 10 * SS
INSET = 7 * SS  # pill inset for cell containment


def main():
    canvas = make_background()

    # ------------------------------------------------------------------
    # 2. Faint sparse echo of the grid texture across the background
    # ------------------------------------------------------------------
    echo = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    edraw = ImageDraw.Draw(echo)
    ecols = W // PITCH + 1
    erows = H // PITCH + 1
    enoise = octave_noise(ecols, erows, 1313)
    erng = random.Random(99)
    for r in range(erows):
        for c in range(ecols):
            n = enoise[r][c]
            if n < 0.62:  # sparse: only noise peaks show
                continue
            x = c * PITCH + (PITCH // 2)
            y = r * PITCH + (PITCH // 2)
            t = (n - 0.62) / 0.38
            col = ramp_color(0.30 + 0.30 * t)
            alpha = int(5 + 7 * t + erng.uniform(0, 2))  # ~2-6% opacity
            edraw.rounded_rectangle(
                [x, y, x + CELL, y + CELL], radius=CELL_RAD, fill=col + (alpha,)
            )
    canvas = Image.alpha_composite(canvas.convert("RGBA"), echo).convert("RGB")

    # ------------------------------------------------------------------
    # 3. Ambient lavender glow around the bar (screen-composited)
    # ------------------------------------------------------------------
    ambient = Image.new("RGB", (W, H), (0, 0, 0))
    adraw = ImageDraw.Draw(ambient)
    adraw.rounded_rectangle(
        [BAR_X0, BAR_Y0, BAR_X1, BAR_Y1], radius=BAR_RAD,
        fill=scale_color(KNOB_RING, 0.13),
    )
    ambient_wide = ambient.filter(ImageFilter.GaussianBlur(110 * SS))
    ambient_near = ambient.filter(ImageFilter.GaussianBlur(34 * SS))
    ambient = ImageChops.screen(ambient_wide, ambient_near.point(lambda v: v * 5 // 10))
    canvas = ImageChops.screen(canvas, ambient)

    # ------------------------------------------------------------------
    # 4. Bar pill + subtle 1px lighter top edge
    # ------------------------------------------------------------------
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle(
        [BAR_X0, BAR_Y0, BAR_X1, BAR_Y1], radius=BAR_RAD, fill=BAR_FILL
    )

    # Top edge highlight: outline layer masked by vertical gradient
    edge = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle(
        [BAR_X0, BAR_Y0, BAR_X1, BAR_Y1], radius=BAR_RAD,
        outline=BAR_EDGE_HI + (200,), width=1 * SS,
    )
    grad = Image.new("L", (W, H), 0)
    gdraw = ImageDraw.Draw(grad)
    fade_h = int(BAR_H * 0.55)
    for i in range(fade_h):
        a = int(255 * (1 - i / fade_h) ** 1.6)
        gdraw.line([(0, BAR_Y0 + i), (W, BAR_Y0 + i)], fill=a)
    r_, g_, b_, a_ = edge.split()
    edge = Image.merge("RGBA", (r_, g_, b_, ImageChops.multiply(a_, grad)))
    canvas = Image.alpha_composite(canvas.convert("RGBA"), edge).convert("RGB")

    # ------------------------------------------------------------------
    # 5. Shimmer cell grid inside the bar
    # ------------------------------------------------------------------
    ncols = (CELL_REGION_X1 - CELL_REGION_X0) // PITCH
    noise = octave_noise(ncols, ROWS, 2024)
    crng = random.Random(7)

    draw = ImageDraw.Draw(canvas)
    glow = Image.new("RGB", (W, H), (0, 0, 0))
    gdraw2 = ImageDraw.Draw(glow)

    for c in range(ncols):
        x0 = CELL_REGION_X0 + c * PITCH
        x1 = x0 + CELL
        t = c / max(1, ncols - 1)
        base = 0.07 + 0.70 * (t ** 1.5)  # brightness ramps left -> right
        for r in range(ROWS):
            y0 = GRID_TOP + r * PITCH
            y1 = y0 + CELL
            if not rect_in_round_rect(
                x0, y0, x1, y1,
                BAR_X0 + INSET, BAR_Y0 + INSET, BAR_X1 - INSET, BAR_Y1 - INSET,
                BAR_RAD - INSET,
            ):
                continue
            n = noise[r][c]
            b = base * (0.45 + 1.00 * n)
            # sparse sparkles, more likely toward the right
            if crng.random() < 0.018 + 0.05 * t:
                b = min(1.0, b + 0.45 + crng.uniform(0.0, 0.3))
            # occasional dropout cells for texture
            elif crng.random() < 0.05:
                b *= 0.45
            b = max(0.0, min(1.0, b))
            col = ramp_color(b)
            draw.rounded_rectangle([x0, y0, x1, y1], radius=CELL_RAD, fill=col)
            if b > 0.62:
                f = 0.40 * (b - 0.62) / 0.38
                gdraw2.rounded_rectangle(
                    [x0, y0, x1, y1], radius=CELL_RAD, fill=scale_color(col, f)
                )

    # ------------------------------------------------------------------
    # 6. Knob glow (drawn into glow layer before blurring)
    # ------------------------------------------------------------------
    gdraw2.rounded_rectangle(
        [KNOB_X0 - 5 * SS, KNOB_Y0 - 5 * SS, KNOB_X1 + 5 * SS, KNOB_Y1 + 5 * SS],
        radius=KNOB_RAD + 5 * SS, fill=(0xB9, 0xAE, 0xE8),
    )

    glow_tight = glow.filter(ImageFilter.GaussianBlur(7 * SS))
    glow_soft = glow.filter(ImageFilter.GaussianBlur(22 * SS))
    bloom = ImageChops.screen(
        glow_tight.point(lambda v: v * 5 // 10), glow_soft.point(lambda v: v * 4 // 10)
    )
    canvas = ImageChops.screen(canvas, bloom)

    # ------------------------------------------------------------------
    # 7. Crisp knob on top: #8b78e8 ring around #eee9fb fill
    # ------------------------------------------------------------------
    draw = ImageDraw.Draw(canvas)
    ring_w = 3 * SS
    draw.rounded_rectangle(
        [KNOB_X0 - ring_w, KNOB_Y0 - ring_w, KNOB_X1 + ring_w, KNOB_Y1 + ring_w],
        radius=KNOB_RAD + ring_w, fill=KNOB_RING,
    )
    draw.rounded_rectangle(
        [KNOB_X0, KNOB_Y0, KNOB_X1, KNOB_Y1], radius=KNOB_RAD, fill=KNOB_FILL
    )

    # ------------------------------------------------------------------
    # 8. Downscale and save
    # ------------------------------------------------------------------
    final = canvas.resize((FINAL_W, FINAL_H), Image.LANCZOS)
    final.save(OUT_PATH, "PNG")
    print(f"saved {OUT_PATH} ({final.size[0]}x{final.size[1]})")


if __name__ == "__main__":
    main()
