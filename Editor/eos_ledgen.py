"""EOS LED Studio 2.0 effect renderer/compiler.

The FPGA/runtime stays deliberately simple.  This module renders rich lighting
fx into ordinary WS2812 frames and compiles those frames to the existing EOS
script language.  No new gateware opcodes are required.
"""
from __future__ import annotations

import math
import random
import eos_language as L

RGB = tuple[int, int, int]
BLACK: RGB = (0, 0, 0)
WHITE: RGB = (255, 255, 255)


def clamp8(v):
    return 0 if v < 0 else (255 if v > 255 else int(v))


def scale_pixel(px, brightness):
    if brightness >= 255:
        return tuple(px)
    k = max(0, brightness) / 255.0
    return tuple(clamp8(c * k) for c in px)


def rgb_to_grb_hex(px):
    """WS2812 wants G,R,B bytes. Return 6 hex chars."""
    r, g, b = (clamp8(px[0]), clamp8(px[1]), clamp8(px[2]))
    return f"{g:02X}{r:02X}{b:02X}"


def frame_to_hex(frame, brightness=255):
    return "".join(rgb_to_grb_hex(scale_pixel(px, brightness)) for px in frame)


# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
def hue_to_rgb(h):
    h = (h % 1.0) * 6.0
    i = int(h)
    f = h - i
    q = 1.0 - f
    if i == 0:   r, g, b = 1, f, 0
    elif i == 1: r, g, b = q, 1, 0
    elif i == 2: r, g, b = 0, 1, f
    elif i == 3: r, g, b = 0, q, 1
    elif i == 4: r, g, b = f, 0, 1
    else:        r, g, b = 1, 0, q
    return (clamp8(r * 255), clamp8(g * 255), clamp8(b * 255))


def hsv_to_rgb(h, s=1.0, v=1.0):
    h %= 1.0
    s = max(0.0, min(1.0, s)); v = max(0.0, min(1.0, v))
    i = int(h * 6.0)
    f = h * 6.0 - i
    p = v * (1.0 - s)
    q = v * (1.0 - f * s)
    t = v * (1.0 - (1.0 - f) * s)
    i %= 6
    vals = ((v, t, p), (q, v, p), (p, v, t),
            (p, q, v), (t, p, v), (v, p, q))[i]
    return tuple(clamp8(x * 255) for x in vals)


def _lerp(a, b, t):
    t = max(0.0, min(1.0, t))
    return tuple(clamp8(a[i] + (b[i] - a[i]) * t) for i in range(3))


def _mul(c, k):
    return tuple(clamp8(x * k) for x in c)


def _add(a, b):
    return tuple(clamp8(a[i] + b[i]) for i in range(3))


def sample_palette(palette, x, blend=True):
    pal = [tuple(c) for c in palette if c is not None]
    if not pal:
        return WHITE
    if len(pal) == 1:
        return pal[0]
    x %= 1.0
    pos = x * len(pal)
    i0 = int(math.floor(pos)) % len(pal)
    if not blend:
        return pal[i0]
    i1 = (i0 + 1) % len(pal)
    return _lerp(pal[i0], pal[i1], pos - math.floor(pos))


