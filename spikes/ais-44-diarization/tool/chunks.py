#!/usr/bin/env python3
"""AIS-44 spike: chunk-level clustering experiment (a candidate for AIS-46).

sherpa-onnx clusters one embedding per (10 s window, pyannote local speaker).
When pyannote puts two similar voices into one local speaker, no embedding
model can split them. This experiment keeps sherpa-onnx's speech and overlap
activity but re-labels speakers from fixed 1.5 s chunk embeddings:

  1. cluster chunk embeddings per clip (average-linkage, cosine; oracle k or threshold)
  2. each 10 ms frame takes the vote of the chunks covering it
  3. where sherpa-onnx reports >= 2 active speakers, the frame gets the top-2
     clusters voted within +-1 s (overlap kept, V-S18)

Usage: python3 tool/chunks.py <emb chunks json> <diarize json> [--k oracle|<threshold>]
"""
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score import DATA, STEP, score  # noqa: E402


def agglomerate(X, k=None, th=None):
    clusters = [[i] for i in range(len(X))]
    S = X @ X.T
    while len(clusters) > 1:
        best, bi, bj = -9, 0, 1
        for i in range(len(clusters)):
            for j in range(i + 1, len(clusters)):
                s = S[np.ix_(clusters[i], clusters[j])].mean()
                if s > best:
                    best, bi, bj = s, i, j
        if k is not None and len(clusters) <= k:
            break
        if th is not None and 1 - best > th:
            break
        clusters[bi] += clusters.pop(bj)
    lab = np.zeros(len(X), dtype=int)
    for c, members in enumerate(clusters):
        lab[members] = c
    return lab


def frames_to_segs(active, step):
    segs = []
    for spk, row in active.items():
        d = np.diff(np.concatenate([[0], row.astype(int), [0]]))
        for a, b in zip(np.where(d == 1)[0], np.where(d == -1)[0]):
            segs.append({"speaker": f"C{spk}", "start": a * step, "end": b * step})
    return segs


def main(argv):
    chunks = json.load(open(argv[0]))
    dia = {r["clip"]: r for r in json.load(open(argv[1]))["results"]}
    mode = argv[argv.index("--k") + 1] if "--k" in argv else "oracle"
    ders = []
    for clip in sorted({c["clip"] for c in chunks}):
        ref = json.load(open(os.path.join(DATA, clip + ".json")))
        rows = [c for c in chunks if c["clip"] == clip]
        X = np.array([r["emb"] for r in rows], dtype=np.float64)
        X /= np.linalg.norm(X, axis=1, keepdims=True)
        lab = agglomerate(X, k=len(ref["speakers"])) if mode == "oracle" else agglomerate(X, th=float(mode))
        nk = lab.max() + 1
        n = int(np.ceil(ref["duration"] / STEP)) + 1
        votes = np.zeros((nk, n))
        for r, l in zip(rows, lab):
            votes[l, int(r["start"] / STEP):int(r["end"] / STEP)] += 1
        # sherpa-onnx activity: speech mask and active-speaker count per frame
        cnt = np.zeros(n, dtype=int)
        for s in dia[clip]["segments"]:
            cnt[int(s["start"] / STEP):int(s["end"] / STEP)] += 1
        active = {k: np.zeros(n, dtype=bool) for k in range(nk)}
        w = int(1.0 / STEP)
        cs = np.cumsum(np.pad(votes, ((0, 0), (1, 0))), axis=1)
        for t in np.where(cnt >= 1)[0]:
            if cnt[t] >= 2 and nk >= 2:
                a, b = max(0, t - w), min(n, t + w)
                near = cs[:, b] - cs[:, a]
                for k in np.argsort(-near)[:2]:
                    active[k][t] = True
            elif votes[:, t].sum() > 0:
                active[int(np.argmax(votes[:, t]))][t] = True
            else:
                a, b = max(0, t - w), min(n, t + w)
                active[int(np.argmax(cs[:, b] - cs[:, a]))][t] = True
        segs = frames_to_segs(active, STEP)
        s0 = score(ref["segments"], segs, ref["duration"])
        s1 = score(ref["segments"], segs, ref["duration"], 0.25)
        ders.append((s0, s1))
        print(f"{clip:16s} DER={s0['der']*100:5.1f}% (collar {s1['der']*100:5.1f}%) conf={s0['conf']*100:4.1f} "
              f"spk={s0['hyp_spk']}/{s0['ref_spk']} ovlR={s0['ovl_recall']*100:3.0f}% ovlBoth={s0['ovl_both']*100:3.0f}%")
    print(f"mean DER={np.mean([d[0]['der'] for d in ders])*100:.1f}% "
          f"(collar {np.mean([d[1]['der'] for d in ders])*100:.1f}%), right count "
          f"{sum(d[0]['hyp_spk'] == d[0]['ref_spk'] for d in ders)}/{len(ders)}")


if __name__ == "__main__":
    main(sys.argv[1:])
