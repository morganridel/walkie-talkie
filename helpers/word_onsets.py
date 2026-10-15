"""Move each Whisper word's start onto the speech it names (2026-10-04).

Whisper's word timings (cross-attention DTW) make the words contiguous: the word
after a pause *starts in the pause*. Measured on 60 of the user's dictations
(`evals/local-word-timing/`): after every pause of 0.25 s or more, the next
word's start sat a median **620 ms before the audio's own voice onset** (p10
1.7 s early), while parakeet-tdt's sat 60 ms before it. A screenshot taken in
that pause therefore landed one word late — in the pause only 24 % of the time.

The fix is the audio, not the model: 20 ms RMS frames, voiced = 12 dB over the
clip's 10th-percentile floor and over the relay meter's absolute floor (180 on
int16), two voiced frames in a row = an onset. A word whose start is silent is
moved to the first onset inside it, 40 ms early; a word with no onset inside it
is left alone. Pure numpy, ~1 ms for a minute of audio.
"""
import numpy as np

FRAME = 0.02
LEAD = 0.04
ABS_FLOOR = 180 / 32768


def voiced_frames(samples, rate=16000):
    hop = int(FRAME * rate)
    n = len(samples) // hop
    if n < 2:
        return np.zeros(0, dtype=bool)
    frames = np.asarray(samples[:n * hop], dtype=np.float32).reshape(n, hop)
    rms = np.sqrt((frames ** 2).mean(axis=1)) + 1e-9
    db = 20 * np.log10(rms)
    return (db > np.percentile(db, 10) + 12) & (rms > ABS_FLOOR)


def voiced_onsets(samples, rate=16000):
    voiced = voiced_frames(samples, rate)
    if not len(voiced):
        return voiced
    onset = voiced.copy()
    onset[:-1] &= voiced[1:]
    onset[-1] = False
    return onset


STUB = 0.24   # voice at the head of a word that is the previous word's tail
GAP = 0.20    # a silence this long after that stub is the pause


def snap_starts(words, samples, rate=16000):
    """`words` is `[{text, start, end}]`; returns a new list with starts moved.

    Two shapes, both seen in his clips: the word *starts in the silence* (moved
    to the first onset inside it), and the word starts on the last ≤ 240 ms of
    the previous word's voice followed by ≥ 200 ms of silence (moved past the
    silence). Anything else is left where Whisper put it.
    """
    onset = voiced_onsets(samples, rate)
    if not len(onset):
        return words
    voiced = voiced_frames(samples, rate)
    stub, gap = int(round(STUB / FRAME)), int(round(GAP / FRAME))
    out = []
    for w in words:
        w = dict(w)
        a = int(w["start"] / FRAME)
        b = min(len(onset), int(np.ceil(w["end"] / FRAME)))
        if 0 <= a < b:
            k = a
            while k < b and voiced[k] and k - a <= stub:
                k += 1
            head_voiced = k > a
            z = k
            while z < b and not voiced[z]:
                z += 1
            silent = z - k
            if (not head_voiced and silent > 0) or (head_voiced and k - a <= stub and silent >= gap):
                hits = np.flatnonzero(onset[z:b])
                if len(hits):
                    w["start"] = round(min(w["end"], max(w["start"], (z + hits[0]) * FRAME - LEAD)), 3)
        out.append(w)
    return out
