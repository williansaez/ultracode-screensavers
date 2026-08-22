#!/usr/bin/env python3
"""
Claude Code "ultracode" shimmer wallpaper — variant "fullfield".
Full-screen continuous field of rounded-square cells in lavender/purple tones.
Renders at 2x supersample, LANCZOS downscale to 3024x1964.
"""

import math
import random
from PIL import Image, ImageDraw, ImageFilter

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------
FINAL_W, FINAL_H = 3024, 1964
SS = 2  # supersample factor
W, H = FINAL_W * SS, FINAL_H * SS

CELL_PITCH = 52 * SS          # distance between cell centers (~48-56 px at final res)
GAP_FRAC = 0.30               # gap as fraction of cell size
CELL_SIZE = int(round(CELL_PITCH * (1.0 - GAP_FRAC)))   # actual square size
CORNER_R = CELL_SIZE * 0.28

SEED = 1107
rng = random.Random(SEED)

# Palette (RGB)
BG_TOP = (0x23, 0x21, 0x26)
BG_BOT = (0x1B, 0x19, 0x1E)

DIM = [(0x34, 0x31, 0x3A), (0x3D, 0x39, 0x46)]
MID = [(0x56, 0x50, 0x6B), (0x6F, 0x65, 0x90)]
BRIGHT = [(0x9C, 0x8F, 0xD0), (0xB9, 0xAE, 0xE8), (0xCF, 0xC6, 0xF2)]


def lerp(a, b, t):
    return a + (b - a) * t


def lerp_rgb(c1, c2, t):
    return tuple(int(round(lerp(c1[i], c2[i], t))) for i in range(3))


# ----------------------------------------------------------------------------
# Value noise (smooth random field) for spatially-correlated brightness
# ----------------------------------------------------------------------------
def make_value_noise(gw, gh, freq, seed):
    """Returns a function f(gx, gy) -> [0,1] of smooth value noise over grid coords."""
    r = random.Random(seed)
    lat_w = int(gw / freq) + 3
    lat_h = int(gh / freq) + 3
    lattice = [[r.random() for _ in range(lat_w)] for _ in range(lat_h)]

    def smoothstep(t):
        return t * t * (3.0 - 2.0 * t)

    def sample(gx, gy):
        fx = gx / freq
        fy = gy / freq
        x0, y0 = int(fx), int(fy)
        tx, ty = smoothstep(fx - x0), smoothstep(fy - y0)
        v00 = lattice[y0][x0]
        v10 = lattice[y0][x0 + 1]
        v01 = lattice[y0 + 1][x0]
        v11 = lattice[y0 + 1][x0 + 1]
        a = lerp(v00, v10, tx)
        b = lerp(v01, v11, tx)
        return lerp(a, b, ty)

    return sample


# ----------------------------------------------------------------------------
# Grid setup
# ----------------------------------------------------------------------------
cols = W // CELL_PITCH + 2
rows = H // CELL_PITCH + 2
# center the grid
off_x = (W - (cols - 1) * CELL_PITCH) // 2 - CELL_PITCH // 2
off_y = (H - (rows - 1) * CELL_PITCH) // 2 - CELL_PITCH // 2

# Multi-octave value noise for organic clusters
n1 = make_value_noise(cols, rows, 14.0, SEED + 1)   # large blobs
n2 = make_value_noise(cols, rows, 6.0, SEED + 2)    # medium
n3 = make_value_noise(cols, rows, 2.5, SEED + 3)    # fine shimmer

# Diagonal wave field: brightness flows in diagonal bands across the screen
def wave_field(u, v):
    # u, v in [0,1]; diagonal coordinate
    d = u * 0.62 + v * 0.78
    w = 0.5 + 0.5 * math.sin(d * math.pi * 3.1 - 0.9)
    w2 = 0.5 + 0.5 * math.sin(d * math.pi * 5.7 + 1.8)
    return 0.65 * w + 0.35 * w2


def brightness_at(gx, gy):
    u = gx / (cols - 1)
    v = gy / (rows - 1)

    noise = 0.50 * n1(gx, gy) + 0.30 * n2(gx, gy) + 0.20 * n3(gx, gy)
    wave = wave_field(u, v)

    b = 0.60 * noise + 0.40 * wave

    # expand contrast: push lows down, highs up so clusters actually get bright
    b = (b - 0.34) / (0.74 - 0.34)
    b = max(0.0, min(1.0, b))
    b = b ** 1.6

    # composition gradient: calmer upper-left, build toward lower-right
    diag = (u + v) / 2.0
    comp = 0.30 + 1.05 * (diag ** 1.3)
    b *= comp

    # menu-bar zone (top ~5% of screen) extra calm
    if v < 0.055:
        b *= 0.45

    return max(0.0, min(1.0, b))


