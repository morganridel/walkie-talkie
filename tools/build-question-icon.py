#!/usr/bin/env python3
"""Build assets/question-mark-icon-8x6.png — the ⚡ quick question's mark on the chip.

Usage: tools/build-question-icon.py [first-frame]

`assets/question-mark.mov` cropped square on the question mark and its first
crackle of bolts (2026-10-12, Victor: *"în loc de fulger din fața Asking … un
semnul întrebării … galben în stilul celui care apare ca efect"*), then, the
same morning, *"este și animat? Mi-ar plăcea"*: the film's whole 4 s loop at
12 fps, 48 cells packed eight across, read left to right, top to bottom.
`RelayWindow.questionView` plays them; the first cell is the still the states
page photographs. The film's colour is stored premultiplied
(`tools/build-question-mark.py`), so it is divided back by alpha here — read
straight, the gold edges came out muddy.
"""
import subprocess, sys, tempfile, pathlib
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
BOX = (470, 160, 790, 590)   # the "?" in the 1280×720 frame
SIZE = 96                    # 18 pt × 2, with room to spare for a 3× screen
COLS, ROWS = 8, 6            # 48 cells: every other frame of the 96-frame loop

def cell(path):
    decoded = Image.open(path).convert("RGBA")
    # Its bytes are premultiplied whatever the mode says: relabel them, and PIL
    # divides by alpha on the way back to RGBA.
    im = Image.frombytes("RGBa", decoded.size, decoded.tobytes()).convert("RGBA").crop(BOX)
    side = max(im.size)
    square = Image.new("RGBA", (side, side))
    square.paste(im, ((side - im.width) // 2, (side - im.height) // 2))
    return square.resize((SIZE, SIZE), Image.LANCZOS)

def main():
    first = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    with tempfile.TemporaryDirectory() as d:
        subprocess.run(["ffmpeg", "-v", "error", "-i", str(ROOT / "assets/question-mark.mov"),
                        f"{d}/%04d.png"], check=True)
        frames = sorted(pathlib.Path(d).glob("*.png"))
        step = len(frames) // (COLS * ROWS)
        sheet = Image.new("RGBA", (COLS * SIZE, ROWS * SIZE))
        for k in range(COLS * ROWS):
            sheet.paste(cell(frames[(first + k * step) % len(frames)]), ((k % COLS) * SIZE, (k // COLS) * SIZE))
    out = ROOT / f"assets/question-mark-icon-{COLS}x{ROWS}.png"
    sheet.save(out)
    print(out)

if __name__ == "__main__":
    main()
