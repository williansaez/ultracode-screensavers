#!/usr/bin/env python3
"""Ultracode shimmer wallpaper -- variant "minimal".

3024x1964 macOS wallpaper. Dark vertical gradient, a single sparse band of
rounded shimmer cells across the lower third, fading in from the left and
terminating ~70% across at a bright knob pill with a purple ring and glow.

Rendered at 2x and LANCZOS-downscaled for crispness.
"""

import os
import random

from PIL import Image, ImageChops, ImageDraw, ImageFilter

random.seed(20260611)

# ----------------------------------------------------------------------------
# Canvas
# ----------------------------------------------------------------------------
W, H = 3024, 1964
SS = 2                       # supersample factor
w, h = W * SS, H * SS

# ----------------------------------------------------------------------------
# Palette (sampled from screenshot -- do not invent hues)
# ----------------------------------------------------------------------------
def hx(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))

BG_TOP = hx("232126")
BG_BOT = hx("19171c")

PAL = [
    (0.00, hx("34313a")),   # dim
    (0.22, hx("3d3946")),   # dim
    (0.45, hx("56506b")),   # mid
    (0.62, hx("6f6590")),   # mid
    (0.78, hx("9c8fd0")),   # bright
    (0.90, hx("b9aee8")),   # bright
    (1.00, hx("cfc6f2")),   # brightest
]

KNOB_FILL = hx("eee9fb")
KNOB_RING = hx("8b78e8")


def lerp(a, b, t):
    return a + (b - a) * t


def mix(c1, c2, t):
    return tuple(int(round(lerp(a, b, t))) for a, b in zip(c1, c2))


def palette(t):
    t = max(0.0, min(1.0, t))
    for (p0, c0), (p1, c1) in zip(PAL, PAL[1:]):
        if t <= p1:
            f = 0.0 if p1 == p0 else (t - p0) / (p1 - p0)
            return mix(c0, c1, f)
    return PAL[-1][1]


def smoothstep(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3.0 - 2.0 * t)


# ----------------------------------------------------------------------------
# Background: vertical gradient with dither (no banding)
# ----------------------------------------------------------------------------
grad = Image.new("RGB", (1, h))
gp = grad.load()
for y in range(h):
    gp[0, y] = mix(BG_TOP, BG_BOT, y / (h - 1))
bg = grad.resize((w, h), Image.NEAREST)

# +/-1 random dither to break gradient banding
noise = Image.frombytes("L", (w, h), os.urandom(w * h))
plus = noise.point(lambda v: 1 if v < 85 else 0)
minus = noise.point(lambda v: 1 if v > 170 else 0)
bg = ImageChops.add(bg, Image.merge("RGB", (plus, plus, plus)))
bg = ImageChops.subtract(bg, Image.merge("RGB", (minus, minus, minus)))


def bg_at(y):
    return mix(BG_TOP, BG_BOT, max(0.0, min(1.0, y / (h - 1))))


# ----------------------------------------------------------------------------
# Grid geometry (cell pitch ~40 px final -> 80 px at 2x)
# ----------------------------------------------------------------------------
PITCH = 40 * SS
CELL = int(round(PITCH * 0.70))          # ~30% gap
RADIUS = CELL * 0.28                     # 28% corner radius
ROWS = 4                                 # band 3-5 rows tall

band_cy = int(h * 0.70)                  # lower third of the screen
band_top = band_cy - (ROWS * PITCH) // 2

knob_cx = int(w * 0.70)                  # knob terminates ~70% across
KNOB_W = 32 * SS
KNOB_H = ROWS * PITCH - (PITCH - CELL) + 8 * SS
knob_left = knob_cx - KNOB_W // 2

