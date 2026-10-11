#!/usr/bin/env python3
"""Rename the app "Vwish" to "Danaview" across the whole repository.

Deterministic and idempotent: a second run on a renamed tree changes nothing. Python 3.8+,
standard library only. Run from anywhere inside the repository (or pass --root).

    python3 tool/rename/rename_to_danaview.py --dry-run [--report FILE]
    python3 tool/rename/rename_to_danaview.py --apply
    python3 tool/rename/rename_to_danaview.py --regenerate
    python3 tool/rename/rename_to_danaview.py --verify [--allow-mac-pending]

Rules (case-preserving, applied in this order, to file contents and to file/folder names):

 1  brand         vwish/Vwish/VWISH -> danaview/Danaview/DANAVIEW anywhere, also inside words
                  (VwishColors, vwish_editor_core, com.vecvel.vwish, vwish://, "vwish/...").
 2  project type  vwproj/Vwproj/VWPROJ -> dnproj/Dnproj/DNPROJ anywhere (.vwproj, VwprojFormat).
 3  C/FFI prefix  vw_ -> dv_ at the start of a token or of a snake segment (vw_job, _vw_job_start,
                  fake_vw_bindings) and after "lib" (libvw_shim).
 4  macro prefix  VW_ -> DV_ in the same positions (VW_OK, TEST_RUNNER_VW_SECONDS) and after -D
                  (-DVW_SANITIZER -> -DDV_SANITIZER).
 5  namespace     the lone token vw before "::", "." + letter, or after "namespace "
                  (vw::, namespace vw, vw.spike.export, vw.cleanup.v1).
 6  camel prefix  Vw + [A-Z0-9] at token start or after a lowercase letter (VwStatus,
                  FakeVwBindings, VwT); vw/VW + [A-Z0-9] at token start (vwAbiVersion,
                  VWSpikeHost, VWPK, VWT_CMP); the lone token VW.
 7  tags          vwt, vwtest, vwspike, vwpk, vwth at token start (vwt_support, .vwpk).

Every token matching /[A-Za-z0-9_]*vw[A-Za-z0-9_]*/i is classified: each "vw" in it is renamed
by a rule or kept by the KEEP list (vW inside ordinary words such as WavWriter or vWidth, media
test ids md_..., the alphabet strings, dvwC, the local pair "vw, vh"). Anything unclassified
stops --apply, so code written after this script cannot slip through.

Never edited:
  * packages/*/third_party/**, .git, build/, .dart_tool/, Pods/, .gradle/, .cxx/,
    android/key.properties, *.jks, *.keystore, and this folder (tool/rename/);
  * binary files: --verify scans them for real names as readable strings; the spike metallibs
    are recompiled on the Mac;
  * generated files (lock files, plugin registrants, Pigeon and ffigen output, metallib
    BUILD_INFO) and hashed fixtures (.vwproj documents, the .vsprite manifest): --regenerate
    rebuilds them with the repo's own generators.
"""

from __future__ import annotations

import argparse
import fnmatch
import os
import platform
import re
import shutil
import subprocess
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Dict, List, Optional, Tuple

# --------------------------------------------------------------------------------------------
# Rules
# --------------------------------------------------------------------------------------------

RULE_NAMES = {
    "1": "brand (vwish -> danaview)",
    "2": "project type (vwproj -> dnproj)",
    "3": "C/FFI prefix (vw_ -> dv_)",
    "4": "macro prefix (VW_ -> DV_)",
    "5": "namespace and dotted ids (vw:: / vw. -> dv)",
    "6": "camel prefix (Vw/vw/VW + upper -> Dv/dv/DV)",
    "7": "lowercase tags (vwt, vwpk, vwth, vwspike, vwtest -> dv...)",
}

SUBSTRING_RULES: List[Tuple[str, bytes, bytes]] = [
    ("2", b"vwproj", b"dnproj"),
    ("2", b"Vwproj", b"Dnproj"),
    ("2", b"VWPROJ", b"DNPROJ"),
    ("1", b"vwish", b"danaview"),
    ("1", b"Vwish", b"Danaview"),
    ("1", b"VWISH", b"DANAVIEW"),
]
CASE_MAP = {b"vw": b"dv", b"Vw": b"Dv", b"VW": b"DV"}
TAG_AFTER = re.compile(rb"(?:test|spike|pk|th|t)(?![a-z])")

# Tokens that only contain the letters, kept whole.
KEEP_TOKENS = {b"dvwC"}  # MP4 Dolby Vision configuration box
KEEP_PATTERNS = [
    (re.compile(rb"^(?:qh_)?md_[A-Za-z0-9]+$"), "random media/test id"),
    (re.compile(rb"(?i)uvwxyz"), "alphabet string"),
    # Base64 test data (e.g. Ac3Fixture.kt): long random strings where "vw" is a coincidence.
    (re.compile(rb"^(?=[A-Za-z0-9]{24,}$)(?=.*[0-9])(?=.*[a-z])(?=.*[A-Z])(?!.*(?i:vwish|vwproj))[A-Za-z0-9]+$"), "base64 data"),
]

