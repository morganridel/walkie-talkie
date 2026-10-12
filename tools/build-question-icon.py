#!/usr/bin/env python3
"""Build assets/question-mark-icon.png — the ⚡ quick question's mark on the chip.

Usage: tools/build-question-icon.py [frame]

One still of `assets/question-mark.mov` (2026-10-12, Victor: *"în loc de fulger
din fața Asking … un semnul întrebării … galben în stilul celui care apare ca
efect"*), cropped square on the question mark and its first crackle of bolts.
The film's colour is stored premultiplied (`tools/build-question-mark.py`), so it
is divided back by alpha here — read straight, the gold edges came out muddy.
"""
import subprocess, sys, tempfile, pathlib
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
BOX = (470, 160, 790, 590)   # the "?" in the 1280×720 frame
SIZE = 96                    # 18 pt × 2, with room to spare for a 3× screen

def main():
    frame = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    with tempfile.TemporaryDirectory() as d:
        png = f"{d}/f.png"
        subprocess.run(["ffmpeg", "-v", "error", "-i", str(ROOT / "assets/question-mark.mov"),
                        "-vf", f"select=eq(n\\,{frame})", "-frames:v", "1", png], check=True)
        decoded = Image.open(png).convert("RGBA")
    # Its bytes are premultiplied whatever the mode says: relabel them, and PIL
    # divides by alpha on the way back to RGBA.
    im = Image.frombytes("RGBa", decoded.size, decoded.tobytes()).convert("RGBA").crop(BOX)
    side = max(im.size)
    square = Image.new("RGBA", (side, side))
    square.paste(im, ((side - im.width) // 2, (side - im.height) // 2))
    out = ROOT / "assets/question-mark-icon.png"
    square.resize((SIZE, SIZE), Image.LANCZOS).save(out)
    print(out)

if __name__ == "__main__":
    main()
