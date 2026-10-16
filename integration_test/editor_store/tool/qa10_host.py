#!/usr/bin/env python3
# OWNER: QA-10
"""Host driver of the QA-10 store suite (integration_test/editor_store/qa10_store_test.dart).

It runs the three phases of the suite against one simulator / emulator and serves the file
handshake of the shared E2E suite (integration_test/editor/support/e2e_handshake.dart, same
protocol as QA-00's e2e_host.sh) for what an app cannot do to itself:

  kill               kill the app (no ack: the phase ends there)
  screenshot {name}  evidence screenshot
  backupAttrs {paths: {name: path}}
                     iOS: read back NSURLIsExcludedFromBackupKey of each directory (the
                     com.apple.metadata:com_apple_backup_excludeItem xattr the simulator writes on
                     the Mac file system, V-D4) into e2e_out/qa10-backup-attrs.json
  compareOriginals {allowedNew: [...]}
                     compare every original (Documents tree and the host's bookmarked originals)
                     with the baseline taken after the seed phase: size, SHA-256, mtime, xattrs,
                     plus the file set and mtime of every folder holding an original (D-44)

Phases (`run`): uninstall (clean start) -> seed (dies: host kill) -> baseline snapshot -> edit (dies:
host kill with the editor open) -> verify (`flutter test` reinstalls the app over the top).

iOS Simulator only on this Mac; the fsync probe (tool/fsync_probe.c) is built and injected with
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES for V-D1. The Android branch (adb, run-as) is the Windows lane's.

  integration_test/editor_store/tool/qa10_host.py -p ios -d <udid> run
  integration_test/editor_store/tool/qa10_host.py -p ios -d <udid> run verify   # one phase
  integration_test/editor_store/tool/qa10_host.py -p android -d emulator-5554 run

Evidence: build/qa10/<platform>/<device>/ (logs/, screens/, files/, baseline.json,
compare.json, backup-attrs.json, summary.txt).
"""

import argparse
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

APP_ID = "com.vecvel.danaview"
ROOT = Path(__file__).resolve().parents[3]
TEST = "integration_test/editor_store/qa10_store_test.dart"
FIXTURES = ROOT / "packages/danaview_editor_engine/test_fixtures/media"
BACKUP_XATTR = "com.apple.metadata:com_apple_backup_excludeItem"
ANDROID_SHARED = f"/sdcard/Android/data/{APP_ID}/files"
EXCLUDED_TOP = {"e2e_handshake", "e2e_out"}