TOKEN = re.compile(rb"[A-Za-z0-9_]+")
ANY_VW = re.compile(rb"(?i)vw")
BRAND_ANY = re.compile(rb"(?i)vwish|vwproj")

# Real names as readable strings inside binaries (compression noise such as "Vw_", "VWSA" or
# "vWEQ" does not match).
BINARY_NAME = re.compile(
    rb"(?i:vwish|vwproj)"
    rb"|(?<![A-Za-z0-9])_?(?:vw|VW)_[A-Za-z]{3,}"
    rb"|(?<![A-Za-z0-9])(?:Vw|VW)[A-Z][a-z]{2,}"
    rb"|(?<![A-Za-z0-9])vw[A-Z][a-z]{2,}"
    rb"|(?<![A-Za-z0-9])(?:vwt|vwpk|vwth|vwspike|VWPK|VWTH)(?![A-Za-z0-9])"
    rb"|(?<![A-Za-z0-9])vw::"
)


# Compressed media: short matches there are compression noise, so only the brand or a whole
# identifier of 7+ characters inside a readable text run counts as a real name.
COMPRESSED_EXT = {".png", ".jpg", ".jpeg", ".mp4", ".mov", ".mkv", ".webm", ".m4a", ".wav", ".jar",
                  ".ttf", ".otf", ".ico", ".gif", ".webp", ".aac", ".mp3"}
PRINTABLE_RUN = re.compile(rb"[ -~]{8,}")
IDENT = re.compile(rb"[A-Za-z0-9_:]+")


def binary_names(path: str, data: bytes) -> List[str]:
    """Real names found as readable strings in a binary file."""
    if PurePosixPath(path).suffix.lower() not in COMPRESSED_EXT:
        return sorted({m.decode("latin-1") for m in BINARY_NAME.findall(data)})
    names = set()
    for run in PRINTABLE_RUN.finditer(data):
        text = run.group()
        for m in BINARY_NAME.finditer(text):
            whole = next(i.group() for i in IDENT.finditer(text) if i.start() <= m.start() < i.end())
            if BRAND_ANY.search(whole) or len(whole) >= 7:
                names.add(whole.decode("latin-1"))
    return sorted(names)


@dataclass
class Event:
    kind: str  # rule number, "KEEP" or "UNCLASSIFIED"
    old: str
    new: str = ""
    note: str = ""


def _occurrence_rule(s: bytes, before: bytes, after: bytes, pre: bytes) -> Optional[str]:
    """The rule renaming the "vw" [s] at this position of a token, or None."""
    if s == b"vw" and before == b"" and TAG_AFTER.match(after):
        return "7"
    if s in (b"vw", b"VW") and after.startswith(b"_"):
        if before == b"" or before.endswith(b"_") or before == b"lib":
            return "3" if s == b"vw" else "4"
        if s == b"VW" and before == b"D" and pre.endswith(b"-"):
            return "4"
    nxt = after[:1]
    if nxt and (nxt.isupper() or nxt.isdigit()):
        if s == b"Vw" and (before == b"" or before[-1:].islower()):
            return "6"
        if s in (b"vw", b"VW") and before == b"":
            return "6"
    return None


def map_token(tok: bytes, pre: bytes, post: bytes) -> Tuple[bytes, List[Event]]:
    """Maps one token (already brand-mapped). [pre]/[post] are the text around it."""
    if not ANY_VW.search(tok):
        return tok, []
    t = tok.decode("latin-1")
    if tok == b"vw":
        if post.startswith(b"::") or re.match(rb"\.[A-Za-z]", post) or pre.endswith(b"namespace "):
            return b"dv", [Event("5", t, "dv")]
        if re.match(rb", ?vh\b", post):
            return tok, [Event("KEEP", t, note="local (vw, vh) = video width/height")]
        return tok, [Event("UNCLASSIFIED", t)]
    if tok == b"VW":
        return b"DV", [Event("6", t, "DV")]
    out = bytearray()
    events: List[Event] = []
    unmatched = []
    rules = []
    i = 0
    low = tok.lower()
    while True:
        j = low.find(b"vw", i)
        if j < 0:
            out += tok[i:]
            break
        s = tok[j:j + 2]
        rule = _occurrence_rule(s, tok[:j], tok[j + 2:], pre)
        out += tok[i:j]
        if rule:
            out += CASE_MAP[s]
            rules.append(rule)
        else:
            out += s
            unmatched.append(s)
        i = j + 2
    new = bytes(out)
    if rules:
        events.append(Event(min(rules), t, new.decode("latin-1")))
    if unmatched:
        if all(s == b"vW" for s in unmatched):
            events.append(Event("KEEP", t, note="vW inside an ordinary word"))
        elif tok in KEEP_TOKENS:
            events.append(Event("KEEP", t, note="MP4 box type"))
        else:
            for pat, why in KEEP_PATTERNS:
                if pat.search(tok):
                    events.append(Event("KEEP", t, note=why))
                    break
            else:
                events.append(Event("UNCLASSIFIED", t))
    return new, events


