"""After Hue develop prototype.

Deterministic selective-color renderer. The agent (Gemini in the app) only
chooses a recipe; this file turns the recipe into pixels. No generative edits.

Recipe (JSON):
{
  "image": "samples/piano.jpg",
  "colors": [                       # 1-3 kept colors
    {"at": [0.52, 0.31]},           # pick from the photo (normalized x, y)
    {"hex": "#3c55c8"},             # or an explicit color (advanced)
    # optional per color: "width", "softness", "chroma_min", "lightness"
  ],
  "width": 16,                      # hue degrees kept at full strength
  "softness": 24,                   # extra hue degrees over which color fades out
  "area": {                         # optional, null = whole photo
    "polygon": [[x, y], ...],       # normalized coords ("polygons" for several)
    "ellipses": [[cx, cy, rx, ry]], # normalized, may be combined with polygons
    "edge": 0.04                    # feather, as a fraction of the short side
  },
  "mono": {"contrast": 0.12}        # tone of the black-and-white part
}

Commands:
  render  <recipe.json> [--out DIR]   render result, weight map and side-by-side
  probe   <image> x,y [x,y ...]       print OKLCh at normalized points
  hues    <image>                     chroma-weighted hue histogram peaks
  grid    <image> [--out FILE]        save the photo with a 10% coordinate grid
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

HERE = Path(__file__).resolve().parent
# numpy + Accelerate on macOS emits spurious matmul warnings on large arrays
np.seterr(all="ignore")


# ---------------------------------------------------------------- color math

def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


_M1 = np.array([
    [0.4122214708, 0.5363325363, 0.0514459929],
    [0.2119034982, 0.6806995451, 0.1073969566],
    [0.0883024619, 0.2817188376, 0.6299787005],
])
_M2 = np.array([
    [0.2104542553, 0.7936177850, -0.0040720468],
    [1.9779984951, -2.4285922050, 0.4505937099],
    [0.0259040371, 0.7827717662, -0.8086757660],
])
_M1_INV = np.linalg.inv(_M1)
_M2_INV = np.linalg.inv(_M2)


def rgb_to_oklab(rgb):
    lin = srgb_to_linear(rgb)
    lms = lin @ _M1.T
    return np.cbrt(lms) @ _M2.T


def oklab_to_rgb(lab):
    lms = (lab @ _M2_INV.T) ** 3
    return linear_to_srgb(lms @ _M1_INV.T)


def hex_to_oklab(h):
    h = h.lstrip("#")
    rgb = np.array([int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)])
    return rgb_to_oklab(rgb[None, None, :])[0, 0]


def oklab_to_hex(lab):
    rgb = oklab_to_rgb(np.asarray(lab)[None, None, :])[0, 0]
    return "#" + "".join(f"{int(round(v * 255)):02x}" for v in rgb)


def lch(lab):
    L = lab[..., 0]
    a, b = lab[..., 1], lab[..., 2]
    C = np.hypot(a, b)
    H = (np.degrees(np.arctan2(b, a)) + 360) % 360
    return L, C, H


# ---------------------------------------------------------------- helpers

def load(path):
    img = Image.open(path)
    try:
        from PIL import ImageOps
        img = ImageOps.exif_transpose(img)
    except Exception:
        pass
    return np.asarray(img.convert("RGB"), dtype=np.float64) / 255.0


def save(rgb, path):
    Image.fromarray((np.clip(rgb, 0, 1) * 255 + 0.5).astype(np.uint8)).save(path, quality=92)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / max(e1 - e0, 1e-9), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def sample(lab, at, radius_frac=0.008):
    h, w, _ = lab.shape
    x, y = int(at[0] * (w - 1)), int(at[1] * (h - 1))
    r = max(2, int(min(h, w) * radius_frac))
    patch = lab[max(0, y - r):y + r + 1, max(0, x - r):x + r + 1].reshape(-1, 3)
    return np.median(patch, axis=0)


def guided_filter(guide, src, radius, eps):
    """He et al. guided filter: smooths src while following edges in guide."""
    size = 2 * radius + 1
    mean = lambda x: ndimage.uniform_filter(x, size=size, mode="reflect")
    mI, mp = mean(guide), mean(src)
    cov = mean(guide * src) - mI * mp
    var = mean(guide * guide) - mI * mI
    a = cov / (var + eps)
    b = mp - a * mI
    return mean(a) * guide + mean(b)


def area_mask(shape, area):
    h, w = shape
    if not area:
        return np.ones(shape)
    img = Image.new("L", (w, h), 0)
    draw = ImageDraw.Draw(img)
    for poly in area.get("polygons", [area["polygon"]] if "polygon" in area else []):
        draw.polygon([(x * w, y * h) for x, y in poly], fill=255)
    for cx, cy, rx, ry in area.get("ellipses", [area["ellipse"]] if "ellipse" in area else []):
        draw.ellipse([(cx - rx) * w, (cy - ry) * h, (cx + rx) * w, (cy + ry) * h], fill=255)
    m = np.asarray(img, dtype=np.float64) / 255.0
    edge = area.get("edge", 0.04) * min(h, w)
    if edge > 0:
        m = ndimage.gaussian_filter(m, sigma=edge / 2)
    return m


def tone_curve(L, contrast):
    # gentle S-curve around mid grey, keeps black and white points
    if not contrast:
        return L
    x = np.clip(L, 0, 1)
    s = x + contrast * np.sin(2 * math.pi * (x - 0.5)) / (2 * math.pi)
    return np.clip(s, 0, 1)


# ---------------------------------------------------------------- render

def resolve_colors(recipe, lab):
    out = []
    for c in recipe["colors"]:
        ref = hex_to_oklab(c["hex"]) if "hex" in c else sample(lab, c["at"])
        L0, C0, H0 = lch(ref)
        out.append({
            "L": float(L0), "C": float(C0), "H": float(H0), "hex": oklab_to_hex(ref),
            "width": c.get("width", recipe.get("width", 16)),
            "softness": c.get("softness", recipe.get("softness", 24)),
            "chroma_min": c.get("chroma_min", recipe.get("chroma_min", 0.03)),
            "lightness": c.get("lightness"),
        })
    return out


def keep_weight(lab, colors):
    L, C, H = lch(lab)
    w = np.zeros(L.shape)
    for c in colors:
        dh = np.abs((H - c["H"] + 180) % 360 - 180)
        # continuous falloff: full inside width, cosine fade across softness
        t = np.clip((dh - c["width"]) / max(c["softness"], 1e-6), 0, 1)
        wh = 0.5 * (1 + np.cos(math.pi * t))
        # hue is meaningless near grey, so fade in with chroma
        cm = c["chroma_min"]
        wc = smoothstep(cm * 0.5, cm * 1.5, C)
        wl = 1.0
        if c["lightness"]:
            lo, hi = c["lightness"]
            wl = smoothstep(lo - 0.08, lo, L) * (1 - smoothstep(hi, hi + 0.08, L))
        w = np.maximum(w, wh * wc * wl)
    return w


def render(recipe, base=HERE):
    src = load(base / recipe["image"])
    lab = rgb_to_oklab(src)
    colors = resolve_colors(recipe, lab)
    h, w, _ = src.shape

    raw = keep_weight(lab, colors) * area_mask((h, w), recipe.get("area"))
    # edge-aware cleanup so the kept region follows the subject, not pixel noise
    r = max(2, int(min(h, w) * 0.006))
    weight = np.clip(guided_filter(lab[..., 0], raw, r, 2e-3), 0, 1)

    mono = recipe.get("mono", {})
    out = lab.copy()
    out[..., 0] = tone_curve(lab[..., 0], mono.get("contrast", 0.1))
    out[..., 1] *= weight
    out[..., 2] *= weight
    return src, oklab_to_rgb(out), weight, colors


def cmd_render(args):
    recipe_path = Path(args.recipe)
    recipe = json.loads(recipe_path.read_text())
    out_dir = Path(args.out) if args.out else HERE / "out"
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = recipe_path.stem
    src, rgb, weight, colors = render(recipe)
    save(rgb, out_dir / f"{stem}.jpg")
    save(np.repeat(weight[..., None], 3, axis=2), out_dir / f"{stem}.weight.jpg")
    pair = np.concatenate([src, np.ones((src.shape[0], 16, 3)), rgb], axis=1)
    save(pair, out_dir / f"{stem}.pair.jpg")
    for c in colors:
        print(f"kept {c['hex']}  L={c['L']:.2f} C={c['C']:.3f} H={c['H']:.0f}  width={c['width']} softness={c['softness']}")
    print(f"kept area {weight.mean() * 100:.1f}% of photo -> {out_dir / (stem + '.jpg')}")


def cmd_probe(args):
    lab = rgb_to_oklab(load(args.image))
    for p in args.points:
        x, y = map(float, p.split(","))
        ref = sample(lab, (x, y))
        L, C, H = lch(ref)
        print(f"{x:.2f},{y:.2f}  {oklab_to_hex(ref)}  L={L:.2f} C={C:.3f} H={H:.0f}")


def cmd_hues(args):
    lab = rgb_to_oklab(load(args.image))
    L, C, H = lch(lab)
    mask = C > 0.04
    hist, edges = np.histogram(H[mask], bins=36, range=(0, 360), weights=C[mask])
    total = hist.sum()
    for i in np.argsort(hist)[::-1][:10]:
        sel = mask & (H >= edges[i]) & (H < edges[i + 1])
        print(f"H {edges[i]:3.0f}-{edges[i + 1]:3.0f}  share {hist[i] / total * 100:5.1f}%  "
              f"area {sel.mean() * 100:5.1f}%  meanC {C[sel].mean():.3f}  meanL {L[sel].mean():.2f}")


def cmd_grid(args):
    img = Image.open(args.image).convert("RGB")
    w, h = img.size
    d = ImageDraw.Draw(img)
    for i in range(1, 10):
        x, y = w * i / 10, h * i / 10
        d.line([(x, 0), (x, h)], fill=(255, 255, 0), width=2)
        d.line([(0, y), (w, y)], fill=(255, 255, 0), width=2)
        d.text((x + 4, 4), f"{i / 10:.1f}", fill=(255, 255, 0))
        d.text((4, y + 4), f"{i / 10:.1f}", fill=(255, 255, 0))
    out = args.out or str(HERE / "out" / (Path(args.image).stem + ".grid.jpg"))
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    img.save(out, quality=85)
    print(out)


def main(argv=None):
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("render"); r.add_argument("recipe"); r.add_argument("--out")
    pr = sub.add_parser("probe"); pr.add_argument("image"); pr.add_argument("points", nargs="+")
    hu = sub.add_parser("hues"); hu.add_argument("image")
    g = sub.add_parser("grid"); g.add_argument("image"); g.add_argument("--out")
    args = p.parse_args(argv)
    {"render": cmd_render, "probe": cmd_probe, "hues": cmd_hues, "grid": cmd_grid}[args.cmd](args)


if __name__ == "__main__":
    main(sys.argv[1:])