COLS = int((knob_left - 14 * SS) // PITCH)   # last cell clears the knob

# ----------------------------------------------------------------------------
# Value noise: spatially-correlated brightness field (two octaves)
# ----------------------------------------------------------------------------
def value_noise(cols, rows, cw, ch):
    """Coarse random grid upsampled with bicubic -> smooth field."""
    coarse = Image.new("F", (cw, ch))
    cp = coarse.load()
    for yy in range(ch):
        for xx in range(cw):
            cp[xx, yy] = random.random()
    field = coarse.resize((cols, rows), Image.BICUBIC)
    fp = field.load()
    return [[max(0.0, min(1.0, fp[c, r])) for c in range(cols)]
            for r in range(rows)]


oct1 = value_noise(COLS, ROWS, max(2, COLS // 6), 3)
oct2 = value_noise(COLS, ROWS, max(3, COLS // 2), ROWS)

# ----------------------------------------------------------------------------
# Draw cells + glow layer
# ----------------------------------------------------------------------------
draw = ImageDraw.Draw(bg)
glow = Image.new("RGB", (w, h), (0, 0, 0))
gdraw = ImageDraw.Draw(glow)

inset = (PITCH - CELL) / 2.0

for r in range(ROWS):
    for c in range(COLS):
        u = c / (COLS - 1)
        ramp = u ** 1.25                              # builds left -> right
        n = 0.65 * oct1[r][c] + 0.35 * oct2[r][c]     # clustered noise

        t = 0.07 + 0.70 * ramp + (n - 0.5) * 0.55 * (0.35 + 0.65 * ramp)

        # sparse very-bright sparkle cells, denser toward the knob
        if random.random() < 0.035 * (0.08 + 0.92 * ramp ** 1.5):
            t = random.uniform(0.93, 1.0)
        t = max(0.0, min(1.0, t))

        # fade in from the left edge
        fade = smoothstep(min(1.0, c / 7.0 + 0.12))

        x0 = c * PITCH + inset
        y0 = band_top + r * PITCH + inset
        cy = y0 + CELL / 2.0

        color = mix(bg_at(cy), palette(t), fade)
        draw.rounded_rectangle((x0, y0, x0 + CELL, y0 + CELL),
                               radius=RADIUS, fill=color)

        # bright cells contribute soft lavender bloom
        if t > 0.68:
            g = (t - 0.68) / 0.32 * 0.45 * fade
            gc = tuple(int(ch_ * g) for ch_ in palette(t))
            gdraw.rounded_rectangle((x0, y0, x0 + CELL, y0 + CELL),
                                    radius=RADIUS, fill=gc)

# ----------------------------------------------------------------------------
# Knob halo on the glow layer (drawn before blur)
# ----------------------------------------------------------------------------
ky0 = band_cy - KNOB_H // 2
pad = 8 * SS
gdraw.rounded_rectangle(
    (knob_left - pad, ky0 - pad, knob_left + KNOB_W + pad, ky0 + KNOB_H + pad),
    radius=(KNOB_W + 2 * pad) / 2,
    fill=tuple(int(ch_ * 0.55) for ch_ in KNOB_RING),
)

# two-radius bloom: tight + wide, composited with screen
glow_tight = glow.filter(ImageFilter.GaussianBlur(14 * SS / 2))
glow_wide = glow.filter(ImageFilter.GaussianBlur(42 * SS / 2))
glow_wide = glow_wide.point(lambda v: int(v * 0.50))
bg = ImageChops.screen(bg, glow_tight)
bg = ImageChops.screen(bg, glow_wide)

# ----------------------------------------------------------------------------
# Knob pill (crisp, on top of the glow)
# ----------------------------------------------------------------------------
draw = ImageDraw.Draw(bg)
draw.rounded_rectangle(
    (knob_left, ky0, knob_left + KNOB_W, ky0 + KNOB_H),
    radius=KNOB_W / 2,
    fill=KNOB_FILL,
    outline=KNOB_RING,
    width=5 * SS,
)

# ----------------------------------------------------------------------------
# Downscale + save
# ----------------------------------------------------------------------------
final = bg.resize((W, H), Image.LANCZOS)
out = "/Users/williansaez/GitHub/Wallpaper/screenshots/variant_minimal.png"
final.save(out, "PNG")
print("saved", out, final.size)
