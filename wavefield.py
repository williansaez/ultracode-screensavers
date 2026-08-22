#!/usr/bin/env python3
"""
Variant "wavefield": Claude Code 'ultracode' shimmer effect as a full-screen
wallpaper. Brightness driven by 2-3 overlapping sinusoidal diagonal waves,
producing flowing bands of bright lavender cells. A leading edge of near-knob
bright cells is scattered along the brightest wavefront with stronger bloom.
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

random.seed(7)

# Palette (sampled)
BG_TOP = (0x23, 0x21, 0x26)
BG_BOTTOM = (0x1B, 0x19, 0x1E)

DIM = [(0x34, 0x31, 0x3A), (0x3D, 0x39, 0x46)]
MID = [(0x56, 0x50, 0x6B), (0x6F, 0x65, 0x90)]
BRIGHT = [(0x9C, 0x8F, 0xD0), (0xB9, 0xAE, 0xE8), (0xCF, 0xC6, 0xF2)]
KNOB = (0xEE, 0xE9, 0xFB)
KNOB_RING = (0x8B, 0x78, 0xE8)

# Grid geometry (at supersampled resolution)
CELL = 46 * SS          # cell square size
GAP = int(CELL * 0.30)  # ~30% gap
PITCH = CELL + GAP
RADIUS = int(CELL * 0.28)

# ----------------------------------------------------------------------------
# Color ramp: piecewise interpolation across the palette stops
# ----------------------------------------------------------------------------
RAMP_STOPS = [
    (0.00, DIM[0]),
    (0.22, DIM[1]),
    (0.45, MID[0]),
    (0.62, MID[1]),
    (0.78, BRIGHT[0]),
    (0.90, BRIGHT[1]),
    (1.00, BRIGHT[2]),
]


def lerp(a, b, t):
    return a + (b - a) * t


def ramp_color(v):
    v = max(0.0, min(1.0, v))
    for i in range(len(RAMP_STOPS) - 1):
        t0, c0 = RAMP_STOPS[i]
        t1, c1 = RAMP_STOPS[i + 1]
        if v <= t1:
            f = (v - t0) / (t1 - t0) if t1 > t0 else 0.0
            return tuple(int(round(lerp(c0[k], c1[k], f))) for k in range(3))
    return RAMP_STOPS[-1][1]


# ----------------------------------------------------------------------------
# Value noise (smooth random field) for organic modulation
# ----------------------------------------------------------------------------
def make_value_noise(nx, ny, seed):
    rnd = random.Random(seed)
    return [[rnd.random() for _ in range(nx)] for _ in range(ny)]


def smoothstep(t):
    return t * t * (3 - 2 * t)


def sample_noise(grid, x, y):
    ny = len(grid)
    nx = len(grid[0])
    x = x % nx
    y = y % ny
    x0, y0 = int(x), int(y)
    x1, y1 = (x0 + 1) % nx, (y0 + 1) % ny
    fx, fy = smoothstep(x - x0), smoothstep(y - y0)
    v00, v10 = grid[y0][x0], grid[y0][x1]
    v01, v11 = grid[y1][x0], grid[y1][x1]
    return lerp(lerp(v00, v10, fx), lerp(v01, v11, fx), fy)


NOISE_A = make_value_noise(24, 16, 101)   # large-scale clusters
NOISE_B = make_value_noise(64, 44, 202)   # finer detail


# ----------------------------------------------------------------------------
# Wave field: 3 overlapping diagonal sinusoidal waves
# ----------------------------------------------------------------------------
DIAG = math.hypot(FINAL_W, FINAL_H)

# (angle radians, wavelength px in final coords, phase, amplitude)
WAVES = [
    (math.radians(28),  920.0, 0.0,   1.00),
    (math.radians(40), 1450.0, 2.1,   0.65),
    (math.radians(16),  560.0, 4.4,   0.40),
]


def wave_value(px, py):
    """px, py in final-resolution coordinates. Returns 0..1 wave intensity."""
    total = 0.0
    amp_sum = 0.0
    for ang, wl, ph, amp in WAVES:
        d = px * math.cos(ang) + py * math.sin(ang)
        s = math.sin(2 * math.pi * d / wl + ph)
        # sharpen crests a little so bands read as fronts, troughs stay dim
        s = 0.5 + 0.5 * s
        s = s ** 1.6
        total += amp * s
        amp_sum += amp
    return total / amp_sum


# Primary wave: locate the ONE crest line nearest the image center, so the
# leading edge clusters along a single brightest wavefront.
def _primary_d(px, py):
    ang, _, _, _ = WAVES[0]
    return px * math.cos(ang) + py * math.sin(ang)


def _nearest_crest_d(d):
    ang, wl, ph, _ = WAVES[0]
    # crest where sin(2*pi*d/wl + ph) = 1  =>  d = wl*(0.25 - ph/(2pi) + k)
    base = wl * (0.25 - ph / (2 * math.pi))
    k = round((d - base) / wl)
    return base + k * wl


# anchor the leading edge on the crest passing nearest a point left of center
LEAD_CREST_D = _nearest_crest_d(_primary_d(FINAL_W * 0.38, FINAL_H * 0.55))


def dist_to_lead_crest(px, py):
    """Absolute distance in px from the chosen single crest line."""
    return abs(_primary_d(px, py) - LEAD_CREST_D)


# ----------------------------------------------------------------------------
# Background with subtle vertical/radial gradient + film grain
# ----------------------------------------------------------------------------
def build_background():
    # Build gradient at low res then upscale (smooth), grain added at full res
    gw, gh = 378, 246
    bg = Image.new("RGB", (gw, gh))
    px = bg.load()
    cx, cy = gw * 0.5, gh * 0.42
    max_d = math.hypot(max(cx, gw - cx), max(cy, gh - cy))
    for y in range(gh):
        for x in range(gw):
            d = math.hypot(x - cx, y - cy) / max_d
            t = min(1.0, 0.25 * (y / gh) + 0.75 * d)  # radial + vertical mix
            c = tuple(int(round(lerp(BG_TOP[k], BG_BOTTOM[k], t))) for k in range(3))
            px[x, y] = c
    bg = bg.resize((W, H), Image.BICUBIC)

    # Film grain: per-pixel noise, very subtle
    import numpy as np  # Pillow 11 environments ship with numpy commonly
    arr = np.asarray(bg).astype(np.int16)
    rng = np.random.default_rng(42)
    grain = rng.integers(-3, 4, size=(H, W, 1), dtype=np.int16)
    arr = np.clip(arr + grain, 0, 255).astype(np.uint8)
    return Image.fromarray(arr, "RGB")


# ----------------------------------------------------------------------------
# Main render
# ----------------------------------------------------------------------------
def main():
    base = build_background()
    draw = ImageDraw.Draw(base)

    # Glow layer: bright cells re-drawn here, blurred, screen-composited
    glow = Image.new("RGB", (W, H), (0, 0, 0))
    gdraw = ImageDraw.Draw(glow)

    # Strong glow layer for leading-edge cells
    glow2 = Image.new("RGB", (W, H), (0, 0, 0))
    g2draw = ImageDraw.Draw(glow2)

    cols = W // PITCH + 2
    rows = H // PITCH + 2
    # center the grid
    ox = (W - (cols - 1) * PITCH - CELL) // 2
    oy = (H - (rows - 1) * PITCH - CELL) // 2

    leading_candidates = []

    for r in range(rows):
        for c in range(cols):
            x0 = ox + c * PITCH
            y0 = oy + r * PITCH
            # cell center in final-res coordinates
            fx = (x0 + CELL / 2) / SS
            fy = (y0 + CELL / 2) / SS

            wv = wave_value(fx, fy)

            # organic modulation from smooth value noise
            na = sample_noise(NOISE_A, c * 24 / cols, r * 16 / rows)
            nb = sample_noise(NOISE_B, c * 64 / cols, r * 44 / rows)
            noise_mod = 0.65 + 0.45 * na + 0.25 * (nb - 0.5)

            v = wv * noise_mod
            # keep troughs visible but dim
            v = 0.06 + 0.94 * max(0.0, min(1.0, v))

            # sparse sparkle cells: small chance, biased toward brighter areas
            sparkle = False
            if random.random() < 0.012 * (0.3 + v):
                v = min(1.0, v + random.uniform(0.25, 0.5))
                sparkle = True

            color = ramp_color(v)
            x1, y1 = x0 + CELL, y0 + CELL
            draw.rounded_rectangle([x0, y0, x1, y1], radius=RADIUS, fill=color)

            # glow contribution from bright cells
            if v > 0.72 or sparkle:
                strength = (v - 0.72) / 0.28 if v > 0.72 else 0.4
                strength = max(0.0, min(1.0, strength))
                gc = tuple(int(ch * strength * 0.85) for ch in color)
                gdraw.rounded_rectangle([x0, y0, x1, y1], radius=RADIUS, fill=gc)

            # collect candidates for leading edge: near the single chosen
            # crest line AND in a bright region
            pd = dist_to_lead_crest(fx, fy)
            if pd < 70.0 and v > 0.55:
                leading_candidates.append((x0, y0, v))

    # ------------------------------------------------------------------
    # Leading edge: scatter a handful of near-knob-bright cells along the
    # brightest wavefront, with stronger bloom.
    # ------------------------------------------------------------------
    random.shuffle(leading_candidates)
    n_lead = min(16, len(leading_candidates))
    chosen = leading_candidates[:n_lead]
    for (x0, y0, v) in chosen:
        x1, y1 = x0 + CELL, y0 + CELL
        # knob-bright fill with a subtle purple ring
        ring_w = max(2, CELL // 12)
        draw.rounded_rectangle([x0, y0, x1, y1], radius=RADIUS, fill=KNOB,
                               outline=KNOB_RING, width=ring_w)
        g2draw.rounded_rectangle([x0 - GAP, y0 - GAP, x1 + GAP, y1 + GAP],
                                 radius=RADIUS + GAP, fill=KNOB)

    # Blur + screen composite glow layers
    glow = glow.filter(ImageFilter.GaussianBlur(CELL * 0.9))
    glow2 = glow2.filter(ImageFilter.GaussianBlur(CELL * 1.5))

    import numpy as np
    b = np.asarray(base).astype(np.float32) / 255.0
    g1 = np.asarray(glow).astype(np.float32) / 255.0
    g2 = np.asarray(glow2).astype(np.float32) / 255.0

    # screen blend: 1 - (1-a)(1-b), glow attenuated to avoid blowout
    out = 1.0 - (1.0 - b) * (1.0 - g1 * 0.55)
    out = 1.0 - (1.0 - out) * (1.0 - g2 * 0.50)
    out = np.clip(out * 255.0, 0, 255).astype(np.uint8)
    final = Image.fromarray(out, "RGB")

    final = final.resize((FINAL_W, FINAL_H), Image.LANCZOS)
    final.save("/Users/williansaez/GitHub/Wallpaper/screenshots/variant_wavefield.png",
               optimize=True)
    print("saved", final.size, "leading cells:", n_lead)


if __name__ == "__main__":
    main()
