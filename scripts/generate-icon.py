#!/usr/bin/env python3
"""
Generate the AgyHigher "C" macOS App Icon inspired directly by Google Antigravity's
aerodynamic floating ribbon geometry and vibrant diffused Google 4-color mesh gradient.

Outputs:
  - assets/icon-c-1024.png   (1024x1024 macOS squircle app icon)
  - assets/icon-c-glyph.png  (1024x1024 transparent glyph only)
  - assets/icon-c.svg        (clean vector SVG)
  - assets/AppIcon.icns      (macOS .icns bundle via iconutil)
"""

import os
import shutil
import subprocess
import tempfile
import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS_DIR = os.path.join(ROOT, "assets")
SANDBOX_DIR = os.path.join(ROOT, ".dev-sandbox")
os.makedirs(ASSETS_DIR, exist_ok=True)
os.makedirs(SANDBOX_DIR, exist_ok=True)


def eval_cubic(p0, p1, p2, p3, steps=96):
    ts = np.linspace(0.0, 1.0, steps, endpoint=False)
    omt = 1.0 - ts
    x = (omt**3)*p0[0] + 3*(omt**2)*ts*p1[0] + 3*omt*(ts**2)*p2[0] + (ts**3)*p3[0]
    y = (omt**3)*p0[1] + 3*(omt**2)*ts*p1[1] + 3*omt*(ts**2)*p2[1] + (ts**3)*p3[1]
    return list(zip(x.tolist(), y.tolist()))


def build_c_glyph_polygon(scale=1024.0):
    """
    Antigravity-inspired aerodynamic floating "C" ribbon in normalized [0..1] space:
      - Plush, buoyant rounded spine on the left (echoing Antigravity's levitating apex)
      - Wide, breathable concave inner arch
      - Sleekly tapering upper & lower arms flaring subtly into delicate rounded tips
        (exact calligraphic weight ratio as Antigravity's "A")
    """
    segs = [
        # 1. Delicate upper-right rounded tip (sleek flare, ~0.044 thickness)
        ((0.752, 0.244), (0.778, 0.258), (0.770, 0.292), (0.738, 0.296)),
        # 2. Inner upper arm sweeping gracefully inward & downward
        ((0.738, 0.296), (0.652, 0.304), (0.562, 0.332), (0.506, 0.382)),
        # 3. Deep smooth concave inner curve to plush spine center (x=0.448)
        ((0.506, 0.382), (0.460, 0.422), (0.448, 0.458), (0.448, 0.500)),
        # 4. Inner spine center down to inner lower curve
        ((0.448, 0.500), (0.448, 0.542), (0.460, 0.578), (0.506, 0.618)),
        # 5. Inner lower arm sweeping gracefully out toward lower tip
        ((0.506, 0.618), (0.562, 0.668), (0.652, 0.696), (0.738, 0.704)),
        # 6. Delicate lower-right rounded tip (mirroring Antigravity's weightless flared feet)
        ((0.738, 0.704), (0.770, 0.708), (0.778, 0.742), (0.752, 0.756)),
        # 7. Outer lower sweeping arc toward bottom-left shoulder
        ((0.752, 0.756), (0.680, 0.794), (0.545, 0.812), (0.415, 0.770)),
        # 8. Outer lower-left spine sweeping up into the full buoyant left crest (x=0.222)
        ((0.415, 0.770), (0.285, 0.728), (0.222, 0.625), (0.222, 0.500)),
        # 9. Outer upper-left spine sweeping up to top-left shoulder
        ((0.222, 0.500), (0.222, 0.375), (0.285, 0.272), (0.415, 0.230)),
        # 10. Outer upper sweeping arc back to upper-right tip
        ((0.415, 0.230), (0.545, 0.188), (0.680, 0.206), (0.752, 0.244)),
    ]

    pts = []
    for p0, p1, p2, p3 in segs:
        pts.extend(eval_cubic(p0, p1, p2, p3, steps=96))
    return [(x * scale, y * scale) for x, y in pts], segs