def map_bytes(data: bytes) -> Tuple[bytes, List[Event]]:
    """Applies rules 1-7 to a text; returns the new bytes and one event per change or keep."""
    events: List[Event] = []
    for rule, src, dst in SUBSTRING_RULES:
        c = data.count(src)
        if c:
            events.extend(Event(rule, src.decode(), dst.decode()) for _ in range(c))
            data = data.replace(src, dst)
    if not ANY_VW.search(data):
        return data, events
    out = bytearray()
    last = 0
    for m in TOKEN.finditer(data):
        tok = m.group()
        if b"w" not in tok and b"W" not in tok:
            continue
        new, ev = map_token(tok, data[max(0, m.start() - 12):m.start()], data[m.end():m.end() + 6])
        if ev:
            events.extend(ev)
        if new != tok:
            out += data[last:m.start()] + new
            last = m.end()
    out += data[last:]
    return bytes(out), events


def map_name(name: str) -> str:
    return map_bytes(name.encode("utf-8"))[0].decode("utf-8")


# --------------------------------------------------------------------------------------------
# Exclusions and special files
# --------------------------------------------------------------------------------------------

EXCLUDED_DIR_NAMES = {".git", "build", ".dart_tool", "Pods", ".gradle", ".cxx"}
EXCLUDED_FILE_GLOBS = ["android/key.properties", "*.jks", "*.keystore"]
SELF_DIR = "tool/rename"

GENERATED_NAMES = {
    "pubspec.lock", "Podfile.lock",
    "generated_plugin_registrant.cc", "generated_plugin_registrant.h", "generated_plugins.cmake",
    "GeneratedPluginRegistrant.swift", "GeneratedPluginRegistrant.java",
    "GeneratedPluginRegistrant.m", "GeneratedPluginRegistrant.h",
}
GENERATED_GLOBS = ["spikes/*/*/Prebuilt/BUILD_INFO.txt"]
GENERATED_MARKERS = [b"Autogenerated from Pigeon", b"Generated by `package:ffigen`"]

# Byte-exact fixtures whose bytes are hashed (header SHA-256, Adler-32 of a raster of the name).
HASHED_GLOBS = ["*.vwproj", "*.dnproj", "*/test_fixtures/sprites/sprites.json"]

# Only the Mac regenerates these faithfully (CocoaPods; Metal; the sprite rasterizer and zlib
# differ per host, so another host also rewrites sprites that never contained the name).
MAC_ONLY_GLOBS = ["Podfile.lock", "*/test_fixtures/sprites/sprites.json", "*.metallib",
                  "spikes/*/*/Prebuilt/BUILD_INFO.txt"]

# Pictures that may show the old name or logo: renamed, never redrawn by this script.
ARTWORK_GLOBS = [
    "assets/branding/*",
    "ios/Runner/Assets.xcassets/AppIcon.appiconset/*",
    "ios/Runner/Assets.xcassets/LaunchImage.imageset/*",
    "macos/Runner/Assets.xcassets/AppIcon.appiconset/*",
    "android/app/src/main/res/mipmap-*/*",
    "android/app/src/main/res/drawable*/*",
    "windows/runner/resources/*",
    "linux/*.png",
    "ios/fastlane/screenshots*/*",
    "ios/fastlane/metadata/*",
    "android/fastlane/metadata/*/images/*",
    "publishing/screenshots/*",
    "publishing/source_assets/*",
]
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".ico", ".icns", ".webp", ".gif", ".svg", ".pdf"}


def _glob(path: str, pattern: str) -> bool:
    # fnmatch's "*" also crosses "/", so "dir/*" covers the whole subtree.
    return fnmatch.fnmatchcase(path, pattern) or fnmatch.fnmatchcase("/" + path, pattern)


def is_third_party(path: str) -> bool:
    parts = path.split("/")
    return len(parts) >= 3 and parts[0] == "packages" and parts[2] == "third_party"


def content_excluded(path: str) -> bool:
    parts = path.split("/")
    if any(p in EXCLUDED_DIR_NAMES for p in parts[:-1]) or is_third_party(path):
        return True
    if path == SELF_DIR or path.startswith(SELF_DIR + "/"):
        return True
    return any(_glob(path, g) or fnmatch.fnmatchcase(parts[-1], g) for g in EXCLUDED_FILE_GLOBS)


def is_hashed(path: str) -> bool:
    return any(_glob(path, g) for g in HASHED_GLOBS)


def is_generated(path: str, data: bytes) -> bool:
    if PurePosixPath(path).name in GENERATED_NAMES or any(_glob(path, g) for g in GENERATED_GLOBS):
        return True
    head = data[:4096]
    return any(m in head for m in GENERATED_MARKERS)


def is_mac_pending(path: str) -> bool:
    name = PurePosixPath(path).name
    return any(_glob(path, g) or fnmatch.fnmatchcase(name, g) for g in MAC_ONLY_GLOBS)


def is_artwork(path: str) -> bool:
    return PurePosixPath(path).suffix.lower() in IMAGE_EXT and any(_glob(path, g) for g in ARTWORK_GLOBS)


def is_binary(data: bytes) -> bool:
    return b"\0" in data


# --------------------------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------------------------


def mapped_limit(path: str) -> int:
    """Leading segments subject to the rules (below packages/<pkg>/third_party/ nothing is)."""
    return 2 if is_third_party(path) else len(path.split("/"))


