#!/usr/bin/env python3
"""AIS-44 spike: score diarize.dart output against the generated ground truth.

Frame-level (10 ms) DER with overlap scored, optimal 1:1 speaker mapping,
reported with no collar and with a 0.25 s collar around reference boundaries.
Also reports speaker count and overlap handling (V-S18):
  ovl_recall  = share of reference overlap frames where the hypothesis has >= 2 speakers
  ovl_prec    = share of hypothesis overlap frames that are reference overlap
  ovl_both    = share of reference overlap frames where every active speaker is right

Usage: python3 tool/score.py results/run.json [more.json ...]  -> one line per clip + mean
"""
import itertools
import json
import os
import sys

import numpy as np

STEP = 0.01
DATA = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")


def matrix(segs, labels, n):
    m = np.zeros((len(labels), n), dtype=bool)
    for s in segs:
        a, b = int(round(s["start"] / STEP)), int(round(s["end"] / STEP))
        m[labels.index(s["speaker"]), max(0, a):min(n, b)] = True
    return m


def score(ref_segs, hyp_segs, duration, collar=0.0):
    n = int(np.ceil(duration / STEP)) + 1
    rl = sorted({s["speaker"] for s in ref_segs})
    hl = sorted({s["speaker"] for s in hyp_segs})
    R = matrix(ref_segs, rl, n)
    H = matrix(hyp_segs, hl, n) if hl else np.zeros((0, n), dtype=bool)
    keep = np.ones(n, dtype=bool)
    if collar > 0:
        c = int(round(collar / STEP))
        for s in ref_segs:
            for t in (s["start"], s["end"]):
                k = int(round(t / STEP))
                keep[max(0, k - c):k + c] = False
    R, H = R[:, keep], H[:, keep]
    # Optimal mapping hyp -> ref maximising co-active frames.
    ov = (R[:, None, :] & H[None, :, :]).sum(axis=2) if len(hl) else np.zeros((len(rl), 0))
    best, best_map = -1, ()
    k = max(len(rl), len(hl))
    for perm in itertools.permutations(range(k), len(rl)):
        tot = sum(ov[i, p] for i, p in enumerate(perm) if p < len(hl))
        if tot > best:
            best, best_map = tot, perm
    correct = np.zeros(R.shape[1], dtype=np.int32)
    for i, p in enumerate(best_map):
        if p < len(hl):
            correct += (R[i] & H[p])
    nr, nh = R.sum(0), H.sum(0)
    total = nr.sum()
    miss = np.maximum(0, nr - nh).sum()
    fa = np.maximum(0, nh - nr).sum()
    conf = (np.minimum(nr, nh) - correct).sum()
    ro, ho = nr >= 2, nh >= 2
    return {
        "der": (miss + fa + conf) / total, "miss": miss / total, "fa": fa / total, "conf": conf / total,
        "ref_spk": len(rl), "hyp_spk": len(hl),
        "ovl_recall": (ro & ho).sum() / max(1, ro.sum()),
        "ovl_prec": (ro & ho).sum() / max(1, ho.sum()),
        "ovl_both": (ro & (correct == nr)).sum() / max(1, ro.sum()),
    }


def main(paths):
    rows = []
    for p in paths:
        run = json.load(open(p))
        tag = f"{os.path.basename(run['emb'])[:22]} seg={os.path.basename(run['seg'])} " \
              f"k={run['clusters']} th={run['threshold']}"
        for r in run["results"]:
            ref = json.load(open(os.path.join(DATA, r["clip"] + ".json")))
            s0 = score(ref["segments"], r["segments"], ref["duration"], 0.0)
            s1 = score(ref["segments"], r["segments"], ref["duration"], 0.25)
            rows.append((tag, r["clip"], s0, s1, r["rtf"]))
            print(f"{tag} | {r['clip']:16s} DER={s0['der']*100:5.1f}% (collar {s1['der']*100:5.1f}%) "
                  f"miss={s0['miss']*100:4.1f} fa={s0['fa']*100:4.1f} conf={s0['conf']*100:4.1f} "
                  f"spk={s0['hyp_spk']}/{s0['ref_spk']} ovlR={s0['ovl_recall']*100:4.0f}% "
                  f"ovlP={s0['ovl_prec']*100:4.0f}% ovlBoth={s0['ovl_both']*100:4.0f}% RTF={r['rtf']:.3f}")
    return rows


if __name__ == "__main__":
    main(sys.argv[1:])
