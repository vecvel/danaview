#!/usr/bin/env python3
"""Minimal pure-Python TrueType outliner (no fontTools).

Reads head, hhea, maxp, OS/2, cmap (formats 4 and 12), hmtx, loca and glyf (simple and
composite glyphs), plus pair kerning from GPOS (lookup type 2, formats 1 and 2, also behind
extension lookups) for the 'kern' feature. Turns text into one SVG path of absolute,
already-scaled coordinates (y down), so the result needs no font at render time.

    from ttf_outline import Font
    f = Font("packages/danaview_ui_kit/fonts/Figtree-Bold.ttf")
    run = f.layout("Danaview", size=64, tracking=-0.01)   # tracking in em
    d = run.path(x=0, baseline=64)                         # SVG path data
    run.ink                                               # (xMin, yMin, xMax, yMax) in px, y up

Only static TrueType fonts with a glyf table are supported (no CFF, no variations).
"""
import struct


class Font:
    def __init__(self, path):
        with open(path, "rb") as fh:
            self.data = d = fh.read()
        n = struct.unpack_from(">H", d, 4)[0]
        self.tables = {}
        for i in range(n):
            tag, _, off, ln = struct.unpack_from(">4sIII", d, 12 + 16 * i)
            self.tables[tag.decode("latin-1")] = (off, ln)
        h = self.tables["head"][0]
        self.upm = struct.unpack_from(">H", d, h + 18)[0]
        self.loca_long = struct.unpack_from(">h", d, h + 50)[0] == 1
        self.num_glyphs = struct.unpack_from(">H", d, self.tables["maxp"][0] + 4)[0]
        hh = self.tables["hhea"][0]
        self.ascender, self.descender, self.line_gap = struct.unpack_from(">hhh", d, hh + 4)
        self.num_hmetrics = struct.unpack_from(">H", d, hh + 34)[0]
        os2 = self.tables.get("OS/2")
        self.cap_height = self.x_height = None
        if os2:
            ver = struct.unpack_from(">H", d, os2[0])[0]
            if ver >= 2:
                self.x_height, self.cap_height = struct.unpack_from(">hh", d, os2[0] + 86)
        self._read_hmtx()
        self._read_loca()
        self.cmap = self._read_cmap()
        self.kerning = self._read_gpos_kerning()
        self._glyph_cache = {}

    # ------------------------------------------------------------ tables
    def _read_hmtx(self):
        d, off = self.data, self.tables["hmtx"][0]
        self.advances, self.lsbs = [], []
        for i in range(self.num_hmetrics):
            a, l = struct.unpack_from(">Hh", d, off + 4 * i)
            self.advances.append(a); self.lsbs.append(l)
        last = self.advances[-1]
        base = off + 4 * self.num_hmetrics
        for i in range(self.num_glyphs - self.num_hmetrics):
            self.advances.append(last)
            self.lsbs.append(struct.unpack_from(">h", self.data, base + 2 * i)[0])

    def _read_loca(self):
        d, off = self.data, self.tables["loca"][0]
        n = self.num_glyphs + 1
        if self.loca_long:
            self.loca = list(struct.unpack_from(f">{n}I", d, off))
        else:
            self.loca = [v * 2 for v in struct.unpack_from(f">{n}H", d, off)]

    def _read_cmap(self):
        d, off = self.data, self.tables["cmap"][0]
        n = struct.unpack_from(">H", d, off + 2)[0]
        best = None
        for i in range(n):
            pid, eid, sub = struct.unpack_from(">HHI", d, off + 4 + 8 * i)
            fmt = struct.unpack_from(">H", d, off + sub)[0]
            rank = {(3, 10): 0, (0, 4): 1, (3, 1): 2, (0, 3): 3}.get((pid, eid), 9)
            if fmt in (4, 12) and (best is None or rank < best[0]):
                best = (rank, off + sub, fmt)
        if best is None:
            raise ValueError("no usable cmap subtable (format 4 or 12)")
        _, s, fmt = best
        m = {}
        if fmt == 4:
            segx2 = struct.unpack_from(">H", d, s + 6)[0]
            seg = segx2 // 2
            ends = struct.unpack_from(f">{seg}H", d, s + 14)
            starts = struct.unpack_from(f">{seg}H", d, s + 16 + segx2)
            deltas = struct.unpack_from(f">{seg}h", d, s + 16 + 2 * segx2)
            ro_off = s + 16 + 3 * segx2
            ranges = struct.unpack_from(f">{seg}H", d, ro_off)
            for i in range(seg):
                for c in range(starts[i], ends[i] + 1):
                    if c == 0xFFFF:
                        continue
                    if ranges[i] == 0:
                        g = (c + deltas[i]) & 0xFFFF
                    else:
                        p = ro_off + 2 * i + ranges[i] + 2 * (c - starts[i])
                        g = struct.unpack_from(">H", d, p)[0]
                        if g:
                            g = (g + deltas[i]) & 0xFFFF
                    if g:
                        m[c] = g
        else:
            ngroups = struct.unpack_from(">I", d, s + 12)[0]
            for i in range(ngroups):
                a, b, g0 = struct.unpack_from(">III", d, s + 16 + 12 * i)
                for c in range(a, b + 1):
                    m[c] = g0 + (c - a)
        return m

    # ------------------------------------------------------------ GPOS kerning
    def _coverage(self, off):
        d = self.data
        fmt = struct.unpack_from(">H", d, off)[0]
        if fmt == 1:
            n = struct.unpack_from(">H", d, off + 2)[0]
            return {g: i for i, g in enumerate(struct.unpack_from(f">{n}H", d, off + 4))}
        n = struct.unpack_from(">H", d, off + 2)[0]
        cov = {}
        for i in range(n):
            a, b, idx = struct.unpack_from(">HHH", d, off + 4 + 6 * i)
            for g in range(a, b + 1):
                cov[g] = idx + g - a
        return cov

    def _class_def(self, off):
        d = self.data
        fmt = struct.unpack_from(">H", d, off)[0]
        cls = {}
        if fmt == 1:
            start, n = struct.unpack_from(">HH", d, off + 2)
            for i, c in enumerate(struct.unpack_from(f">{n}H", d, off + 6)):
                cls[start + i] = c
        else:
            n = struct.unpack_from(">H", d, off + 2)[0]
            for i in range(n):
                a, b, c = struct.unpack_from(">HHH", d, off + 4 + 6 * i)
                for g in range(a, b + 1):
                    cls[g] = c
        return cls

    @staticmethod
    def _vr_size(fmt):
        return 2 * bin(fmt & 0xFF).count("1")

    def _x_advance(self, off, fmt):
        """XAdvance from a ValueRecord at off (0 when absent)."""
        if not fmt & 0x0004:
            return 0
        skip = 2 * bin(fmt & 0x0003).count("1")
        return struct.unpack_from(">h", self.data, off + skip)[0]

    def _read_gpos_kerning(self):
        """{(left, right): x advance adjustment} for the 'kern' feature; first match wins."""
        if "GPOS" not in self.tables:
            return {}
        d, g = self.data, self.tables["GPOS"][0]
        _, _, script_off, feat_off, lookup_off = struct.unpack_from(">HHHHH", d, g)
        fl = g + feat_off
        nfeat = struct.unpack_from(">H", d, fl)[0]
        lookups = []
        for i in range(nfeat):
            tag, foff = struct.unpack_from(">4sH", d, fl + 2 + 6 * i)
            if tag != b"kern":
                continue
            f = fl + foff
            n = struct.unpack_from(">H", d, f + 2)[0]
            for li in struct.unpack_from(f">{n}H", d, f + 4):
                if li not in lookups:
                    lookups.append(li)
        ll = g + lookup_off
        pairs = {}
        for li in sorted(lookups):
            lo = ll + struct.unpack_from(">H", d, ll + 2 + 2 * li)[0]
            ltype, _, nsub = struct.unpack_from(">HHH", d, lo)
            for si in range(nsub):
                st = lo + struct.unpack_from(">H", d, lo + 6 + 2 * si)[0]
                t = ltype
                if t == 9:  # extension
                    t, ext = struct.unpack_from(">HI", d, st + 2)
                    st = st + ext
                if t != 2:
                    continue
                self._read_pair_pos(st, pairs)
        return pairs

    def _read_pair_pos(self, st, pairs):
        d = self.data
        fmt, cov_off, vf1, vf2 = struct.unpack_from(">HHHH", d, st)
        cov = self._coverage(st + cov_off)
        s1, s2 = self._vr_size(vf1), self._vr_size(vf2)
        if fmt == 1:
            n = struct.unpack_from(">H", d, st + 8)[0]
            set_offs = struct.unpack_from(f">{n}H", d, st + 10)
            for g1, idx in cov.items():
                ps = st + set_offs[idx]
                cnt = struct.unpack_from(">H", d, ps)[0]
                rec = 2 + s1 + s2
                for k in range(cnt):
                    r = ps + 2 + k * rec
                    g2 = struct.unpack_from(">H", d, r)[0]
                    v = self._x_advance(r + 2, vf1)
                    if v and (g1, g2) not in pairs:
                        pairs[(g1, g2)] = v
        elif fmt == 2:
            cd1_off, cd2_off, n1, n2 = struct.unpack_from(">HHHH", d, st + 8)
            cd1, cd2 = self._class_def(st + cd1_off), self._class_def(st + cd2_off)
            rec = s1 + s2
            base = st + 16
            by2 = {}
            for g, c in cd2.items():
                by2.setdefault(c, []).append(g)
            all2 = set(range(self.num_glyphs))
            by2[0] = sorted(all2 - set(cd2))
            for g1 in cov:
                c1 = cd1.get(g1, 0)
                for c2 in range(n2):
                    v = self._x_advance(base + (c1 * n2 + c2) * rec, vf1)
                    if not v:
                        continue
                    for g2 in by2.get(c2, ()):
                        if (g1, g2) not in pairs:
                            pairs[(g1, g2)] = v

    # ------------------------------------------------------------ glyphs
    def glyph_id(self, ch):
        return self.cmap.get(ord(ch), 0)

    def contours(self, gid):
        """List of contours; each is a list of (x, y, on_curve) in font units (y up)."""
        if gid in self._glyph_cache:
            return self._glyph_cache[gid]
        d = self.data
        start, end = self.loca[gid], self.loca[gid + 1]
        out = []
        if end > start:
            g = self.tables["glyf"][0] + start
            nc = struct.unpack_from(">h", d, g)[0]
            out = self._simple(g, nc) if nc >= 0 else self._composite(g)
        self._glyph_cache[gid] = out
        return out

    def glyph_bbox(self, gid):
        d = self.data
        if self.loca[gid + 1] <= self.loca[gid]:
            return None
        g = self.tables["glyf"][0] + self.loca[gid]
        return struct.unpack_from(">hhhh", d, g + 2)

    def _simple(self, g, nc):
        d = self.data
        ends = struct.unpack_from(f">{nc}H", d, g + 10)
        npts = ends[-1] + 1 if nc else 0
        ilen = struct.unpack_from(">H", d, g + 10 + 2 * nc)[0]
        p = g + 12 + 2 * nc + ilen
        flags = []
        while len(flags) < npts:
            f = d[p]; p += 1
            flags.append(f)
            if f & 8:
                r = d[p]; p += 1
                flags.extend([f] * r)
        flags = flags[:npts]

        def coords(short_bit, same_bit):
            nonlocal p
            vals, v = [], 0
            for f in flags:
                if f & short_bit:
                    dv = d[p]; p += 1
                    v += dv if f & same_bit else -dv
                elif not f & same_bit:
                    v += struct.unpack_from(">h", d, p)[0]; p += 2
                vals.append(v)
            return vals

        xs = coords(0x02, 0x10)
        ys = coords(0x04, 0x20)
        out, s = [], 0
        for e in ends:
            out.append([(xs[i], ys[i], bool(flags[i] & 1)) for i in range(s, e + 1)])
            s = e + 1
        return out

    def _composite(self, g):
        d = self.data
        p = g + 10
        out = []
        while True:
            flags, gi = struct.unpack_from(">HH", d, p); p += 4
            if flags & 0x0001:
                a1, a2 = struct.unpack_from(">hh", d, p); p += 4
            else:
                a1, a2 = struct.unpack_from(">bb", d, p); p += 2
            if not flags & 0x0002:
                raise ValueError("point-matched composite components are not supported")
            xx, xy, yx, yy = 1.0, 0.0, 0.0, 1.0
            if flags & 0x0008:
                xx = yy = struct.unpack_from(">h", d, p)[0] / 16384; p += 2
            elif flags & 0x0040:
                xx, yy = (v / 16384 for v in struct.unpack_from(">hh", d, p)); p += 4
            elif flags & 0x0080:
                xx, xy, yx, yy = (v / 16384 for v in struct.unpack_from(">hhhh", d, p)); p += 8
            for c in self.contours(gi):
                out.append([(x * xx + y * yx + a1, x * xy + y * yy + a2, on) for x, y, on in c])
            if not flags & 0x0020:
                break
        return out

    # ------------------------------------------------------------ layout
    def layout(self, text, size, tracking=0.0, kerning=True):
        return Run(self, text, size, tracking, kerning)