def map_path(path: str) -> str:
    parts = path.split("/")
    limit = mapped_limit(path)
    return "/".join(map_name(p) if i < limit else p for i, p in enumerate(parts))


# --------------------------------------------------------------------------------------------
# Targeted patches (applied by --apply to the file at its renamed path; idempotent)
# --------------------------------------------------------------------------------------------


@dataclass
class Patch:
    path: str  # path after the rename
    done_marker: bytes
    description: str

    def apply(self, data: bytes) -> Optional[bytes]:
        raise NotImplementedError


class RelativeMetallibPaths(Patch):
    """build_metallibs.sh compiles from relative paths so the metallibs carry no checkout path."""

    def apply(self, data: bytes) -> Optional[bytes]:
        if self.done_marker in data:
            return data
        lines = re.compile(rb'^build "\$HERE/([^"]+)" "\$HERE/([^"]+)"', re.M)
        if not lines.search(data):
            return None
        m = lines.search(data)
        data = data[:m.start()] + self.done_marker + b"\n" + data[m.start():]
        return lines.sub(rb'build "\1" "\2"', data)


PATCHES: List[Patch] = [
    RelativeMetallibPaths(
        "spikes/ios_engine/tools/build_metallibs.sh",
        b'cd "$HERE"  # relative source paths: the metallibs must not embed the absolute checkout path',
        "compile the spike Metal kernels from relative paths (no absolute checkout path in the metallibs)",
    ),
]


# --------------------------------------------------------------------------------------------
# Repository access
# --------------------------------------------------------------------------------------------


def git(root: Path, *args: str, check: bool = True) -> str:
    r = subprocess.run(["git", "-c", "core.quotepath=off", *args], cwd=root, capture_output=True)
    if check and r.returncode != 0:
        sys.exit(f"git {' '.join(args[:3])} failed:\n{r.stderr.decode(errors='replace')}")
    return r.stdout.decode("utf-8", errors="surrogateescape")


def tracked(root: Path) -> List[str]:
    return sorted(p for p in git(root, "ls-files", "-z").split("\0") if p)


def untracked(root: Path) -> List[str]:
    return sorted(p for p in git(root, "ls-files", "-z", "--others", "--exclude-standard").split("\0") if p)


def symlinks(root: Path) -> set:
    res = set()
    for rec in git(root, "ls-files", "-s", "-z").split("\0"):
        if rec.startswith("120000 "):
            res.add(rec.split("\t", 1)[1])
    return res


def read(root: Path, path: str, links: set) -> Optional[bytes]:
    full = root / path
    if path in links and full.is_symlink():
        return os.readlink(full).replace("\\", "/").encode("utf-8")
    try:
        return full.read_bytes()
    except (FileNotFoundError, IsADirectoryError, PermissionError, NotADirectoryError):
        return None


def write(root: Path, path: str, data: bytes, links: set) -> None:
    full = root / path
    if path in links and full.is_symlink():
        full.unlink()
        os.symlink(data.decode("utf-8"), full)
        return
    with open(full, "wb") as f:  # bytes in, bytes out: line endings and encodings are untouched
        f.write(data)


def file_type(path: str) -> str:
    name = PurePosixPath(path).name
    if name.endswith(".fixture"):
        return ".fixture"
    return PurePosixPath(path).suffix or name


def line_of(data: bytes, token: str) -> str:
    i = data.find(token.encode("latin-1"))
    if i < 0:
        return ""
    s = data.rfind(b"\n", 0, i) + 1
    e = data.find(b"\n", i)
    return data[s:e if e >= 0 else len(data)].decode("utf-8", errors="replace").strip()[:140]


# --------------------------------------------------------------------------------------------
# Planning
# --------------------------------------------------------------------------------------------


@dataclass
class Plan:
    edits: Dict[str, Tuple[bytes, int]] = field(default_factory=dict)
    rule_counts: Counter = field(default_factory=Counter)
    rule_tokens: Dict[str, Counter] = field(default_factory=lambda: defaultdict(Counter))
    keeps: Dict[Tuple[str, str], int] = field(default_factory=Counter)
    unclassified: Dict[str, List[str]] = field(default_factory=lambda: defaultdict(list))
    renames: List[Tuple[str, str]] = field(default_factory=list)
    dir_renames: List[Tuple[str, str]] = field(default_factory=list)
    generated: Dict[str, int] = field(default_factory=dict)
    hashed: Dict[str, int] = field(default_factory=dict)
    binaries: Dict[str, List[str]] = field(default_factory=dict)
    artwork: List[Tuple[str, str]] = field(default_factory=list)
    patches: List[Tuple[str, str]] = field(default_factory=list)
    collisions: List[str] = field(default_factory=list)


def record(plan: Plan, path: str, data: bytes, events: List[Event]) -> int:
    n = 0
    for e in events:
        if e.kind == "KEEP":
            plan.keeps[(e.old, e.note)] += 1
        elif e.kind == "UNCLASSIFIED":
            if len(plan.unclassified[e.old]) < 5:
                plan.unclassified[e.old].append(f"{path}: {line_of(data, e.old)}")
        else:
            n += 1
    return n


