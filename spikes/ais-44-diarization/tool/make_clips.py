#!/usr/bin/env python3
"""AIS-44 spike: synthesise the diarization test clips with macOS `say`.

Writes 16 kHz mono 16-bit WAVs plus ground truth (RTTM and JSON) into
data/ (git-ignored; re-run this script to regenerate). No network.

Each utterance is rendered by `say`, trimmed to its speech span (energy
threshold), and placed on a timeline. A negative gap means the next speaker
starts before the previous one ends, i.e. overlapping speech. The ground
truth segment for an utterance is its trimmed span on the timeline.

Usage: python3 tool/make_clips.py [--long-minutes 10]
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import wave

import numpy as np

SR = 16000
HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(os.path.dirname(HERE), "data")

SENTENCES = [
    "Good morning everyone, thanks for joining the call today.",
    "I wanted to start with a quick update on the launch schedule.",
    "We moved the review to Thursday because the build was late.",
    "That makes sense, but the marketing team needs the screenshots first.",
    "Can we share a draft of the release notes by tomorrow afternoon?",
    "Sure, I will write them tonight and send them around.",
    "The editor feels much faster since the last round of fixes.",
    "I noticed the captions drift a little on long videos though.",
    "Let's look at that one together after this meeting.",
    "Honestly the new speaker lanes are my favourite part of the update.",
    "We still need to decide how big the model download should be.",
    "Smaller is better, people hate waiting on a slow connection.",
    "I agree, and the phone gets warm when it runs for a long time.",
    "Should we test it on the older devices before we decide?",
    "Yes, the low tier is where it matters most.",
    "Okay, I think that covers everything on my list for today.",
    "One more thing, the photos import was broken on my tablet.",
    "Really? It worked fine for me this morning on the phone.",
    "Maybe it depends on the album size, I had thousands of pictures.",
    "Send me the steps and I will try to reproduce it.",
    "Thanks, talk to you all again next week.",
    "Bye for now, and good luck with the release.",
]

# Clip definitions: list of (voice, sentence index, gap seconds before it).
# Negative gap = overlap with the previous utterance.
CLIPS = {
    # Two clearly different voices, clean turns.
    "c1_2spk_turns": [("Samantha", 0, 0.5), ("Daniel", 1, 0.6), ("Samantha", 2, 0.5),
                       ("Daniel", 3, 0.4), ("Samantha", 4, 0.7), ("Daniel", 5, 0.5),
                       ("Samantha", 6, 0.6), ("Daniel", 7, 0.5)],
    # Two voices with three overlapping stretches (1.0-2.0 s each).
    "c2_2spk_overlap": [("Samantha", 0, 0.5), ("Daniel", 1, -1.2), ("Samantha", 2, 0.5),
                         ("Daniel", 3, -1.5), ("Samantha", 4, 0.6), ("Daniel", 5, -2.0),
                         ("Samantha", 6, 0.5), ("Daniel", 7, 0.5)],
    # Three voices, clean turns.
    "c3_3spk_turns": [("Samantha", 8, 0.5), ("Daniel", 9, 0.5), ("Karen", 10, 0.5),
                       ("Samantha", 11, 0.6), ("Daniel", 12, 0.4), ("Karen", 13, 0.5),
                       ("Daniel", 14, 0.5), ("Samantha", 15, 0.6), ("Karen", 16, 0.5)],
    # Three voices with overlaps, including a stretch where one speaker
    # cuts in while another is mid-sentence.
    "c4_3spk_overlap": [("Samantha", 8, 0.5), ("Daniel", 9, -1.0), ("Karen", 10, 0.4),
                         ("Samantha", 11, -1.6), ("Daniel", 12, 0.5), ("Karen", 13, -1.2),
                         ("Daniel", 14, 0.5), ("Samantha", 15, -1.0), ("Karen", 16, 0.5)],
    # Two similar voices (both female), turns plus one overlap: the hard case.
    "c5_2spk_similar": [("Samantha", 17, 0.5), ("Karen", 18, 0.5), ("Samantha", 19, 0.5),
                         ("Karen", 20, -1.0), ("Samantha", 21, 0.5), ("Karen", 0, 0.5),
                         ("Samantha", 3, 0.5), ("Karen", 6, 0.5)],
    # Two male voices, short back-and-forth.
    "c6_2spk_male": [("Daniel", 11, 0.4), ("Ralph", 12, 0.4), ("Daniel", 13, 0.4),
                      ("Ralph", 14, -0.8), ("Daniel", 15, 0.4), ("Ralph", 16, 0.4),
                      ("Daniel", 17, 0.4), ("Ralph", 18, 0.4)],
}

VOICES_LONG = ["Samantha", "Daniel", "Karen", "Ralph"]


def render(voice, text, tmpdir, cache):
    key = (voice, text)
    if key in cache:
        return cache[key]
    path = os.path.join(tmpdir, f"u{len(cache)}.wav")
    subprocess.run(["say", "-v", voice, "--file-format=WAVE",
                    f"--data-format=LEI16@{SR}", "-o", path, text], check=True)
    with wave.open(path) as w:
        assert w.getframerate() == SR and w.getnchannels() == 1, (voice, w.getparams())
        x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
    # Trim leading/trailing silence: 10 ms frames, -40 dBFS threshold.
    f = 160
    n = len(x) // f
    rms = np.sqrt(np.mean(x[: n * f].reshape(n, f) ** 2, axis=1) + 1e-12)
    active = np.where(20 * np.log10(rms) > -40)[0]
    x = x[active[0] * f:(active[-1] + 1) * f] if len(active) else x
    cache[key] = x
    return x


def build(name, plan, tmpdir, cache, rng):
    pieces = []
    t = 0.0
    prev_end = 0.0
    for voice, si, gap in plan:
        x = render(voice, SENTENCES[si % len(SENTENCES)], tmpdir, cache)
        start = max(0.0, prev_end + gap)
        pieces.append((voice, start, x))
        prev_end = start + len(x) / SR
        t = max(t, prev_end)
    total = int((t + 0.8) * SR)
    mix = np.zeros(total, dtype=np.float32)
    segs = []
    for voice, start, x in pieces:
        s = int(round(start * SR))
        mix[s:s + len(x)] += 0.6 * x
        segs.append({"speaker": voice, "start": round(s / SR, 3),
                     "end": round((s + len(x)) / SR, 3)})
    mix += rng.normal(0, 10 ** (-55 / 20), total).astype(np.float32)  # -55 dBFS noise floor
    mix = np.clip(mix, -1, 1)
    pcm = (mix * 32767).astype(np.int16)
    wav = os.path.join(DATA, name + ".wav")
    with wave.open(wav, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    with open(os.path.join(DATA, name + ".rttm"), "w") as fh:
        for g in segs:
            fh.write(f"SPEAKER {name} 1 {g['start']:.3f} {g['end'] - g['start']:.3f} "
                     f"<NA> <NA> {g['speaker']} <NA> <NA>\n")
    ovl = overlap_seconds(segs)
    meta = {"clip": name, "duration": round(total / SR, 3),
            "speakers": sorted({g["speaker"] for g in segs}),
            "overlap_seconds": round(ovl, 3), "segments": segs}
    with open(os.path.join(DATA, name + ".json"), "w") as fh:
        json.dump(meta, fh, indent=1)
    return meta


def overlap_seconds(segs):
    step = 0.01
    end = max(g["end"] for g in segs)
    n = int(end / step) + 1
    cnt = np.zeros(n, dtype=np.int32)
    for g in segs:
        cnt[int(g["start"] / step):int(g["end"] / step)] += 1
    return float(np.sum(cnt >= 2) * step)


def long_plan(minutes, rng):
    """A ~N-minute 4-speaker meeting for real-time-factor runs (~10% overlap turns)."""
    plan = []
    dur = 0.0
    i = 0
    while dur < minutes * 60:
        v = VOICES_LONG[i % 4] if rng.random() < 0.6 else VOICES_LONG[rng.integers(0, 4)]
        if plan and v == plan[-1][0]:
            v = VOICES_LONG[(VOICES_LONG.index(v) + 1) % 4]
        gap = -float(rng.uniform(0.5, 1.5)) if rng.random() < 0.12 else float(rng.uniform(0.3, 0.9))
        plan.append((v, int(rng.integers(0, len(SENTENCES))), gap))
        dur += 3.6 + gap  # rough average utterance length
        i += 1
    return plan


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--long-minutes", type=float, default=10.0)
    args = ap.parse_args()
    os.makedirs(DATA, exist_ok=True)
    rng = np.random.default_rng(44)
    cache = {}
    manifest = []
    with tempfile.TemporaryDirectory() as tmpdir:
        for name, plan in CLIPS.items():
            manifest.append(build(name, plan, tmpdir, cache, rng))
        if args.long_minutes > 0:
            manifest.append(build("l1_4spk_long", long_plan(args.long_minutes, rng), tmpdir, cache, rng))
    with open(os.path.join(DATA, "manifest.json"), "w") as fh:
        json.dump([{k: m[k] for k in ("clip", "duration", "speakers", "overlap_seconds")}
                   for m in manifest], fh, indent=1)
    for m in manifest:
        print(f"{m['clip']:18s} {m['duration']:7.1f}s spk={len(m['speakers'])} "
              f"ovl={m['overlap_seconds']:.1f}s segs={len(m['segments'])}")


if __name__ == "__main__":
    sys.exit(main())
