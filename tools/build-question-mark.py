#!/usr/bin/env python3
"""Build assets/question-mark.mov — the ⚡ quick question's full-screen film.

Usage: tools/build-question-mark.py <clip.mp4> [out.mov]

The clip (Victor, 2026-10-11) is 8 s of a golden electric question mark with
lightning crawling round it, 1280×720 at 24 fps, on black. It is shown over
the whole Retina (2026-10-11, the second ask: *"centrat pe retină … pe tot
ecranul"*), so what comes out is the clip's full frame, not a crop, as HEVC
with an alpha channel — the one format AVFoundation decodes with alpha in
hardware, so `AVPlayerLayer` composites it over the live desktop:

- **Keyed off black**, `a = max(r, g, b)`, with the codec's black floor
  (~0.03; p90 of the dark pixels is 0.043) taken out first so the grain does
  not become a grey veil over the screen. A glow on black is its own
  premultiplied form, so the key is exact.
- **The colour goes in premultiplied**, whatever `bgra` suggests: Apple's
  decoder hands HEVC-alpha frames back as premultiplied, so straight colour
  came out of `AVAssetImageGenerator` brighter by 1/α — the gold went lemon
  and the bolts white (measured 2026-10-11, one frame each way against the
  composite it should be).
- **A 4 s loop at the clip's 24 fps.** The start is the frame whose twin 4 s
  later is the closest, and the last `XFADE` frames are cross-faded into the
  frames *before* the start — the ones that flow into it in the clip — so the
  jump from the last frame to the first is the film going on, not a cut.
"""
import subprocess, sys, tempfile, pathlib
import numpy as np
from PIL import Image

FRAMES = 96          # 4 s at 24 fps
XFADE = 16           # frames blended into the run-up to the start
FLOOR = 0.03

def frames(clip, d):
    subprocess.run(["ffmpeg", "-v", "error", "-i", clip, f"{d}/%04d.png"], check=True)
    return sorted(pathlib.Path(d).glob("*.png"))

def load(f):
    return np.asarray(Image.open(f).convert("RGB"), dtype=np.float32) / 255

def main():
    clip = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else str(pathlib.Path(__file__).resolve().parent.parent / "assets/question-mark.mov")
    with tempfile.TemporaryDirectory() as src_dir, tempfile.TemporaryDirectory() as key_dir:
        files = frames(clip, src_dir)
        small = np.stack([load(f)[::8, ::8].reshape(-1) for f in files])
        starts = range(XFADE, len(files) - FRAMES)
        a = min(starts, key=lambda i: np.abs(small[i] - small[i + FRAMES]).mean())
        print(f"loop: clip frames {a}…{a + FRAMES} (diff {np.abs(small[a] - small[a + FRAMES]).mean():.4f})")
        for k in range(FRAMES):
            f = load(files[a + k])
            into = k - (FRAMES - XFADE)
            if into >= 0:
                # w climbs to just under 1 on the last frame, which is then
                # almost the frame before the start.
                w = (into + 1) / (XFADE + 1)
                w = w * w * (3 - 2 * w)
                f = (1 - w) * f + w * load(files[a + k - FRAMES])
            lum = f.max(axis=2)
            alpha = np.clip((lum - FLOOR) / (1 - FLOOR), 0, 1)
            rgb = np.where(lum[..., None] > 1e-4, f / np.maximum(lum[..., None], 1e-4), 0)
            px = np.dstack([np.clip(rgb, 0, 1) * alpha[..., None], alpha])
            Image.fromarray((px * 255 + 0.5).astype(np.uint8), "RGBA").save(f"{key_dir}/{k:04d}.png")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-framerate", "24", "-i", f"{key_dir}/%04d.png",
                        "-c:v", "hevc_videotoolbox", "-alpha_quality", "0.9", "-b:v", "5M",
                        "-pix_fmt", "bgra", "-tag:v", "hvc1", "-an", out], check=True)
    print(f"wrote {out}: {FRAMES} frames, {FRAMES / 24:.1f} s loop")

if __name__ == "__main__":
    main()