def color_for(b, sparkle):
    """Map brightness [0,1] to palette color. Returns (rgb, glow_strength)."""
    if sparkle:
        c = BRIGHT[2]
        return c, 1.0
    if b < 0.18:
        t = b / 0.18
        return lerp_rgb(DIM[0], DIM[1], t), 0.0
    if b < 0.42:
        t = (b - 0.18) / 0.24
        return lerp_rgb(DIM[1], MID[0], t), 0.0
    if b < 0.62:
        t = (b - 0.42) / 0.20
        return lerp_rgb(MID[0], MID[1], t), 0.05 * t
    if b < 0.80:
        t = (b - 0.62) / 0.18
        return lerp_rgb(MID[1], BRIGHT[0], t), 0.10 + 0.30 * t
    if b < 0.92:
        t = (b - 0.80) / 0.12
        return lerp_rgb(BRIGHT[0], BRIGHT[1], t), 0.40 + 0.35 * t
    t = (b - 0.92) / 0.08
    return lerp_rgb(BRIGHT[1], BRIGHT[2], t), 0.75 + 0.25 * t


# ----------------------------------------------------------------------------
# Background gradient (vertical with slight radial darkening handled by vignette)
# ----------------------------------------------------------------------------
bg = Image.new("RGB", (W, H))
grad = Image.new("L", (1, H))
for y in range(H):
    grad.putpixel((0, y), int(255 * (y / (H - 1))))
grad = grad.resize((W, H))
top_img = Image.new("RGB", (W, H), BG_TOP)
bot_img = Image.new("RGB", (W, H), BG_BOT)
bg = Image.composite(bot_img, top_img, grad)

# ----------------------------------------------------------------------------
# Draw cells
# ----------------------------------------------------------------------------
draw = ImageDraw.Draw(bg)

# glow layer: only bright cells, drawn then blurred and screen-composited
glow = Image.new("RGB", (W, H), (0, 0, 0))
glow_draw = ImageDraw.Draw(glow)

half = CELL_SIZE / 2.0

for gy in range(rows):
    for gx in range(cols):
        cx = off_x + gx * CELL_PITCH + CELL_PITCH // 2
        cy = off_y + gy * CELL_PITCH + CELL_PITCH // 2
        if cx + half < 0 or cx - half > W or cy + half < 0 or cy - half > H:
            continue

        b = brightness_at(gx, gy)

        # sparse sparkle cells: more likely inside already-bright regions,
        # very rare in dim ones
        sparkle_p = 0.0012 + 0.06 * (b ** 1.8)
        u = gx / (cols - 1)
        v = gy / (rows - 1)
        if v < 0.07:
            sparkle_p *= 0.15  # keep menu bar quiet
        sparkle = rng.random() < sparkle_p

        # tiny per-cell jitter so neighbors are not identical
        b = max(0.0, min(1.0, b + rng.uniform(-0.035, 0.035)))

        rgb, glow_s = color_for(b, sparkle)

        x0 = cx - half
        y0 = cy - half
        x1 = cx + half
        y1 = cy + half
        draw.rounded_rectangle([x0, y0, x1, y1], radius=CORNER_R, fill=rgb)

        if glow_s > 0.03:
            gc = tuple(int(c * glow_s) for c in rgb)
            glow_draw.rounded_rectangle([x0, y0, x1, y1], radius=CORNER_R, fill=gc)

# ----------------------------------------------------------------------------
# Bloom: blur the glow layer at two radii and screen-composite
# ----------------------------------------------------------------------------
bloom_small = glow.filter(ImageFilter.GaussianBlur(radius=10 * SS))
bloom_large = glow.filter(ImageFilter.GaussianBlur(radius=34 * SS))

from PIL import ImageChops
out = ImageChops.screen(bg, bloom_small)
# large bloom at reduced strength
bloom_large = bloom_large.point(lambda p: int(p * 0.55))
out = ImageChops.screen(out, bloom_large)

# ----------------------------------------------------------------------------
# Vignette: edges slightly darker
# ----------------------------------------------------------------------------
vig = Image.new("L", (W // 4, H // 4), 0)
vd = ImageDraw.Draw(vig)
vw, vh = vig.size
for yy in range(vh):
    for xx in range(vw):
        nx = (xx / vw - 0.5) * 2.0
        ny = (yy / vh - 0.5) * 2.0
        d = math.sqrt(nx * nx * 0.92 + ny * ny * 1.0)
        # 255 = full image, darker toward edges
        val = 1.0 - 0.22 * max(0.0, d - 0.55) / 0.65
        vig.putpixel((xx, yy), int(255 * max(0.70, min(1.0, val))))
vig = vig.resize((W, H), Image.BILINEAR).filter(ImageFilter.GaussianBlur(8 * SS))

black = Image.new("RGB", (W, H), (0, 0, 0))
out = Image.composite(out, black, vig)

# ----------------------------------------------------------------------------
# Downscale and save
# ----------------------------------------------------------------------------
final = out.resize((FINAL_W, FINAL_H), Image.LANCZOS)
final.save("/Users/williansaez/GitHub/Wallpaper/screenshots/variant_fullfield.png", "PNG")
print("saved", final.size)
