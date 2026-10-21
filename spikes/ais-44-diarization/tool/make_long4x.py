#!/usr/bin/env python3
"""AIS-44 spike: data/l2_4spk_37min.wav = l1_4spk_long.wav repeated 4x (memory/RTF scaling run)."""
import os, wave
D = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")
with wave.open(os.path.join(D, "l1_4spk_long.wav")) as w:
    p, frames = w.getparams(), w.readframes(w.getnframes())
with wave.open(os.path.join(D, "l2_4spk_37min.wav"), "wb") as o:
    o.setparams(p); o.writeframes(frames * 4)