def render_mesh_gradient(size):
    """
    Vibrant Google Antigravity 4-color diffused mesh gradient:
      - Follows the exact color progression of Antigravity's official A mark:
        Emerald Green (left-lower shoulder) -> Sunlit Amber/Gold (left-upper crest)
        -> Fiery Coral Red (top arch & upper tip) -> Electric Cobalt Blue (core + lower sweep & lower tip)
      - Tight Gaussian sigma + radial falloff prevents green+red muddying and keeps pure luminosity.
    """
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) / float(size)

    # Color anchors positioned cleanly along the C silhouette (zero muddy overlap):
    # (cx, cy, sigma, (r, g, b), weight)
    nodes = [
        # Core & lower sweep: vivid Antigravity Electric Cobalt Blue (#2E84FF -> #4298FF)
        (0.42, 0.54, 0.17, (42, 134, 255), 2.40),
        (0.46, 0.74, 0.18, (46, 140, 255), 2.50),
        (0.72, 0.73, 0.17, (68, 154, 255), 2.60),
        # Upper-left spine: luminous Emerald Green (#48C962)
        (0.24, 0.45, 0.145, (66, 202, 96), 2.55),
        # Top-left crest: vibrant Sunlit Gold/Orange (#FFA91C) bridging Green -> Red
        (0.32, 0.26, 0.135, (255, 174, 24), 2.75),
        # Top arch & upper-right arm: vivid Coral Red-Orange (#FF4E33)
        (0.54, 0.22, 0.145, (255, 76, 50), 2.75),
        (0.75, 0.26, 0.145, (252, 72, 58), 2.45),
    ]

    accum = np.zeros((size, size, 3), dtype=np.float32)
    wsum = np.zeros((size, size, 1), dtype=np.float32) + 1e-6

    for cx, cy, sigma, rgb, weight in nodes:
        d2 = (xx - cx) ** 2 + (yy - cy) ** 2
        w = weight * np.exp(-d2 / (2.0 * sigma * sigma))
        w = w[:, :, None]
        accum += w * np.array(rgb, dtype=np.float32)[None, None, :]
        wsum += w

    rgb_img = np.clip(accum / wsum, 0.0, 255.0)

    # Gentle chroma boost (1.08x) around pixel luma so transitions stay crisp & luminous like Google's icon
    luma = (0.299 * rgb_img[:, :, 0] + 0.587 * rgb_img[:, :, 1] + 0.114 * rgb_img[:, :, 2])[:, :, None]
    rgb_img = np.clip(luma + (rgb_img - luma) * 1.12, 0.0, 255.0).astype(np.uint8)
    return rgb_img


def build_squircle_mask(size, margin_frac=0.09, power=3.95):
    """Exact Apple macOS icon squircle matching Antigravity.app's 9% margin & corner curvature."""
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    half = size / 2.0
    r = half * (1.0 - 2.0 * margin_frac)
    nx = np.abs((xx + 0.5 - half) / r)
    ny = np.abs((yy + 0.5 - half) / r)
    dist = (nx ** power + ny ** power) ** (1.0 / power)
    aa = 1.6 / r
    alpha = np.clip((1.0 - dist) / aa + 0.5, 0.0, 1.0)
    return (alpha * 255.0).astype(np.uint8)


def generate_svg(segs, out_path):
    """Write clean standalone vector SVG."""
    d_parts = [f"M {segs[0][0][0]*1024:.2f} {segs[0][0][1]*1024:.2f}"]
    for _, p1, p2, p3 in segs:
        d_parts.append(
            f"C {p1[0]*1024:.2f} {p1[1]*1024:.2f}, {p2[0]*1024:.2f} {p2[1]*1024:.2f}, {p3[0]*1024:.2f} {p3[1]*1024:.2f}"
        )
    d_parts.append("Z")
    d_str = " ".join(d_parts)

    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <radialGradient id="meshBlue" cx="50%" cy="68%" r="55%">
      <stop offset="0%" stop-color="#2A86FF"/>
      <stop offset="100%" stop-color="#449AFF"/>
    </radialGradient>
    <radialGradient id="meshGreen" cx="24%" cy="45%" r="24%">
      <stop offset="0%" stop-color="#42CA60" stop-opacity="0.98"/>
      <stop offset="72%" stop-color="#42CA60" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="meshGold" cx="32%" cy="26%" r="22%">
      <stop offset="0%" stop-color="#FFAE18" stop-opacity="0.98"/>
      <stop offset="75%" stop-color="#FFAE18" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="meshRed" cx="62%" cy="24%" r="28%">
      <stop offset="0%" stop-color="#FF4C32" stop-opacity="0.98"/>
      <stop offset="76%" stop-color="#FF4C32" stop-opacity="0"/>
    </radialGradient>
    <clipPath id="cGlyph">
      <path d="{d_str}"/>
    </clipPath>
  </defs>
  <rect x="92" y="92" width="840" height="840" rx="205" ry="205" fill="#FFFFFF"/>
  <g clip-path="url(#cGlyph)">
    <rect x="0" y="0" width="1024" height="1024" fill="url(#meshBlue)"/>
    <rect x="0" y="0" width="1024" height="1024" fill="url(#meshGreen)"/>
    <rect x="0" y="0" width="1024" height="1024" fill="url(#meshGold)"/>
    <rect x="0" y="0" width="1024" height="1024" fill="url(#meshRed)"/>
  </g>