def _fmt(v):
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def contour_to_svg(contour, tx):
    """One TrueType contour (quadratic, implied on-curve midpoints) as SVG path data."""
    n = len(contour)
    if n == 0:
        return ""
    pts = [(x, y, on) for x, y, on in contour]
    # start on an on-curve point (or the midpoint of the first two off-curve points)
    si = next((i for i, p in enumerate(pts) if p[2]), None)
    if si is None:
        a, b = pts[0], pts[1]
        start = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
        seq = pts
    else:
        start = pts[si][:2]
        seq = pts[si + 1:] + pts[:si]
    out = [f"M{_fmt(tx(*start)[0])} {_fmt(tx(*start)[1])}"]
    ctrl = None
    for x, y, on in seq + [(start[0], start[1], True)]:
        if on:
            X, Y = tx(x, y)
            if ctrl is None:
                out.append(f"L{_fmt(X)} {_fmt(Y)}")
            else:
                cx, cy = tx(*ctrl)
                out.append(f"Q{_fmt(cx)} {_fmt(cy)} {_fmt(X)} {_fmt(Y)}")
                ctrl = None
        else:
            if ctrl is not None:
                mx, my = (ctrl[0] + x) / 2, (ctrl[1] + y) / 2
                cx, cy = tx(*ctrl); MX, MY = tx(mx, my)
                out.append(f"Q{_fmt(cx)} {_fmt(cy)} {_fmt(MX)} {_fmt(MY)}")
            ctrl = (x, y)
    out.append("Z")
    return "".join(out)