def make_plan(root: Path) -> Plan:
    plan = Plan()
    files = tracked(root)
    links = symlinks(root)
    for path in files:
        data = read(root, path, links)
        if data is None:
            continue
        if content_excluded(path):
            continue
        if is_binary(data):
            names = binary_names(path, data)
            if names:
                plan.binaries[path] = names
            continue
        new, events = map_bytes(data)
        if not events:
            continue
        n = record(plan, path, data, events)
        if not n:
            continue
        if is_hashed(path):
            plan.hashed[path] = n
            continue
        if is_generated(path, data):
            plan.generated[path] = n
            continue
        for e in events:
            if e.kind in RULE_NAMES:
                plan.rule_counts[e.kind] += 1
                plan.rule_tokens[e.kind][(e.old, e.new)] += 1
        plan.edits[path] = (new, n)

    # Targeted patches, on the renamed path.
    by_new = {map_path(p): p for p in files}
    for patch in PATCHES:
        old = by_new.get(patch.path)
        if old is None:
            plan.patches.append((patch.path, "SKIPPED: file not found"))
            continue
        base = plan.edits.get(old, (read(root, old, links), 0))[0]
        patched = patch.apply(base)
        if patched is None:
            plan.patches.append((patch.path, "NOT APPLIED: anchor not found, check by hand"))
        elif patched != base:
            plan.patches.append((patch.path, patch.description))
            plan.edits[old] = (patched, plan.edits.get(old, (b"", 0))[1] + 1)

    seen = set()
    new_paths = set()
    targets = set(files)
    for path in files:
        new = map_path(path)
        if is_artwork(path):
            plan.artwork.append((path, new))
        if new == path:
            continue
        plan.renames.append((path, new))
        if new in targets or new in new_paths:
            plan.collisions.append(f"{path} -> {new}")
        new_paths.add(new)
        parts = path.split("/")
        for i in range(1, min(mapped_limit(path), len(parts) - 1) + 1):
            d = "/".join(parts[:i])
            if map_name(parts[i - 1]) != parts[i - 1] and d not in seen:
                seen.add(d)
                plan.dir_renames.append((d, "/".join(parts[:i - 1] + [map_name(parts[i - 1])])))
    plan.dir_renames.sort(key=lambda r: (-r[0].count("/"), r[0]))  # deepest first
    return plan


# --------------------------------------------------------------------------------------------
# Regeneration
# --------------------------------------------------------------------------------------------


@dataclass
class Step:
    title: str
    cwd: str
    cmd: List[str]
    env: Dict[str, str] = field(default_factory=dict)
    needs: str = ""
    mac_only: bool = False
    fallback: str = ""  # "map": on failure off macOS, write the rule-mapped file (provisional)
    output: str = ""


def _dirs_with(root: Path, name: str) -> List[str]:
    res = []
    for p in tracked(root):
        if PurePosixPath(p).name == name and not content_excluded(p) and not p.startswith("spikes/"):
            res.append(str(PurePosixPath(p).parent))
    return sorted(res, key=lambda d: (d != ".", d))


def regen_steps(root: Path) -> List[Step]:
    files = tracked(root)
    steps = [Step("Resolve packages (pubspec.lock, plugin registrants)", d, ["flutter", "pub", "get"])
             for d in _dirs_with(root, "pubspec.yaml")]
    for p in files:
        pp = PurePosixPath(p)
        if pp.parent.name == "pigeons" and pp.suffix == ".dart" and not content_excluded(p):
            if b"@ConfigurePigeon" in (read(root, p, set()) or b""):
                steps.append(Step("Pigeon output", str(pp.parent.parent),
                                  ["dart", "run", "pigeon", "--input", f"pigeons/{pp.name}"]))
    for d in _dirs_with(root, "ffigen.yaml"):
        out = ""
        m = re.search(rb"^output:\s*['\"]?([^'\"\n]+)", (root / d / "ffigen.yaml").read_bytes(), re.M)
        if m:
            out = f"{d}/{m.group(1).decode().strip()}"
        steps.append(Step("ffigen bindings (needs libclang)", d,
                          ["dart", "run", "ffigen", "--config", "ffigen.yaml"], fallback="map", output=out))
    core = "packages/danaview_editor_core"
    api = "packages/danaview_editor_engine_api"
    steps += [
        Step("Codec golden bodies and kitchen_sink.dnproj", core,
             ["dart", "test", "test/codec/determinism_test.dart"],
             env={"DANAVIEW_UPDATE_GOLDENS": "1"}, needs=f"{core}/test/codec/determinism_test.dart"),
        Step("Schema fixtures (.dnproj headers and checksums)", core,
             ["dart", "test", "test/codec_migrations/fixtures_test.dart"],
             env={"REGENERATE_FIXTURES": "1"}, needs=f"{core}/test/codec_migrations/fixtures_test.dart"),
        Step(".vsprite fixtures and sprites.json", api,
             ["flutter", "test", "test/render_prep/sprite_fixtures_test.dart"],
             env={"DANAVIEW_REGEN_SPRITE_FIXTURES": "1"},
             needs=f"{api}/test/render_prep/sprite_fixtures_test.dart", mac_only=True),
        Step("Reference vectors and goldens (expect no change)", api, ["dart", "run", "tool/regen_goldens.dart"],
             needs=f"{api}/tool/regen_goldens.dart"),
    ]
    steps += [Step("CocoaPods (Podfile.lock)", d, ["pod", "install"], mac_only=True)
              for d in _dirs_with(root, "Podfile")]
    steps.append(Step("RECOMPILE the spike metallibs and BUILD_INFO.txt", "spikes/ios_engine",
                      ["bash", "tools/build_metallibs.sh"], needs="spikes/ios_engine/tools/build_metallibs.sh",
                      mac_only=True))
    return steps