class Host:
    def __init__(self, platform: str, device: str, timeout: int):
        self.platform = platform
        self.device = device
        self.timeout = timeout
        self.out = ROOT / "build" / "qa10" / platform / device
        for d in ("logs", "screens", "files"):
            (self.out / d).mkdir(parents=True, exist_ok=True)
        self.host_dir = self.out / "host"
        self.died = False

    # ---- logging --------------------------------------------------------------------------------

    def log(self, msg: str) -> None:
        line = f"[qa10_host {time.strftime('%H:%M:%S')}] {msg}"
        print(line, file=sys.stderr, flush=True)
        with open(self.out / "logs" / "host.log", "a") as f:
            f.write(line + "\n")

    def sh(self, *cmd, check=False, capture=True, env=None) -> subprocess.CompletedProcess:
        return subprocess.run(list(cmd), check=check, capture_output=capture, text=True, env=env)

    # ---- device file access ---------------------------------------------------------------------

    def ios_container(self):
        r = self.sh("xcrun", "simctl", "get_app_container", self.device, APP_ID, "data")
        p = r.stdout.strip()
        return Path(p) if r.returncode == 0 and p else None

    def shared(self):
        """The handshake root: iOS Documents (host path) or the Android external files folder."""
        if self.platform == "ios":
            c = self.ios_container()
            return (c / "Documents") if c else None
        return ANDROID_SHARED

    def list_requests(self):
        if self.platform == "ios":
            d = self.shared()
            if not d or not (d / "e2e_handshake").is_dir():
                return []
            return sorted(p.name for p in (d / "e2e_handshake").glob("req-*.json"))
        r = self.sh("adb", "-s", self.device, "shell", f"ls {ANDROID_SHARED}/e2e_handshake/ 2>/dev/null")
        return sorted(n.strip() for n in r.stdout.splitlines() if n.strip().startswith("req-") and n.strip().endswith(".json"))

    def read_shared(self, rel: str) -> str:
        if self.platform == "ios":
            return (self.shared() / rel).read_text()
        return self.sh("adb", "-s", self.device, "shell", f"cat {ANDROID_SHARED}/{rel}").stdout

    def write_shared(self, rel: str, text: str) -> None:
        if self.platform == "ios":
            target = self.shared() / rel
            tmp = target.with_name(target.name + ".tmp")
            tmp.write_text(text)
            tmp.rename(target)
            return
        local = self.out / "files" / ".push.tmp"
        local.write_text(text)
        self.sh("adb", "-s", self.device, "push", str(local), f"{ANDROID_SHARED}/{rel}.tmp")
        self.sh("adb", "-s", self.device, "shell", f"mv {ANDROID_SHARED}/{rel}.tmp {ANDROID_SHARED}/{rel}")

    def move_shared(self, a: str, b: str) -> None:
        if self.platform == "ios":
            (self.shared() / a).rename(self.shared() / b)
        else:
            self.sh("adb", "-s", self.device, "shell", f"mv {ANDROID_SHARED}/{a} {ANDROID_SHARED}/{b}")

    def collect(self) -> None:
        if self.platform == "ios":
            d = self.shared()
            if d and (d / "e2e_out").is_dir():
                shutil.copytree(d / "e2e_out", self.out / "files", dirs_exist_ok=True)
        else:
            self.sh("adb", "-s", self.device, "pull", f"{ANDROID_SHARED}/e2e_out/.", str(self.out / "files"))

    # ---- actions --------------------------------------------------------------------------------

    def kill(self) -> None:
        if self.platform == "ios":
            self.sh("xcrun", "simctl", "terminate", self.device, APP_ID)
        else:
            self.sh("adb", "-s", self.device, "shell", "am", "force-stop", APP_ID)

    def screenshot(self, name: str) -> None:
        f = self.out / "screens" / f"{time.strftime('%H%M%S')}-{name}.png"
        if self.platform == "ios":
            self.sh("xcrun", "simctl", "io", self.device, "screenshot", str(f))
        else:
            with open(f, "wb") as fh:
                subprocess.run(["adb", "-s", self.device, "exec-out", "screencap", "-p"], stdout=fh)
        self.log(f"screenshot {f}")

    def backup_attrs(self, paths: dict) -> dict:
        result = {}
        for name, path in paths.items():
            p = Path(path)
            entry = {"path": path, "exists": p.exists(), "excluded": False, "xattr": None}
            if p.exists():
                r = self.sh("xattr", "-p", BACKUP_XATTR, str(p))
                if r.returncode == 0:
                    entry["excluded"] = True
                    entry["xattr"] = r.stdout.strip()
            result[name] = entry
        return result

    # ---- snapshot of the originals (D-44) -------------------------------------------------------

    @staticmethod
    def xattrs(path: Path) -> dict:
        names = subprocess.run(["xattr", str(path)], capture_output=True, text=True).stdout.split("\n")
        out = {}
        for n in (n.strip() for n in names):
            if not n:
                continue
            v = subprocess.run(["xattr", "-p", "-x", n, str(path)], capture_output=True, text=True).stdout
            out[n] = " ".join(v.split())
        return out

    @staticmethod
    def sha256(path: Path) -> str:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()

    def snapshot_tree(self, base: Path, skip_top=frozenset()) -> dict:
        files, dirs = {}, {}
        for dirpath, dirnames, filenames in os.walk(base):
            rel_dir = os.path.relpath(dirpath, base)
            if rel_dir == ".":
                dirnames[:] = [d for d in dirnames if d not in skip_top]
            dirs[rel_dir] = sorted(filenames + dirnames)
            for fn in filenames:
                p = Path(dirpath) / fn
                rel = os.path.relpath(p, base)
                st = p.lstat()
                files[rel] = {
                    "size": st.st_size,
                    "sha256": self.sha256(p),
                    "mtime_ns": st.st_mtime_ns,
                    "xattrs": self.xattrs(p),
                }
        return {"files": files, "dirs": dirs}

    def originals_parents(self, files: dict) -> set:
        return {os.path.dirname(rel) or "." for rel in files}

    def snapshot(self) -> dict:
        if self.platform != "ios":
            return self.snapshot_android()
        docs = self.shared()
        snap = {
            "documents_path": str(docs),
            "documents": self.snapshot_tree(docs, EXCLUDED_TOP),
            "host": self.snapshot_tree(self.host_dir / "originals"),
        }
        dir_mtimes = {}
        for key, base in (("documents", docs), ("host", self.host_dir / "originals")):
            for parent in self.originals_parents(snap[key]["files"]):
                if key == "documents" and (parent == "." or parent.split("/")[0] == "Exports"):
                    continue  # Documents itself and Exports/ legitimately change (D-44 keep a copy)
                p = base / parent
                dir_mtimes[f"{key}:{parent}"] = {"mtime_ns": p.stat().st_mtime_ns, "xattrs": self.xattrs(p)}
        snap["parent_dirs"] = dir_mtimes
        return snap

    def snapshot_android(self) -> dict:
        state = json.loads(self.read_shared("e2e_out/state-qa10.json"))
        docs = state["documents"]
        script = (
            f"cd '{docs}' && find . -path ./e2e_handshake -prune -o -path ./e2e_out -prune -o -type f "
            "-exec sh -c 'for f; do echo \"$(stat -c \"%s %Y\" \"$f\") $(sha256sum \"$f\" | cut -d\" \" -f1) $f\"; done' _ {} +"
        )
        r = self.sh("adb", "-s", self.device, "shell", "run-as", APP_ID, "sh", "-c", script)
        files = {}
        for line in r.stdout.splitlines():
            parts = line.strip().split(" ", 3)
            if len(parts) == 4:
                size, mtime, sha, rel = parts
                files[rel[2:] if rel.startswith("./") else rel] = {"size": int(size), "sha256": sha, "mtime_ns": int(mtime) * 10**9, "xattrs": {}}
        dirs = {}
        for rel in files:
            dirs.setdefault(os.path.dirname(rel) or ".", []).append(os.path.basename(rel))
        return {"documents_path": docs, "documents": {"files": files, "dirs": {k: sorted(v) for k, v in dirs.items()}},
                "host": {"files": {}, "dirs": {}}, "parent_dirs": {}}

    def compare(self, allowed_new: list) -> dict:
        baseline = json.loads((self.out / "baseline.json").read_text())
        now = self.snapshot()
        (self.out / "after.json").write_text(json.dumps(now, indent=1, sort_keys=True))
        problems, checked = [], 0
        for key in ("documents", "host"):
            before, after = baseline[key]["files"], now[key]["files"]
            for rel, b in before.items():
                checked += 1
                a = after.get(rel)
                if a is None:
                    problems.append(f"{key}:{rel} missing")
                    continue
                for field in ("size", "sha256", "mtime_ns", "xattrs"):
                    if a[field] != b[field]:
                        problems.append(f"{key}:{rel} {field} changed: {b[field]} -> {a[field]}")
            for rel in after:
                if rel in before:
                    continue
                if key == "documents" and (rel in allowed_new or rel.startswith("Exports/")):
                    if rel not in allowed_new:
                        problems.append(f"documents:{rel} unexpected new file in Exports/")
                    continue
                problems.append(f"{key}:{rel} new file (sidecar/temp next to the originals)")
        for name, b in baseline.get("parent_dirs", {}).items():
            a = now.get("parent_dirs", {}).get(name)
            if a is None:
                problems.append(f"{name} folder missing")
            elif a != b:
                problems.append(f"{name} folder changed: {b} -> {a}")
        report = {"ok": not problems, "checked": checked, "problems": problems, "allowedNew": allowed_new,
                  "documents_before": baseline["documents_path"], "documents_after": now["documents_path"]}
        (self.out / "compare.json").write_text(json.dumps(report, indent=1))
        return report

    # ---- handshake ------------------------------------------------------------------------------

    def serve_one(self, req: str) -> None:
        body = json.loads(self.read_shared(f"e2e_handshake/{req}"))
        seq, action, args = body["seq"], body["action"], body.get("args") or {}
        self.log(f"request #{seq} {action} {json.dumps(args)[:300]}")
        ok, detail, died = True, "", False
        try:
            if action == "kill":
                self.kill()
                died = True
            elif action == "screenshot":
                self.screenshot(args.get("name", "shot"))
            elif action == "backupAttrs":
                res = self.backup_attrs(args.get("paths", {}))
                (self.out / "backup-attrs.json").write_text(json.dumps(res, indent=1))
                self.write_shared("e2e_out/qa10-backup-attrs.json", json.dumps(res))
                detail = ", ".join(f"{k}={'excluded' if v['excluded'] else ('kept' if v['exists'] else 'absent')}" for k, v in res.items())
            elif action == "compareOriginals":
                res = self.compare(args.get("allowedNew", []))
                self.write_shared("e2e_out/qa10-originals-report.json", json.dumps(res))
                ok = res["ok"]
                detail = f"{res['checked']} files, {len(res['problems'])} problem(s)"
            elif action in ("foreground", "relaunch"):
                if self.platform == "ios":
                    self.sh("xcrun", "simctl", "launch", self.device, APP_ID)
            else:
                ok, detail = False, f"unknown action {action}"
        except Exception as e:  # noqa: BLE001 - reported to the app as a failed ack
            ok, detail = False, f"{type(e).__name__}: {e}"
        self.log(f"  -> ok={ok} {detail}")
        if not died:
            self.write_shared(f"e2e_handshake/ack-{seq}-{action}.json", json.dumps({"seq": seq, "ok": ok, "detail": detail}))
        try:
            self.move_shared(f"e2e_handshake/{req}", f"e2e_handshake/done-{req}")
        except OSError:
            pass
        if died:
            self.died = True

    # ---- phases ---------------------------------------------------------------------------------

    def build_probe(self):
        if self.platform != "ios":
            return None
        dylib = self.out / "fsync_probe.dylib"
        src = ROOT / "integration_test/editor_store/tool/fsync_probe.c"
        r = self.sh("xcrun", "--sdk", "iphonesimulator", "clang", "-dynamiclib", "-arch", "arm64",
                    "-mios-simulator-version-min=15.0", "-o", str(dylib), str(src))
        if r.returncode != 0:
            self.log(f"fsync probe build failed: {r.stderr}")
            return None
        self.sh("codesign", "-f", "-s", "-", str(dylib))
        return dylib

    def stage_host_media(self) -> None:
        if self.platform != "ios":
            return
        if self.host_dir.exists():
            shutil.rmtree(self.host_dir)
        (self.host_dir / "originals").mkdir(parents=True)
        (self.host_dir / "scratch").mkdir(parents=True)
        shutil.copy2(FIXTURES / "tone_under_video.mp4", self.host_dir / "originals")
        shutil.copy2(FIXTURES / "clap_flash_av.mp4", self.host_dir / "scratch")
        self.log(f"host media staged in {self.host_dir}")

    def defines(self, phase: str) -> list:
        d = ["DANAVIEW_EDITOR=true", "DV_E2E_HOST=true", f"DV_E2E_PHASE={phase}"]
        if self.platform == "ios":
            d += [f"DV_E2E_FIXTURES={FIXTURES}", f"DV_QA10_HOST_DIR={self.host_dir}"]
        return [f"--dart-define={x}" for x in d]

    def run_phase(self, phase: str, expect_death: bool, probe) -> bool:
        logf = self.out / "logs" / f"qa10-{phase}.log"
        env = dict(os.environ)
        if probe is not None:
            env["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = str(probe)
        cmd = ["flutter", "test", TEST, "-d", self.device, *self.defines(phase)]
        self.log(f"phase {phase}: {' '.join(cmd)}")
        self.died = False
        with open(logf, "w") as fh:
            proc = subprocess.Popen(cmd, cwd=ROOT, stdout=fh, stderr=subprocess.STDOUT, env=env, start_new_session=True)
            deadline = time.time() + self.timeout
            tick = 0
            while proc.poll() is None:
                tick += 1
                if tick % 20 == 0:
                    try:
                        self.collect()
                    except OSError:
                        pass
                for req in self.list_requests():
                    self.serve_one(req)
                    if self.died:
                        # The test that asked is gone; give flutter a moment, then stop it so it does
                        # not uninstall the app (and its container) on the way out.
                        time.sleep(3)
                        os.killpg(proc.pid, signal.SIGTERM)
                if time.time() > deadline:
                    self.log(f"TIMEOUT phase {phase} after {self.timeout}s")
                    os.killpg(proc.pid, signal.SIGTERM)
                    break
                time.sleep(0.3)
            proc.wait()
        if expect_death:
            ok = self.died
            self.log(f"phase {phase}: {'ended by the host kill as expected' if ok else 'FAILED (the app was not killed)'}")
            return ok
        ok = proc.returncode == 0
        self.log(f"phase {phase}: {'PASS' if ok else 'FAIL'} (exit {proc.returncode}, see {logf})")
        return ok

    def run(self, phases: list) -> int:
        probe = self.build_probe()
        if "seed" in phases:
            self.stage_host_media()
            if self.platform == "ios":
                self.sh("xcrun", "simctl", "uninstall", self.device, APP_ID)
            else:
                self.sh("adb", "-s", self.device, "uninstall", APP_ID)
            self.log("clean start: app uninstalled")
        results = {}
        for phase in phases:
            ok = self.run_phase(phase, expect_death=phase in ("seed", "edit"), probe=probe)
            results[phase] = ok
            if phase == "seed" and ok:
                snap = self.snapshot()
                (self.out / "baseline.json").write_text(json.dumps(snap, indent=1, sort_keys=True))
                self.log(f"baseline: {len(snap['documents']['files'])} Documents file(s), {len(snap['host']['files'])} host original(s)")
            if not ok:
                break
        try:
            self.collect()
        except OSError:
            pass
        lines = [f"{p}: {'pass' if ok else 'FAIL'}" for p, ok in results.items()]
        for f in sorted((self.out / "logs").glob("qa10-*.log")):
            lines += [l.rstrip() for l in f.read_text(errors="replace").splitlines() if "DV_QA10" in l]
        (self.out / "summary.txt").write_text("\n".join(lines) + "\n")
        self.log("summary:\n" + "\n".join(lines))
        return 0 if results and all(results.values()) and len(results) == len(phases) else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-p", "--platform", choices=["ios", "android"], required=True)
    ap.add_argument("-d", "--device", required=True)
    ap.add_argument("--timeout", type=int, default=int(os.environ.get("DV_E2E_PHASE_TIMEOUT", "1200")))
    ap.add_argument("command", choices=["run", "compare"])
    ap.add_argument("phase", nargs="?", default="all", choices=["all", "seed", "edit", "verify"])
    a = ap.parse_args()
    host = Host(a.platform, a.device, a.timeout)
    if a.command == "compare":
        print(json.dumps(host.compare([]), indent=1))
        return 0
    phases = ["seed", "edit", "verify"] if a.phase == "all" else [a.phase]
    return host.run(phases)


if __name__ == "__main__":
    sys.exit(main())
