#!/usr/bin/env python3
"""AIS-44 spike: aggregate the grid in results/ into one table (markdown).

Per run configuration: mean DER (no collar / 0.25 s collar) over the six short
clips, clips with the right speaker count, overlap recall and "both right" on
the overlap clips, mean RTF and peak RSS.
"""
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score import DATA, score  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    rss = {}
    p = os.path.join(ROOT, "results", "rss.txt")
    if os.path.exists(p):
        for line in open(p):
            t, v = line.split()
            rss[t] = int(v) / 1e6
    groups = {}
    for f in sorted(glob.glob(os.path.join(ROOT, "results", "*.json"))):
        name = os.path.basename(f)[:-5]
        if name.startswith("emb.") or name == "try" or name.startswith("rtf."):
            continue
        run = json.load(open(f))
        emb, seg, mode = name.rsplit(".", 2) if ".int8." not in name else (
            name.split(".model.int8.")[0], "int8", name.split(".model.int8.")[1])
        if seg == "model":
            seg = "fp32"
        key = (emb, seg, "oracle" if mode in ("k2", "k3") else mode)
        g = groups.setdefault(key, {"rows": [], "rss": []})
        g["rss"].append(rss.get(name, 0))
        for r in run["results"]:
            ref = json.load(open(os.path.join(DATA, r["clip"] + ".json")))
            g["rows"].append((r["clip"], score(ref["segments"], r["segments"], ref["duration"]),
                              score(ref["segments"], r["segments"], ref["duration"], 0.25), r["rtf"]))
    print("| embedding | seg | clustering | DER | DER (0.25 s collar) | right count | overlap recall | overlap both right | RTF (M2, 2 thr) | peak RSS MB |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for key in sorted(groups):
        rows = groups[key]["rows"]
        n = len(rows)
        der = sum(r[1]["der"] for r in rows) / n
        derc = sum(r[2]["der"] for r in rows) / n
        cnt = sum(r[1]["hyp_spk"] == r[1]["ref_spk"] for r in rows)
        ov = [r for r in rows if "overlap" in r[0] or "similar" in r[0] or "male" in r[0]]
        orc = sum(r[1]["ovl_recall"] for r in ov) / len(ov)
        ob = sum(r[1]["ovl_both"] for r in ov) / len(ov)
        rtf = sum(r[3] for r in rows) / n
        print(f"| {key[0]} | {key[1]} | {key[2]} | {der*100:.1f}% | {derc*100:.1f}% | {cnt}/{n} | "
              f"{orc*100:.0f}% | {ob*100:.0f}% | {rtf:.3f} | {max(groups[key]['rss']):.0f} |")


if __name__ == "__main__":
    main()