def shell_line(s: Step) -> str:
    env = " ".join(f"{k}={v}" for k, v in s.env.items())
    return f"(cd {s.cwd} && {env + ' ' if env else ''}{' '.join(s.cmd)})"


def regenerate(root: Path) -> int:
    is_mac = platform.system() == "Darwin"
    failed = 0
    links = symlinks(root)
    for s in regen_steps(root):
        if s.mac_only and not is_mac:
            print(f"SKIP (macOS only)  {shell_line(s)}")
            continue
        if s.needs and not (root / s.needs).exists():
            print(f"SKIP (no {s.needs})  {shell_line(s)}")
            continue
        exe = shutil.which(s.cmd[0])
        r = None
        if exe:
            print(f"RUN  {shell_line(s)}", flush=True)
            r = subprocess.run([exe, *s.cmd[1:]], cwd=root / s.cwd, env=dict(os.environ, **s.env),
                               capture_output=True)
        if exe and r.returncode == 0:
            continue
        log = (r.stdout + r.stderr).decode(errors="replace") if r else f"{s.cmd[0]} not on PATH"
        if s.fallback == "map" and not is_mac and s.output and (root / s.output).exists():
            data = read(root, s.output, links)
            write(root, s.output, map_bytes(data)[0], links)
            print(f"PROVISIONAL  {s.output}: {s.title} failed here, wrote the rule-mapped file instead;"
                  " the Mac regenerates it for real at cutover (expect no diff)")
            continue
        failed += 1
        print(f"FAIL  {s.title}")
        print("\n".join("    " + t for t in log.splitlines()[-25:]))
    return 1 if failed else 0


# --------------------------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------------------------

MAC_CHECKLIST = [
    "Rename the checkout folder (…/vwish_player -> …/danaview_player) before anything else, and move "
    "Claude's notes folder to match (~/.claude/projects/-Users-besaoct-Desktop-vwish-player -> "
    "…-danaview-player).",
    "--regenerate on the Mac: pod install (ios, macos, editor engine example), the .vsprite fixtures "
    "(only text_box_stroke_shadow may change), ffigen for real (no diff expected), RECOMPILE the 4 spike "
    "metallibs; then `--verify` with no flags must pass.",
    "Metal: the renamed kernels (dv_look, dv_blur_h/v, dv_sharpen, dv_look_st, dv_blur_h_st, ...) and "
    "their Swift lookups in DVSpikeKernels/DVSpikeStitchable; `strings *.metallib | grep -i -e vw -e /Users` "
    "must be empty.",
    "Podspecs: danaview_whisper, danaview_editor_engine (resource bundle DVEditorKernels), the spike pods "
    "DVSpikeKernels and DVSpikeStitchable; `pod lib lint` or a clean `pod install`.",
    "Swift: the editor engine plugin (Pigeon output, DVPK waveforms, DVTH thumbnails, DVEditorKernels "
    "loader), danaview_whisper (dv_whisper_forwarder.cpp, DynamicLibrary.open('danaview_whisper.framework/"
    "danaview_whisper'), os_log subsystem com.vecvel.danaview.whisper).",
    "Xcode projects: PRODUCT_BUNDLE_IDENTIFIER com.vecvel.danaview and com.vecvel.danaview.RunnerTests "
    "(ios, macos, example), danaview.app / TEST_HOST, schemes, ExportOptions.plist, entitlements, "
    "CFBundleURLSchemes danaview, CFBundleURLName.",
    "Builds and tests: flutter build ios --debug --no-codesign, flutter build macos --debug, the example "
    "app's RunnerTests (XCTest), the whisper host tests (src/tests, dv_test.h) with DV_SANITIZER.",
    "The spike host app (DVSpikeHost, DVSpikeTests, DVSpikeUITests): builds, Info.plist name \"DV Spike\".",
    "fastlane: deliver/supply dry runs with the new Appfiles and metadata; new App Store and Play "
    "records for com.vecvel.danaview.",
]


