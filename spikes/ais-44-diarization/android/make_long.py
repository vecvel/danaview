#!/usr/bin/env python3
"""AIS-44 Android half: long clips from the four tracked short clips (no macOS `say` here).

data/a1_3spk_long.wav  = (c1, c2, c4, c5) x 5, 1 s noise-floor gaps  (~9.3 min, like l1)
data/a2_3spk_37min.wav = a1 x 4                                       (~37 min, like l2)
Speakers are the voice names from each clip's JSON (Samantha, Daniel, Karen), so the
same voice keeps one label across the clip. Reference JSON/RTTM are written alongside.
"""
import json
import os
import random
import struct
import wave

D = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")
CLIPS = ["c1_2spk_turns", "c2_2spk_overlap", "c4_3spk_overlap", "c5_2spk_similar"]
SR, GAP = 16000, 1.0


def noise(n, rng):
    amp = 32768 * 10 ** (-55 / 20)
    return b"".join(struct.pack("<h", int(rng.gauss(0, amp))) for _ in range(n))


def build(name, reps):
    rng = random.Random(44)
    gap = noise(int(GAP * SR), rng)
    frames, segs, t = [], [], 0.0
    for _ in range(reps):
        for c in CLIPS:
            with wave.open(os.path.join(D, c + ".wav")) as w:
                assert w.getframerate() == SR and w.getnchannels() == 1 and w.getsampwidth() == 2
                pcm = w.readframes(w.getnframes())
                dur = w.getnframes() / SR
            ref = json.load(open(os.path.join(D, c + ".json")))
            for s in ref["segments"]:
                segs.append({"speaker": s["speaker"], "start": round(t + s["start"], 3),
                             "end": round(t + s["end"], 3)})
            frames += [pcm, gap]
            t += dur + GAP
    with wave.open(os.path.join(D, name + ".wav"), "wb") as o:
        o.setnchannels(1); o.setsampwidth(2); o.setframerate(SR)
        o.writeframes(b"".join(frames))
    spk = sorted({s["speaker"] for s in segs})
    json.dump({"clip": name, "duration": round(t, 3), "speakers": spk, "segments": segs},
              open(os.path.join(D, name + ".json"), "w"), indent=1)
    with open(os.path.join(D, name + ".rttm"), "w") as r:
        for s in segs:
            r.write(f"SPEAKER {name} 1 {s['start']:.3f} {s['end'] - s['start']:.3f} <NA> <NA> {s['speaker']} <NA> <NA>\n")
    print(name, f"{t:.1f} s", spk)


if __name__ == "__main__":
    build("a1_3spk_long", 5)
    build("a2_3spk_37min", 20)
