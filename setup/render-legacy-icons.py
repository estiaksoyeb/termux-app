#!/usr/bin/env python3
"""Render the legacy (pre-API-26) launcher PNGs from ic_foreground.xml.

Adaptive icons only exist on API 26+. Older launchers read the raster mipmaps, so the
same artwork is rasterised here with the terminal's black background baked in and the
foreground scaled into the 72dp safe circle of the 108dp adaptive canvas.
"""
import re
from pathlib import Path

import cairosvg

RES = Path(__file__).resolve().parent.parent / "app/src/main/res"
FOREGROUND = RES / "drawable/ic_foreground.xml"
SIZES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}


def foreground_path_data() -> str:
    src = FOREGROUND.read_text()
    paths = re.findall(r'android:pathData="(.*?)"', src, re.S)
    return " ".join(" ".join(p.split()) for p in paths)


def build_svg(paths: str, round_icon: bool, pad: float = 0.10) -> str:
    """Fit the artwork's own ink bounds into the tile, leaving a small margin.

    The adaptive foreground is authored on the 72dp safe circle inside a 108dp canvas, so the
    mark does not reach the canvas edge and is not centred on it. Legacy icons are a full
    square tile, so the ink bounds are measured and remapped to fill the tile with padding.
    """
    import numpy as np
    from PIL import Image

    # Measure the ink bounds by rasterising the mark alone at high resolution.
    probe = (
        '<svg xmlns="http://www.w3.org/2000/svg" width="108" height="108" viewBox="0 0 108 108">'
        f'<path d="{paths}" fill="#FFFFFF" fill-rule="evenodd"/></svg>'
    )
    png = cairosvg.svg2png(bytestring=probe.encode(), output_width=1080, output_height=1080)
    import io
    arr = np.array(Image.open(io.BytesIO(png)).convert("L"))
    ys, xs = np.where(arr > 40)
    x0, x1 = xs.min() / 10, (xs.max() + 1) / 10
    y0, y1 = ys.min() / 10, (ys.max() + 1) / 10

    w, h = x1 - x0, y1 - y0
    usable = 108 * (1 - 2 * pad)
    scale = usable / max(w, h)
    # Centre the scaled ink in the tile.
    tx = (108 - w * scale) / 2 - x0 * scale
    ty = (108 - h * scale) / 2 - y0 * scale

    clip = (
        '<defs><clipPath id="round"><circle cx="54" cy="54" r="54"/></clipPath></defs>'
        if round_icon else ""
    )
    group_attr = ' clip-path="url(#round)"' if round_icon else ""
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="108" height="108"
     viewBox="0 0 108 108">
  {clip}
  <g{group_attr}>
    <rect width="108" height="108" fill="#000000"/>
    <g transform="translate({tx:.4f},{ty:.4f}) scale({scale:.6f})">
      <path d="{paths}" fill="#FFFFFF" fill-rule="evenodd"/>
    </g>
  </g>
</svg>'''


def main() -> None:
    paths = foreground_path_data()
    for density, size in SIZES.items():
        out_dir = RES / f"mipmap-{density}"
        out_dir.mkdir(parents=True, exist_ok=True)
        for name, is_round in (("ic_launcher.png", False), ("ic_launcher_round.png", True)):
            svg = build_svg(paths, is_round)
            cairosvg.svg2png(bytestring=svg.encode(), write_to=str(out_dir / name),
                             output_width=size, output_height=size)
        print(f"{density}: {size}x{size}")


if __name__ == "__main__":
    main()