def report(root: Path, plan: Plan) -> str:
    out: List[str] = []
    w = out.append
    head = git(root, "rev-parse", "--short", "HEAD").strip()
    w("# Vwish -> Danaview rename: dry-run report")
    w("")
    w(f"Generated by `tool/rename/rename_to_danaview.py --dry-run` on `{head}`.")
    w("")
    total = sum(n for _, n in plan.edits.values())
    w("## Summary")
    w("")
    w(f"- Content edits: {len(plan.edits)} files, {total} changes")
    w(f"- Paths: {len(plan.renames)} tracked files move, {len(plan.dir_renames)} folders are renamed")
    w(f"- Regenerated, not edited: {len(plan.generated)} generated files, {len(plan.hashed)} hashed fixtures")
    w(f"- Binaries carrying real names: {len(plan.binaries)} (RECOMPILE ON MAC AT CUTOVER)")
    w(f"- Pictures that may show the old name: {len(plan.artwork)} (need new Danaview artwork)")
    w(f"- Unclassified tokens: {len(plan.unclassified)}" + (" -> --apply REFUSES TO RUN" if plan.unclassified else ""))
    w(f"- Path collisions: {len(plan.collisions)}" + (" -> --apply REFUSES TO RUN" if plan.collisions else ""))
    w("")
    if plan.unclassified:
        w("## UNCLASSIFIED tokens (add a rule or a KEEP entry)")
        w("")
        for tok, where in sorted(plan.unclassified.items()):
            w(f"- `{tok}`")
            for x in where:
                w(f"  - {x}")
        w("")
    if plan.collisions:
        w("## PATH COLLISIONS")
        w("")
        out.extend(f"- {c}" for c in plan.collisions)
        w("")
    w("## Changes by rule")
    w("")
    w("| Rule | Changes | Distinct tokens |")
    w("|---|---:|---:|")
    for r in sorted(RULE_NAMES):
        w(f"| {r}. {RULE_NAMES[r]} | {plan.rule_counts[r]} | {len(plan.rule_tokens[r])} |")
    w("")
    for r in sorted(RULE_NAMES):
        toks = plan.rule_tokens[r]
        if not toks:
            continue
        w(f"### Rule {r}: {RULE_NAMES[r]}")
        w("")
        for (old, new), n in sorted(toks.items(), key=lambda kv: (-kv[1], kv[0])):
            w(f"- `{old}` -> `{new}` ({n})")
        w("")
    w("## Kept on purpose (KEEP)")
    w("")
    for (tok, why), n in sorted(plan.keeps.items(), key=lambda kv: (kv[0][1], kv[0][0])):
        w(f"- `{tok}` ({n}): {why}")
    w("")
    w("## Content edits by file type")
    w("")
    files_t: Counter = Counter()
    hits_t: Counter = Counter()
    for p, (_, n) in plan.edits.items():
        files_t[file_type(p)] += 1
        hits_t[file_type(p)] += n
    w("| File type | Files | Changes |")
    w("|---|---:|---:|")
    for t in sorted(files_t, key=lambda t: (-hits_t[t], t)):
        w(f"| `{t}` | {files_t[t]} | {hits_t[t]} |")
    w("")
    w("## Targeted patches")
    w("")
    for p, d in plan.patches:
        w(f"- `{p}`: {d}")
    w("")
    w("## Regeneration (never edited by hand)")
    w("")
    w("Generated files:")
    w("")
    for p in sorted(plan.generated):
        w(f"- `{p}` ({plan.generated[p]})")
    w("")
    w("Hashed fixtures (their hashes change):")
    w("")
    for p in sorted(plan.hashed):
        w(f"- `{p}` ({plan.hashed[p]})")
    w("")
    w("Binaries with real names as readable strings, RECOMPILE ON MAC AT CUTOVER:")
    w("")
    for p, names in sorted(plan.binaries.items()):
        w(f"- `{p}`: {', '.join(f'`{n}`' for n in names[:12])}")
    w("")
    w("Commands, in order (`--regenerate` runs them; macOS-only steps are skipped elsewhere):")
    w("")
    for s in regen_steps(root):
        cwd = map_path(s.cwd)
        line = shell_line(Step(s.title, cwd, s.cmd, s.env))
        w(f"- {s.title}{' **(macOS only)**' if s.mac_only else ''}{' (off macOS without libclang: provisional rule-mapped file)' if s.fallback else ''}: `{line}`")
    w("")
    w("## Needs new Danaview artwork (file renamed, pixels unchanged)")
    w("")
    for old, new in plan.artwork:
        w(f"- `{new}`" + (f" (was `{old}`)" if new != old else ""))
    w("")
    w("## Local folders")
    w("")
    w("Rename the local folders at cutover, and move Claude's notes folder to match: Mac "
      "`/Users/besaoct/Desktop/vwish_player` -> `danaview_player` (notes: `~/.claude/projects/"
      "-Users-besaoct-Desktop-vwish-player` -> `-Users-besaoct-Desktop-danaview-player`); Windows "
      "`…\\Desktop\\vwish` -> `…\\Desktop\\danaview_player` (notes: `%USERPROFILE%\\.claude\\projects\\"
      "C--Users-Masud-OneDrive---Zota-Healthcare-Ltd-Desktop-vwish` -> `…-Desktop-danaview-player`).")
    w("")
    w("## Mac checklist (cannot be verified on Windows)")
    w("")
    out.extend(f"- {c}" for c in MAC_CHECKLIST)
    w("")
    w(f"## Folder renames, deepest first ({len(plan.dir_renames)})")
    w("")
    out.extend(f"- `{a}/` -> `{b}/`" for a, b in plan.dir_renames)
    w("")
    w(f"## Path renames ({len(plan.renames)} tracked files)")
    w("")
    out.extend(f"- `{a}` -> `{b}`" for a, b in plan.renames)
    w("")
    return "\n".join(out)


