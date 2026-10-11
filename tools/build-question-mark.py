#!/usr/bin/env python3
"""Build assets/question-mark-8x6.png — the ⚡ quick question's halo film.

Usage: tools/build-question-mark.py <clip.mp4> [out.png]

The clip (Victor, 2026-10-11) is 8 s of a golden electric question mark with
lightning crawling round it, 1280×720 at 24 fps, on black. What comes out is a
sprite sheet `CaretHalo.questionLayer` plays as a loop:

- **Cropped square on the mark** — 720 px round its centre, which sits at
  (624, 364) in the clip and does not move.
- **Keyed off black**, `a = max(r, g, b)`, with the codec's black floor
  (~0.03, p90 of the dark pixels 0.043) taken out first so the grain does not
  become a grey veil. A glow on black is its own premultiplied form, so the
  key is exact (`assets/caret-halo-5x5.png`'s rule).
- **Faded radially to nothing at the cell's edge**, so the bolts that run off
  the crop end in light, not in a square.
- **A 4 s loop at 12 fps, 48 cells**, every second frame of the clip. The
  start is the frame whose twin 4 s later is the closest, and the last
  `XFADE` cells are cross-faded into the frames *before* the start — the ones
  that flow into it in the clip — so the jump from the last cell to the first
  is a continuation of the film, not a cut.
"""
import subprocess, sys, tempfile, pathlib
import numpy as np
from PIL import Image

CROP = (264, 0, 720, 720)   # x, y, w, h in the clip
CELL = 300                  # px per cell
STEP = 2                    # clip frames per cell (24 → 12 fps)
CELLS = 48                  # 4 s
COLS, ROWS = 8, 6
XFADE = 8                   # cells blended into the run-up to the start
FLOOR = 0.03
EDGE_IN, EDGE_OUT = 0.62, 0.98   # radial fade, fractions of the half-cell

def frames(clip):
    with tempfile.TemporaryDirectory() as d:
        x, y, w, h = CROP
        subprocess.run(["ffmpeg", "-v", "error", "-i", clip, "-vf",
                        f"crop={w}:{h}:{x}:{y},scale={CELL}:{CELL}:flags=lanczos",
                        f"{d}/%04d.png"], check=True)
        files = sorted(pathlib.Path(d).glob("*.png"))
        return np.stack([np.asarray(Image.open(f).convert("RGB"), dtype=np.float32) / 255 for f in files])

def main():
    clip = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else str(pathlib.Path(__file__).resolve().parent.parent / "assets/question-mark-8x6.png")
    src = frames(clip)
    span = CELLS * STEP
    lo = XFADE * STEP
    small = src[:, ::6, ::6].reshape(len(src), -1)
    starts = range(lo, len(src) - span)
    a = min(starts, key=lambda i: np.abs(small[i] - small[i + span]).mean())
    print(f"loop: clip frames {a}…{a + span} (diff {np.abs(small[a] - small[a + span]).mean():.4f})")

    cells = []
    for k in range(CELLS):
        f = src[a + k * STEP]
        into = k - (CELLS - XFADE)
        if into >= 0:
            # w climbs to just under 1 on the last cell, which is then almost
            # the frame before the start.
            w = (into + 1) / (XFADE + 1)
            w = w * w * (3 - 2 * w)
            f = (1 - w) * f + w * src[a + k * STEP - span]
        cells.append(f)

    yy, xx = np.mgrid[0:CELL, 0:CELL].astype(np.float32)
    r = np.hypot(xx - CELL / 2 + 0.5, yy - CELL / 2 + 0.5) / (CELL / 2)
    t = np.clip((r - EDGE_IN) / (EDGE_OUT - EDGE_IN), 0, 1)
    edge = 1 - t * t * (3 - 2 * t)

    sheet = np.zeros((ROWS * CELL, COLS * CELL, 4), dtype=np.float32)
    for k, f in enumerate(cells):
        lum = f.max(axis=2)
        alpha = np.clip((lum - FLOOR) / (1 - FLOOR), 0, 1) * edge
        # straight colour: the premultiplied glow divided back by its alpha
        rgb = np.where(lum[..., None] > 1e-4, f / np.maximum(lum[..., None], 1e-4), 0)
        # nothing under a zero alpha: the noise there would only cost bytes
        rgb = np.where(alpha[..., None] > 0.5 / 255, rgb, 0)
        rr, cc = divmod(k, COLS)
        sheet[rr * CELL:(rr + 1) * CELL, cc * CELL:(cc + 1) * CELL, :3] = np.clip(rgb, 0, 1)
        sheet[rr * CELL:(rr + 1) * CELL, cc * CELL:(cc + 1) * CELL, 3] = alpha
    Image.fromarray((sheet * 255 + 0.5).astype(np.uint8), "RGBA").save(out, optimize=True)
    print(f"wrote {out}: {CELLS} cells of {CELL}px, {COLS}x{ROWS}")

if __name__ == "__main__":
    main()
