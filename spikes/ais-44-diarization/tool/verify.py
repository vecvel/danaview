#!/usr/bin/env python3
"""AIS-44 spike: same/different-speaker cosine statistics from bin/embed.dart output.

Reports mean cosine for same-speaker and different-speaker pairs, the margin
between the lowest same-speaker and highest different-speaker score, and an
equal-error-rate estimate. Also clusters the embeddings with oracle count
(average-linkage agglomerative on cosine distance, the method sherpa-onnx's
FastClustering uses) and reports cluster purity.

Usage: python3 tool/verify.py results/emb.<model>.json ...
"""
import json
import os
import sys

import numpy as np


def eer(same, diff):
    ths = np.sort(np.concatenate([same, diff]))
    best = (1.0, 0)
    for t in ths:
        frr = np.mean(same < t)
        far = np.mean(diff >= t)
        if abs(frr - far) < best[0]:
            best = (abs(frr - far), (frr + far) / 2)
    return best[1]


def agglomerate(X, k):
    clusters = [[i] for i in range(len(X))]
    S = X @ X.T
    while len(clusters) > k:
        best, bi, bj = -9, 0, 1
        for i in range(len(clusters)):
            for j in range(i + 1, len(clusters)):
                s = S[np.ix_(clusters[i], clusters[j])].mean()
                if s > best:
                    best, bi, bj = s, i, j
        clusters[bi] += clusters.pop(bj)
    return clusters


def main(paths):
    for p in paths:
        rows = json.load(open(p))
        X = np.array([r["emb"] for r in rows], dtype=np.float64)
        X /= np.linalg.norm(X, axis=1, keepdims=True)
        spk = [r["speaker"] for r in rows]
        clip = [r["clip"] for r in rows]
        S = X @ X.T
        same, diff = [], []
        for i in range(len(rows)):
            for j in range(i + 1, len(rows)):
                (same if spk[i] == spk[j] else diff).append(S[i, j])
        same, diff = np.array(same), np.array(diff)
        # Per-clip oracle clustering purity.
        correct = total = 0
        for c in sorted(set(clip)):
            idx = [i for i in range(len(rows)) if clip[i] == c]
            k = len({spk[i] for i in idx})
            for cl in agglomerate(X[idx], k):
                labels = [spk[idx[i]] for i in cl]
                correct += max(labels.count(l) for l in set(labels))
                total += len(labels)
        print(f"{os.path.basename(p):60s} n={len(rows)} same={same.mean():.3f} diff={diff.mean():.3f} "
              f"min_same={same.min():.3f} max_diff={diff.max():.3f} EER={eer(same, diff)*100:.1f}% "
              f"oracle-cluster purity={correct/total*100:.1f}%")


if __name__ == "__main__":
    main(sys.argv[1:])