# ---------------------------------------------------------------------------
# Effect catalogue. controls tells the UI what is meaningful.
# ---------------------------------------------------------------------------
EFFECT_SPECS = {
    "Solid":            {"controls": ("colorA",), "desc": "One static colour."},
    "Gradient":         {"controls": ("colorA", "colorB", "intensity"), "desc": "Static A→B gradient."},
    "Breathe":          {"controls": ("colorA", "speed", "intensity"), "desc": "Smooth fade to black with a soft trough."},
    "Color wipe":       {"controls": ("colorA", "colorB", "speed"), "desc": "Progressively fills the strip."},
    "Larson scanner":   {"controls": ("colorA", "colorB", "speed", "intensity", "width"), "desc": "Cylon/KITT scanner with a fading tail."},
    "Rainbow":          {"controls": ("speed", "intensity"), "desc": "Full-spectrum travelling rainbow."},
    "Theater chase":    {"controls": ("colorA", "colorB", "speed", "intensity", "width"), "desc": "Marching blocks with adjustable spacing."},
    "Twinkle":          {"controls": ("colorA", "colorB", "speed", "intensity", "width"), "desc": "Random glints over a dim background."},
    "Comet":            {"controls": ("colorA", "colorB", "speed", "intensity", "width"), "desc": "Single moving head with a tapered tail."},
    "Meteor":           {"controls": ("colorA", "colorB", "colorC", "speed", "intensity", "width"), "desc": "Multiple moving heads and persistent tails."},
    "Clock spin":       {"controls": ("colorA", "colorB", "speed", "width"), "desc": "A bright segment rotates over a background."},
    "Plasma":           {"controls": ("speed", "intensity", "width"), "desc": "Layered moving colour field."},
    "Fire / flicker":   {"controls": ("colorA", "colorB", "speed", "intensity"), "desc": "Organic heat/flicker simulation."},
    "Palette cycle":    {"controls": ("colorA", "colorB", "colorC", "colorD", "speed", "intensity"), "desc": "Smooth rotating multi-colour palette."},
    "Palette chase":    {"controls": ("colorA", "colorB", "colorC", "colorD", "speed", "intensity", "width"), "desc": "Palette-coloured blocks moving around the strip."},
    "UNSC ↔ Covenant":  {"controls": ("colorA", "colorB", "colorC", "colorD", "speed", "intensity", "width"), "desc": "Opposing blue/purple energy fronts."},
}

# Compatibility with older Studio callers.
EFFECTS = {name: ("colorA" in spec["controls"], None) for name, spec in EFFECT_SPECS.items()}

QUALITY_FRAMES = {
    "Compact": 8,
    "Balanced": 16,
    "Smooth": 24,
    "Maximum": 32,
}

PALETTE_PRESETS = {
    "EOS Purple": [(196, 64, 255), (255, 42, 170), (56, 184, 255), (20, 255, 180)],
    "Xbox Green": [(16, 255, 48), (0, 150, 38), (160, 255, 110), (0, 60, 20)],
    "Trans": [(91, 206, 250), (245, 169, 184), (255, 255, 255), (245, 169, 184)],
    "Cyber": [(255, 0, 170), (117, 37, 255), (0, 220, 255), (0, 255, 150)],
    "Sunset": [(255, 35, 76), (255, 112, 34), (255, 210, 80), (136, 56, 255)],
    "Halo": [(82, 154, 255), (34, 84, 190), (226, 102, 255), (120, 38, 186)],
    "Fire": [(255, 32, 0), (255, 96, 0), (255, 210, 40), (255, 255, 210)],
}


def max_frames_for_count(count):
    if count <= 0:
        return 1
    payload_cap = L.LIMITS["MAX_PAYLOAD_DECODED"] // (count * 3)
    return max(1, min(L.LIMITS["MAX_DATA"], payload_cap))


def frames_for_quality(count, quality):
    wanted = QUALITY_FRAMES.get(quality, 16)
    return max(1, min(wanted, max_frames_for_count(count)))


def speed_to_delay(speed):
    """Authoring slider 0..255 -> frame delay. Higher means faster."""
    s = max(0.0, min(1.0, speed / 255.0))
    # Perceptually useful range: 420 ms slow ambience -> 28 ms fast motion.
    return int(round(28.0 + (420.0 - 28.0) * ((1.0 - s) ** 1.65)))


def _transform(frame, direction="Forward", offset=0):
    f = list(frame)
    if not f:
        return f
    off = int(offset) % len(f)
    if off:
        f = f[-off:] + f[:-off]
    if direction == "Reverse":
        f.reverse()
    return f