# --------------------------------------------------------------------------------------------
# Apply and verify
# --------------------------------------------------------------------------------------------


def mv(root: Path, src: str, dst: str) -> None:
    (root / dst).parent.mkdir(parents=True, exist_ok=True)
    git(root, "mv", "--", src, dst)


def apply(root: Path, plan: Plan, allow_dirty: bool) -> None:
    if plan.unclassified or plan.collisions:
        for tok, where in sorted(plan.unclassified.items()):
            print(f"UNCLASSIFIED {tok}: {where[0]}")
        for c in plan.collisions:
            print(f"COLLISION {c}")
        sys.exit("refusing to apply: classify every token first (see --dry-run)")
    if git(root, "status", "--porcelain").strip() and not allow_dirty:
        sys.exit("refusing to apply on a dirty working tree (commit first, or pass --allow-dirty)")
    links = symlinks(root)
    for path, (data, _) in sorted(plan.edits.items()):
        write(root, path, data, links)
    print(f"edited {len(plan.edits)} files ({sum(n for _, n in plan.edits.values())} changes)")
    for p, d in plan.patches:
        print(f"patch {p}: {d}")
    # Files whose own name changes, then folders deepest first: every git mv uses the original
    # path of the item's parents, which are renamed later.
    moved = 0
    for old, new in plan.renames:
        parent = str(PurePosixPath(old).parent)
        name, new_name = PurePosixPath(old).name, PurePosixPath(new).name
        if name != new_name:
            src = old
            dst = f"{parent}/{new_name}" if parent != "." else new_name
            mv(root, src, dst)
            moved += 1
    for old, new in plan.dir_renames:
        if (root / new).exists():
            sys.exit(f"cannot move {old} -> {new}: target exists")
        mv(root, old, new)
    print(f"git mv: {moved} files, {len(plan.dir_renames)} folders (deepest first)")
    print("\nNext: python3 tool/rename/rename_to_danaview.py --regenerate   (runs, in order:)")
    for s in regen_steps(root):
        print(f"  {shell_line(s)}{'   # macOS only' if s.mac_only else ''}")
    print("then:  python3 tool/rename/rename_to_danaview.py --verify")


def verify(root: Path, allow_mac_pending: bool) -> int:
    links = symlinks(root)
    files = sorted(set(tracked(root)) | set(untracked(root)))
    bad: List[str] = []
    pending: List[str] = []
    for path in files:
        if content_excluded(path):
            continue
        if map_path(path) != path:
            bad.append(f"path: {path}")
        data = read(root, path, links)
        if data is None:
            continue
        if is_binary(data):
            found = binary_names(path, data)
        else:
            _, events = map_bytes(data)
            found = sorted({e.old for e in events if e.kind != "KEEP"})
        if found:
            line = f"{path}: {', '.join(found[:8])}"
            (pending if allow_mac_pending and is_mac_pending(path) else bad).append(line)
    for p in pending:
        print(f"PENDING (regenerate on macOS) {p}")
    for b in bad:
        print(f"REMAINS {b}")
    if bad:
        print(f"\nverify FAILED: {len(bad)} files or paths still carry the old names")
        return 1
    print(f"verify OK: no old names outside the exclusions ({len(files)} files checked"
          f"{f', {len(pending)} macOS-pending' if pending else ''})")
    return 0


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except AttributeError:
            pass
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--dry-run", action="store_true", help="report every change; change nothing")
    g.add_argument("--apply", action="store_true", help="rewrite contents, git mv files then folders")
    g.add_argument("--regenerate", action="store_true", help="rebuild generated code and hashed fixtures")
    g.add_argument("--verify", action="store_true", help="exit 1 if an old name remains")
    ap.add_argument("--root", help="repository root (default: the git top level of the current directory)")
    ap.add_argument("--report", help="with --dry-run: also write the report to this file")
    ap.add_argument("--allow-dirty", action="store_true", help="with --apply: allow uncommitted changes")
    ap.add_argument("--allow-mac-pending", action="store_true",
                    help="with --verify: tolerate files only macOS can regenerate (Podfile.lock, "
                         "sprites.json, *.metallib, BUILD_INFO.txt)")
    a = ap.parse_args()
    root = Path(git(Path(a.root) if a.root else Path.cwd(), "rev-parse", "--show-toplevel").strip())
    if BRAND_ANY.search(str(root).encode("utf-8")) and (a.verify or a.regenerate):
        print(f"WARNING: the checkout folder still has the old name ({root}). Rename it before "
              "--regenerate on macOS: Xcode and the Metal compiler embed absolute paths.")
    if a.verify:
        return verify(root, a.allow_mac_pending)
    if a.regenerate:
        return regenerate(root)
    plan = make_plan(root)
    if a.dry_run:
        text = report(root, plan)
        sys.stdout.write(text + "\n")
        if a.report:
            Path(a.report).write_bytes(text.encode("utf-8") + b"\n")
        return 1 if plan.unclassified or plan.collisions else 0
    apply(root, plan, a.allow_dirty)
    return 0


if __name__ == "__main__":
    sys.exit(main())