</svg>
"""
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(svg)


def main():
    FINAL = 1024
    SS = 2048

    # 1. Crisp supersampled glyph mask
    pts, segs = build_c_glyph_polygon(scale=float(SS))
    glyph_mask_hi = Image.new("L", (SS, SS), 0)
    ImageDraw.Draw(glyph_mask_hi).polygon(pts, fill=255)
    glyph_mask = glyph_mask_hi.resize((FINAL, FINAL), Image.Resampling.LANCZOS)

    # 2. Vibrant Google Antigravity 4-color diffused mesh
    mesh_rgb = render_mesh_gradient(FINAL)
    glyph_rgba = Image.fromarray(mesh_rgb).convert("RGBA")
    glyph_rgba.putalpha(glyph_mask)
    glyph_rgba.save(os.path.join(ASSETS_DIR, "icon-c-glyph.png"))

    # 3. Pure crisp white macOS squircle (matching official Antigravity.app cleanly on both dark & light)
    squircle_alpha_hi = build_squircle_mask(SS, margin_frac=0.09, power=3.95)
    squircle_mask = Image.fromarray(squircle_alpha_hi).resize(
        (FINAL, FINAL), Image.Resampling.LANCZOS
    )
    tile_rgba = Image.new("RGBA", (FINAL, FINAL), (255, 255, 255, 255))
    tile_rgba.putalpha(squircle_mask)

    canvas = Image.new("RGBA", (FINAL, FINAL), (0, 0, 0, 0))
    canvas.alpha_composite(tile_rgba)
    canvas.alpha_composite(glyph_rgba)

    icon_png_path = os.path.join(ASSETS_DIR, "icon-c-1024.png")
    canvas.save(icon_png_path)
    generate_svg(segs, os.path.join(ASSETS_DIR, "icon-c.svg"))

    # 4. Build full 10-size macOS AppIcon.icns
    tmp_dir = tempfile.mkdtemp(prefix="agy-iconset-")
    try:
        iconset_dir = os.path.join(tmp_dir, "AppIcon.iconset")
        os.makedirs(iconset_dir, exist_ok=True)
        sizes = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024),
        ]
        for fname, px in sizes:
            canvas.resize((px, px), Image.Resampling.LANCZOS).save(os.path.join(iconset_dir, fname))
        subprocess.run(
            ["/usr/bin/iconutil", "-c", "icns", iconset_dir, "-o", os.path.join(ASSETS_DIR, "AppIcon.icns")],
            check=True,
        )
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)

    # 5. Side-by-side comparison preview
    ref_path = os.path.join(SANDBOX_DIR, "agy-ref-icon.png")
    if os.path.exists(ref_path):
        ref_im = Image.open(ref_path).convert("RGBA").resize((256, 256), Image.Resampling.LANCZOS)
        our_im = canvas.resize((256, 256), Image.Resampling.LANCZOS)
        our_sm = canvas.resize((64, 64), Image.Resampling.LANCZOS)
        ref_sm = ref_im.resize((64, 64), Image.Resampling.LANCZOS)

        comp = Image.new("RGBA", (960, 400), (22, 22, 24, 255))
        comp.paste(Image.new("RGBA", (480, 400), (242, 242, 246, 255)), (480, 0))

        comp.alpha_composite(ref_im.resize((190, 190), Image.Resampling.LANCZOS), (42, 48))
        comp.alpha_composite(our_im.resize((190, 190), Image.Resampling.LANCZOS), (248, 48))
        comp.alpha_composite(ref_sm, (105, 286))
        comp.alpha_composite(our_sm, (311, 286))

        comp.alpha_composite(ref_im.resize((190, 190), Image.Resampling.LANCZOS), (522, 48))
        comp.alpha_composite(our_im.resize((190, 190), Image.Resampling.LANCZOS), (728, 48))
        comp.alpha_composite(ref_sm, (585, 286))
        comp.alpha_composite(our_sm, (791, 286))

        comp.save(os.path.join(SANDBOX_DIR, "icon-comparison.png"))

    print("[OK] Regenerated v2 vibrant Antigravity-inspired C icon & AppIcon.icns")


if __name__ == "__main__":
    main()