def render_effect(name, count, frame_count=16, palette=None, speed=128,
                  intensity=128, width=4, direction="Forward", offset=0,
                  seed=0xE05):
    """Render one named effect into deterministic RGB frames."""
    count = max(1, int(count))
    frame_count = max(1, min(int(frame_count), max_frames_for_count(count)))
    speed = max(0, min(255, int(speed)))
    intensity = max(0, min(255, int(intensity)))
    width = max(1, int(width))
    pal = list(palette or [(255, 0, 0), (0, 0, 0), (0, 0, 255), (255, 0, 255)])[:4]
    while len(pal) < 4:
        pal.append(BLACK)
    a, b, c, d = pal
    rng = random.Random(seed + count * 31 + frame_count * 17)

    if name == "Solid":
        frames = [[a] * count]
    elif name == "Gradient":
        mix = intensity / 255.0
        frames = [[_lerp(a, b, (i / max(1, count - 1)) * mix) for i in range(count)]]
    elif name == "Breathe":
        frames = []
        gamma = 2.0 + (intensity / 255.0) * 0.8
        for s in range(frame_count):
            ph = s / frame_count
            y = 0.5 - 0.5 * math.cos(2.0 * math.pi * ph)
            level = y ** (1.0 / gamma)
            if y < 0.025: level = 0.0
            frames.append([_mul(a, level)] * count)
    elif name == "Color wipe":
        frames = []
        for s in range(frame_count):
            upto = int(round(((s + 1) / frame_count) * count))
            frames.append([a if i < upto else b for i in range(count)])
    elif name == "Larson scanner":
        frames = []
        span = max(1, min(width, count))
        trail = 0.12 + (intensity / 255.0) * 0.72
        for s in range(frame_count):
            t = s / frame_count
            tri = 1.0 - abs(2.0 * t - 1.0)
            pos = int(round(tri * max(0, count - 1)))
            fr = [_mul(b, 0.25) for _ in range(count)]
            for i in range(count):
                dist = abs(i - pos)
                if dist <= span:
                    k = max(0.0, 1.0 - dist / (span + 0.001))
                    fr[i] = _add(fr[i], _mul(a, k * (0.35 + 0.65 * trail)))
            frames.append(fr)
    elif name == "Rainbow":
        sat = 0.55 + 0.45 * (intensity / 255.0)
        frames = [[hsv_to_rgb(i / count + s / frame_count, sat, 1.0)
                   for i in range(count)] for s in range(frame_count)]
    elif name == "Theater chase":
        frames = []
        block = max(1, width)
        gap = block + max(1, int(round(block * (0.5 + intensity / 255.0 * 1.5))))
        for s in range(frame_count):
            shift = int((s / frame_count) * gap)
            frames.append([a if ((i - shift) % gap) < block else b for i in range(count)])
    elif name == "Twinkle":
        # Fixed stars with phase offsets make the compiled loop seamless/deterministic.
        density = max(1, int(round(count * (0.04 + 0.30 * intensity / 255.0))))
        stars = [(rng.randrange(count), rng.randrange(frame_count), rng.uniform(0.65, 1.0))
                 for _ in range(density)]
        frames = []
        bg = _mul(b, 0.18)
        life = max(2, min(frame_count // 2, width + 2))
        for s in range(frame_count):
            fr = [bg] * count
            for pos, phase, gain in stars:
                delta = (s - phase) % frame_count
                if delta < life:
                    x = delta / max(1, life - 1)
                    glow = (math.sin(math.pi * x) ** 3) * gain
                    fr[pos] = _add(fr[pos], _mul(a, glow))
            frames.append(fr)
    elif name == "Comet":
        frames = []
        tail = max(2, min(count, width * 2))
        bg = _mul(b, (255 - intensity) / 255.0 * 0.12)
        for s in range(frame_count):
            pos = int((s / frame_count) * count) % count
            fr = [bg] * count
            for k in range(tail):
                fall = (1.0 - k / tail) ** 2
                fr[(pos - k) % count] = _add(fr[(pos - k) % count], _mul(a, fall))
            frames.append(fr)
    elif name == "Meteor":
        frames = []
        heads = max(1, min(6, 1 + intensity // 48))
        tail = max(2, min(count, width * 2 + 2))
        starts = [rng.random() for _ in range(heads)]
        rates = [0.7 + rng.random() * 0.8 for _ in range(heads)]
        cols = [a, b, c, a, c, b]
        for s in range(frame_count):
            fr = [BLACK] * count
            for m in range(heads):
                pos = int(((starts[m] + (s / frame_count) * rates[m]) % 1.0) * count)
                head = cols[m % len(cols)]
                for k in range(tail):
                    fall = (1.0 - k / tail) ** 2
                    idx = (pos - k) % count
                    fr[idx] = _add(fr[idx], _mul(head, fall))
            frames.append(fr)
    elif name == "Clock spin":
        frames = []
        span = max(1, min(count, width))
        for s in range(frame_count):
            pos = int((s / frame_count) * count) % count
            fr = [b] * count
            for k in range(span):
                fr[(pos + k) % count] = a
            frames.append(fr)
    elif name == "Plasma":
        frames = []
        contrast = 0.8 + (width / 20.0) * 0.8
        sat = 0.50 + 0.50 * intensity / 255.0
        for s in range(frame_count):
            t = s / frame_count * 2.0 * math.pi
            fr = []
            for i in range(count):
                u = i / count * 2.0 * math.pi
                field = (math.sin(3*u+t)*0.55 + math.sin(5*u-t*0.8)*0.35 + math.sin(7*u+t*1.5)*0.20)
                v = max(0.05, min(1.0, 0.52 + field * 0.34 * contrast))
                h = (0.55 + field * 0.16 + s / frame_count * 0.15) % 1.0
                fr.append(hsv_to_rgb(h, sat, v))
            frames.append(fr)
    elif name == "Fire / flicker":
        # Circular heat-field simulation adapted for a pre-rendered, deterministic loop.
        heat = [rng.randrange(0, 80) for _ in range(count)]
        frames = []
        cooling = int(45 - 32 * intensity / 255.0)
        sparks = 1 + speed // 70
        for _s in range(frame_count):
            for i in range(count):
                heat[i] = max(0, heat[i] - rng.randrange(max(2, cooling + 1)))
            old = heat[:]
            for i in range(count):
                heat[i] = int((old[i] + old[(i-1) % count] + old[(i+1) % count]) / 3)
            for _ in range(sparks):
                p = rng.randrange(count)
                heat[p] = min(255, heat[p] + rng.randrange(150, 256))
            fr = []
            for h in heat:
                x = h / 255.0
                if x < 0.45:
                    fr.append(_lerp(BLACK, a, x / 0.45))
                else:
                    fr.append(_lerp(a, b if b != BLACK else (255, 220, 80), (x - 0.45) / 0.55))
            frames.append(fr)
    elif name == "Palette cycle":
        blend = intensity > 16
        frames = [[sample_palette(pal, i / count + s / frame_count, blend)
                   for i in range(count)] for s in range(frame_count)]
    elif name == "Palette chase":
        frames = []
        block = max(1, width)
        for s in range(frame_count):
            shift = int((s / frame_count) * block * 4)
            fr = []
            for i in range(count):
                pidx = ((i - shift) // block) % 4
                base = pal[pidx]
                edge = ((i - shift) % block) / max(1, block - 1)
                soften = 1.0 - (intensity / 255.0) * abs(edge - 0.5) * 0.65
                fr.append(_mul(base, soften))
            frames.append(fr)
    elif name == "UNSC ↔ Covenant":
        frames = []
        unsc = a if a != BLACK else (80, 150, 255)
        unsc2 = b if b != BLACK else (35, 70, 190)
        cov = c if c != BLACK else (225, 90, 255)
        cov2 = d if d != BLACK else (120, 35, 190)
        span = max(2, width)
        for s in range(frame_count):
            pos1 = int((s / frame_count) * count) % count
            pos2 = (count - 1 - pos1) % count
            fr = [BLACK] * count
            pulse = 0.65 + 0.35 * math.sin(2*math.pi*s/frame_count) ** 2
            for k in range(span):
                fall = (1.0 - k / span) ** 2 * pulse
                fr[(pos1-k) % count] = _add(fr[(pos1-k) % count], _mul(_lerp(unsc, unsc2, k/span), fall))
                fr[(pos2+k) % count] = _add(fr[(pos2+k) % count], _mul(_lerp(cov, cov2, k/span), fall))
            frames.append(fr)
    else:
        frames = [[a] * count]

    return [_transform(f, direction, offset) for f in frames]


def render_design(name, count, quality="Balanced", palette=None, speed=128,
                  intensity=128, width=4, direction="Forward", offset=0):
    n = 1 if name in ("Solid", "Gradient") else frames_for_quality(count, quality)
    frames = render_effect(name, count, n, palette, speed, intensity, width,
                           direction, offset)
    delay = speed_to_delay(speed)
    delays = [delay] * len(frames)
    # Static effects don't need arbitrary delay but DELAY 100 keeps generated loop valid/simple.
    if len(frames) == 1:
        delays = [100]
    return frames, delays


# ---------------------------------------------------------------------------
# Budget + compiler
# ---------------------------------------------------------------------------
def check_budget(count, n_frames):
    problems = []
    if not (1 <= count <= L.LIMITS["WS_MAX_COUNT"]):
        problems.append(f"LED count must be 1..{L.LIMITS['WS_MAX_COUNT']}.")
    frame_bytes = count * 3
    if frame_bytes > L.LIMITS["WS_MAX_FRAME_BYTES"]:
        problems.append(f"A frame is {frame_bytes} B; max {L.LIMITS['WS_MAX_FRAME_BYTES']}.")
    if n_frames > L.LIMITS["MAX_DATA"]:
        problems.append(f"{n_frames} frames exceeds the {L.LIMITS['MAX_DATA']}-DATA limit.")
    total = frame_bytes * n_frames
    if total > L.LIMITS["MAX_PAYLOAD_DECODED"]:
        problems.append(f"Total frame data {total} B exceeds {L.LIMITS['MAX_PAYLOAD_DECODED']} B.")
    return problems


def budget_info(count, n_frames):
    frame_bytes = count * 3
    total = frame_bytes * n_frames
    return {
        "frame_bytes": frame_bytes,
        "frames": n_frames,
        "data_slots_used": n_frames,
        "data_slots_max": L.LIMITS["MAX_DATA"],
        "payload_used": total,
        "payload_max": L.LIMITS["MAX_PAYLOAD_DECODED"],
        "max_frames_for_count": max_frames_for_count(count),
        "problems": check_budget(count, n_frames),
    }


def generate_script(pin, name, frames, delays, brightness=255, target="NOHD"):
    count = len(frames[0]) if frames else 1
    safe_name = "".join(ch for ch in (name or "anim") if ch.isalnum() or ch == "_")[:12] or "anim"
    out = ["# Generated by EOS LED Studio 2.0 — edit freely.",
           f"TARGET {target}", "",
           f"USES {pin} AS WS2812 COUNT {count}", "", "LOOP"]
    for i in range(len(frames)):
        out.append(f"  WS {pin} {safe_name}{i}")
        out.append(f"  DELAY {max(0, min(L.LIMITS['DELAY_MAX'], int(delays[i])))}")
    out += ["ENDLOOP", "END", ""]
    for i, f in enumerate(frames):
        out.append(f"DATA {safe_name}{i} {_grouped(frame_to_hex(f, brightness))}")
    return "\n".join(out) + "\n"


def _grouped(hexstr):
    return " ".join(hexstr[i:i + 6] for i in range(0, len(hexstr), 6))
