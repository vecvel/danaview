"""Summarise build/results/<label>.jsonl (aggregates only) into Markdown tables for REPORT.md.
usage: python3 -I summarize.py build/results/<label>.jsonl
"""
import json, sys, statistics as st
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
by = lambda t: [r for r in rows if r["type"] == t]
f1 = lambda v: "-" if v is None else f"{v:.1f}"
f2 = lambda v: "-" if v is None else f"{v:.2f}"
f3 = lambda v: "-" if v is None else f"{v:.3f}"
med = lambda xs: st.median(xs) if xs else None
for e in by("env"): print("env:", e)
for e in by("init"): print("init:", e["cand"], f"{e['ms']:.0f} ms")
for e in by("error"): print("ERROR:", e["error"][:1500])
stills = by("still")
if stills:
    print("\n### Stills: latency (median over fixtures of the per-fixture median, ms)\n")
    print("| Runtime | Frame | Face (478) | Pose (33) | Person+hair seg | MP selfie_segmenter | MP hair_segmenter |")
    print("|---|---|---|---|---|---|---|")
    for res in sorted({r["res"] for r in stills}):
        for c in dict.fromkeys(r["cand"] for r in stills):
            rs = [r for r in stills if r["res"] == res and r["cand"] == c]
            ex = lambda k: med([r["extras_ms"][k] for r in rs if k in r["extras_ms"]])
            print(f"| {c} | {res}p | {f1(med([r['face_ms'] for r in rs]))} | {f1(med([r['pose_ms'] for r in rs]))} | "
                  f"{f1(med([r['seg_ms'] for r in rs]))} | {f1(ex('selfie_segmenter'))} | {f1(ex('hair_segmenter'))} |")
    print("\n### Stills: faces / poses found (1080p)\n")
    cands = list(dict.fromkeys(r["cand"] for r in stills))
    print("| Fixture | " + " | ".join(f"{c} faces/poses" for c in cands) + " |")
    print("|---|" + "---|" * len(cands))
    res = max(r["res"] for r in stills)
    for fx in sorted({r["fixture"] for r in stills}):
        cells = []
        for c in cands:
            r = [x for x in stills if x["fixture"] == fx and x["cand"] == c and x["res"] == res]
            cells.append(f"{r[0]['faces']} / {r[0]['poses']}" if r else "-")
        print(f"| {fx} | " + " | ".join(cells) + " |")
ps = by("parity_still")
if ps:
    print("\n### Stills: parity per runtime pair (A~B)\n")
    print("| Pair | Frame | Faces matched (only A / only B) | Face mean px (worst fixture) | Face NME | Worst point px | Pose matched (only A / B) | Pose mean px | IoU person | IoU hair (min) |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for res in sorted({r["res"] for r in ps}):
        for pair in dict.fromkeys(r["pair"] for r in ps):
            rs = [r for r in ps if r["res"] == res and r["pair"] == pair]
            fm = sum(r["face"]["matched"] for r in rs)
            w = [(r["face"]["meanPx"], r["face"]["matched"]) for r in rs if r["face"]["meanPx"] is not None]
            fmean = sum(a * b for a, b in w) / max(1, sum(b for _, b in w)) if w else None
            fworst = max((a for a, _ in w), default=None)
            nme = [r["face"]["nme"] for r in rs if r["face"]["nme"] is not None]
            pts = max((r["face"]["maxPointPx"] for r in rs), default=None)
            pm = sum(r["pose"]["matched"] for r in rs)
            pmean = [r["pose"]["meanPx"] for r in rs if r["pose"]["meanPx"] is not None]
            iop = [r["seg"]["iouPerson"] for r in rs]; ioh = [r["seg"]["iouHair"] for r in rs]
            print(f"| {pair} | {res}p | {fm} ({sum(r['face']['onlyA'] for r in rs)} / {sum(r['face']['onlyB'] for r in rs)}) | "
                  f"{f2(fmean)} ({f2(fworst)}) | {f3(st.mean(nme) if nme else None)} | {f1(pts)} | "
                  f"{pm} ({sum(r['pose']['onlyA'] for r in rs)} / {sum(r['pose']['onlyB'] for r in rs)}) | {f2(st.mean(pmean) if pmean else None)} | "
                  f"{f3(st.mean(iop))} | {f3(st.mean(ioh))} ({f3(min(ioh))}) |")
    print("\nPer fixture (1080p), face mean px / pose mean px / IoU hair:\n")
    res = max(r["res"] for r in ps)
    pairs = list(dict.fromkeys(r["pair"] for r in ps))
    print("| Fixture | " + " | ".join(pairs) + " |"); print("|---|" + "---|" * len(pairs))
    for fx in sorted({r["fixture"] for r in ps}):
        cells = []
        for p in pairs:
            r = [x for x in ps if x["fixture"] == fx and x["pair"] == p and x["res"] == res][0]
            cells.append(f"{f2(r['face']['meanPx'])} ({r['face']['matched']}/{r['face']['onlyA']}/{r['face']['onlyB']}) / {f1(r['pose']['meanPx'])} / {f3(r['seg']['iouHair'])}")
        print(f"| {fx} | " + " | ".join(cells) + " |")
cl = by("clip")
if cl:
    print("\n### Clips (video / tracking mode): per-frame latency median / p90 ms\n")
    print("| Clip | Frame | Runtime | Frames | Frames with a face | Face | Pose | Seg (every 5th frame) |")
    print("|---|---|---|---|---|---|---|---|")
    for r in cl:
        s = lambda k: f"{f1(r[k]['median'])} / {f1(r[k]['p90'])}"
        print(f"| {r['fixture']} | {r['res']}p | {r['cand']} | {r['frames']} | {r['framesWithFace']} | {s('face_ms')} | {s('pose_ms')} | {s('seg_ms')} |")
pc = by("parity_clip")
if pc:
    print("\n### Clips: parity per runtime pair\n")
    print("| Clip | Frame | Pair | Face-frames matched (only A / B) | Face mean px | p90 px | NME | Pose mean px | IoU person | IoU hair |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for r in pc:
        f, p, s = r["face"], r["pose"], r["seg"]
        print(f"| {r['fixture']} | {r['res']}p | {r['pair']} | {f['matched']} ({f['onlyA']} / {f['onlyB']}) | {f2(f['meanPx'])} | {f2(f['p90Px'])} | {f3(f['nme'])} | {f2(p['meanPx'])} | {f3(s['iouPerson'])} | {f3(s['iouHair'])} |")
for e in by("end"): print("\nend:", e)