class Run:
    """Text laid out on one line: glyph ids, pen positions (font units) and ink bounds."""

    def __init__(self, font, text, size, tracking, kerning):
        self.font, self.text, self.size = font, text, size
        self.scale = size / font.upm
        track = tracking * font.upm
        self.glyphs, self.pens = [], []
        pen = 0.0
        gids = [font.glyph_id(c) for c in text]
        for i, gid in enumerate(gids):
            self.glyphs.append(gid)
            self.pens.append(pen)
            pen += font.advances[gid]
            if i + 1 < len(gids):
                if kerning:
                    pen += font.kerning.get((gid, gids[i + 1]), 0)
                pen += track
        self.advance_units = pen
        xmin = ymin = float("inf"); xmax = ymax = float("-inf")
        for gid, px in zip(self.glyphs, self.pens):
            bb = font.glyph_bbox(gid)
            if bb:
                xmin = min(xmin, px + bb[0]); ymin = min(ymin, bb[1])
                xmax = max(xmax, px + bb[2]); ymax = max(ymax, bb[3])
        k = self.scale
        self.ink = (xmin * k, ymin * k, xmax * k, ymax * k)  # px, y up from baseline

    @property
    def advance(self):
        return self.advance_units * self.scale

    @property
    def ink_width(self):
        return self.ink[2] - self.ink[0]

    def path(self, x, baseline, ink_left=False):
        """SVG path data with the pen origin at x (or the ink's left edge at x) on the baseline."""
        k = self.scale
        x0 = x - self.ink[0] if ink_left else x
        parts = []
        for gid, px in zip(self.glyphs, self.pens):
            tx = lambda fx, fy, px=px: (x0 + (px + fx) * k, baseline - fy * k)
            for c in self.font.contours(gid):
                parts.append(contour_to_svg(c, tx))
        return "".join(parts)


if __name__ == "__main__":
    import sys
    f = Font(sys.argv[1])
    text = sys.argv[2] if len(sys.argv) > 2 else "Danaview"
    r = f.layout(text, 100)
    print(f"upm {f.upm} cap {f.cap_height} x {f.x_height} glyphs {f.num_glyphs} kern pairs {len(f.kerning)}")
    print("advance", round(r.advance, 2), "ink", [round(v, 2) for v in r.ink])
    for a, b in zip(r.glyphs, r.glyphs[1:]):
        print(a, b, f.kerning.get((a, b), 0))
