#!/usr/bin/env python3
# OWNER: QA-05
"""Host driver of the QA-05 robustness soak (integration_test/editor_soak).

It runs the soak files against one simulator / emulator / device and serves the file handshake of
the shared E2E suite (integration_test/editor/support/e2e_handshake.dart, same protocol as QA-00's
e2e_host.sh) for what an app cannot do to itself:

  kill                    kill the app (no ack: the phase ends there)
  background {seconds}    send the app to the background, wait, bring it back
  call {seconds}          Android emulator: a real incoming GSM call (`adb emu gsm call`), then
                          hang up. iOS Simulator: no telephony -> ok=false, and the app simulates
                          the inactive -> resumed lifecycle a call banner or Siri produces.
  audioRoute              no scriptable route change on a simulator or emulator -> ok=false (the
                          wired/Bluetooth route change is a device step, see the report)
  lowStorage {leaveMb}    Android: fill /data with a placeholder file until leaveMb MB are left.
                          iOS Simulator: refused (ok=false). The simulator's container lives on the
                          Mac's own disk, and filling it would starve the Mac and the other builders.
  freeStorage             delete the placeholder file
  screenshot {name}       evidence screenshot

Commands:

  soak [--minutes N] [--seed S] [--no-captions]
          runs soak_test.dart. While it runs the host samples the app process from outside every
          30 s (iOS: `ps` RSS of the simulator process; Android: `dumpsys meminfo` total PSS) into
          memory-host.csv. A process that vanishes outside a requested kill is reported as a crash.
  death   runs process_death_test.dart. It starts with an uninstall (a clean start), then runs
          die-autosave, die-proxy, die-reverse, die-freeze, die-export, die-captions (each killed
          by the host mid-job) and verify.
  all     death, then soak

  python3 -I integration_test/editor_soak/tool/soak_host.py -p ios -d <udid> -m ~/danaview-models soak --minutes 60
  python3 -I integration_test/editor_soak/tool/soak_host.py -p ios -d <udid> -m ~/danaview-models death
  python3 -I integration_test/editor_soak/tool/soak_host.py -p android -d emulator-5554 all

Android: stage the fixtures and models first (integration_test/editor/tool/e2e_host.sh -p android
-d <serial> stage; ... stage-models <dir>).

Evidence: build/soak/<platform>/<device>/ (logs/, screens/, files/ with soak-summary.json and
soak-death.json, memory-host.csv, summary.txt).
"""

import argparse
import json
import os
import signal
import shutil
import subprocess
import sys
import time
from pathlib import Path

APP_ID = "com.vecvel.danaview"
ANDROID_ACTIVITY = f"{APP_ID}/.MainActivity"
ROOT = Path(__file__).resolve().parents[3]
SOAK_TEST = "integration_test/editor_soak/soak_test.dart"
DEATH_TEST = "integration_test/editor_soak/process_death_test.dart"
FIXTURES = ROOT / "packages/danaview_editor_engine/test_fixtures/media"
ANDROID_SHARED = f"/sdcard/Android/data/{APP_ID}/files"
ANDROID_FILL = "/data/local/tmp/danaview_soak_fill"
DEATH_JOBS = ["autosave", "proxy", "reverse", "freeze", "export", "captions"]
GSM_NUMBER = "5551234"


class Host:
    def __init__(self, platform: str, device: str, models: str, timeout: int):
        self.platform = platform
        self.device = device
        self.models = models
        self.timeout = timeout
        self.out = ROOT / "build" / "soak" / platform / device
        for d in ("logs", "screens", "files"):
            (self.out / d).mkdir(parents=True, exist_ok=True)
        self.died = False
        self.kill_requested_at = 0.0
        self.crashes = []

    # ---- logging --------------------------------------------------------------------------------

    def log(self, msg: str) -> None:
        line = f"[soak_host {time.strftime('%H:%M:%S')}] {msg}"
        print(line, file=sys.stderr, flush=True)
        with open(self.out / "logs" / "host.log", "a") as f:
            f.write(line + "\n")

    def sh(self, *cmd, timeout=120) -> subprocess.CompletedProcess:
        try:
            return subprocess.run(list(cmd), capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired as e:
            return subprocess.CompletedProcess(list(cmd), 124, e.stdout or "", e.stderr or "timeout")

    def adb(self, *args, timeout=120) -> subprocess.CompletedProcess:
        return self.sh("adb", "-s", self.device, *args, timeout=timeout)

    # ---- device file access ---------------------------------------------------------------------

    def shared(self):
        if self.platform == "ios":
            r = self.sh("xcrun", "simctl", "get_app_container", self.device, APP_ID, "data")
            p = r.stdout.strip()
            return (Path(p) / "Documents") if r.returncode == 0 and p else None
        return ANDROID_SHARED

    def list_requests(self):
        if self.platform == "ios":
            d = self.shared()
            if not d or not (d / "e2e_handshake").is_dir():
                return []
            return sorted(p.name for p in (d / "e2e_handshake").glob("req-*.json"))
        r = self.adb("shell", f"ls {ANDROID_SHARED}/e2e_handshake/ 2>/dev/null")
        return sorted(n.strip() for n in r.stdout.splitlines() if n.strip().startswith("req-") and n.strip().endswith(".json"))

    def read_shared(self, rel: str) -> str:
        if self.platform == "ios":
            return (self.shared() / rel).read_text()
        return self.adb("shell", f"cat {ANDROID_SHARED}/{rel}").stdout

    def write_shared(self, rel: str, text: str) -> None:
        if self.platform == "ios":
            target = self.shared() / rel
            tmp = target.with_name(target.name + ".tmp")
            tmp.write_text(text)
            tmp.rename(target)
            return
        local = self.out / "files" / ".push.tmp"
        local.write_text(text)
        self.adb("push", str(local), f"{ANDROID_SHARED}/{rel}.tmp")
        self.adb("shell", f"mv {ANDROID_SHARED}/{rel}.tmp {ANDROID_SHARED}/{rel}")

    def move_shared(self, a: str, b: str) -> None:
        if self.platform == "ios":
            (self.shared() / a).rename(self.shared() / b)
        else:
            self.adb("shell", f"mv {ANDROID_SHARED}/{a} {ANDROID_SHARED}/{b}")

    def collect(self) -> None:
        if self.platform == "ios":
            d = self.shared()
            if d and (d / "e2e_out").is_dir():
                for f in (d / "e2e_out").glob("soak-*.json"):
                    shutil.copy2(f, self.out / "files" / f.name)
                for f in (d / "e2e_out").glob("state-soak-*.json"):
                    shutil.copy2(f, self.out / "files" / f.name)
        else:
            for name in ("soak-summary.json", "soak-death.json", "state-soak-death-results.json"):
                self.adb("pull", f"{ANDROID_SHARED}/e2e_out/{name}", str(self.out / "files" / name))

    # ---- the app process ------------------------------------------------------------------------

    def app_pid(self):
        if self.platform == "ios":
            r = self.sh("ps", "-axo", "pid=,rss=,command=")
            for line in r.stdout.splitlines():
                if self.device in line and "/Runner.app/Runner" in line:
                    parts = line.split(None, 2)
                    return int(parts[0]), int(parts[1]) * 1024
            return None
        r = self.adb("shell", "pidof", APP_ID)
        pid = r.stdout.strip().split()
        if not pid:
            return None
        m = self.adb("shell", "dumpsys", "meminfo", "--short", APP_ID, timeout=60).stdout
        pss = 0
        for line in m.splitlines():
            if line.strip().startswith("TOTAL"):
                try:
                    pss = int(line.split()[1]) * 1024
                except (IndexError, ValueError):
                    pass
                break
        return int(pid[0]), pss

    # ---- actions --------------------------------------------------------------------------------

    def kill(self) -> None:
        self.kill_requested_at = time.time()
        if self.platform == "ios":
            self.sh("xcrun", "simctl", "terminate", self.device, APP_ID)
        else:
            self.adb("shell", "am", "force-stop", APP_ID)

    def foreground(self) -> None:
        if self.platform == "ios":
            self.sh("xcrun", "simctl", "launch", self.device, APP_ID)
        else:
            self.adb("shell", "am", "start", "-n", ANDROID_ACTIVITY)

    def background(self, seconds: float) -> str:
        if self.platform == "ios":
            self.sh("xcrun", "simctl", "launch", self.device, "com.apple.Preferences")
        else:
            self.adb("shell", "input", "keyevent", "KEYCODE_HOME")
        time.sleep(seconds)
        self.foreground()
        time.sleep(0.5)
        return f"background {seconds}s"

    def call(self, seconds: float):
        if self.platform != "android":
            return False, "no telephony on the iOS Simulator (the app simulates inactive -> resumed)"
        r = self.adb("emu", "gsm", "call", GSM_NUMBER)
        if r.returncode != 0 or "KO" in r.stdout:
            return False, f"adb emu gsm call failed: {r.stdout.strip()} {r.stderr.strip()} (a real device: place a call by hand)"
        time.sleep(seconds)
        self.adb("emu", "gsm", "cancel", GSM_NUMBER)
        time.sleep(1)
        self.foreground()
        return True, f"GSM call {seconds}s"

    def low_storage(self, leave_mb: int):
        if self.platform != "android":
            return False, "refused on the iOS Simulator: its container is on the Mac's disk (device step)"
        df = self.adb("shell", "df", "-k", "/data").stdout.splitlines()
        try:
            avail_kb = int(df[-1].split()[3])
        except (IndexError, ValueError):
            return False, f"cannot read df: {df}"
        fill_kb = avail_kb - leave_mb * 1024
        if fill_kb <= 0:
            return True, f"already below {leave_mb} MB free ({avail_kb // 1024} MB)"
        r = self.adb("shell", "fallocate", "-l", f"{fill_kb}K", ANDROID_FILL, timeout=300)
        if r.returncode != 0:
            r = self.adb("shell", f"dd if=/dev/zero of={ANDROID_FILL} bs=1048576 count={fill_kb // 1024}", timeout=600)
        after = self.adb("shell", "df", "-k", "/data").stdout.splitlines()
        return True, f"filled {fill_kb // 1024} MB; free now {int(after[-1].split()[3]) // 1024} MB"

    def free_storage(self):
        if self.platform != "android":
            return True, "nothing to free"
        self.adb("shell", "rm", "-f", ANDROID_FILL)
        return True, "placeholder removed"

    def screenshot(self, name: str) -> None:
        f = self.out / "screens" / f"{time.strftime('%H%M%S')}-{name}.png"
        if self.platform == "ios":
            self.sh("xcrun", "simctl", "io", self.device, "screenshot", str(f))
        else:
            with open(f, "wb") as fh:
                subprocess.run(["adb", "-s", self.device, "exec-out", "screencap", "-p"], stdout=fh)
        self.log(f"screenshot {f.name}")

    # ---- handshake ------------------------------------------------------------------------------

    def serve_one(self, req: str) -> None:
        body = json.loads(self.read_shared(f"e2e_handshake/{req}"))
        seq, action, args = body["seq"], body["action"], body.get("args") or {}
        self.log(f"request #{seq} {action} {json.dumps(args)[:200]}")
        ok, detail, died = True, "", False
        try:
            if action == "kill":
                self.kill()
                died = True
            elif action == "background":
                detail = self.background(float(args.get("seconds", 3)))
            elif action == "call":
                ok, detail = self.call(float(args.get("seconds", 3)))
            elif action == "audioRoute":
                ok, detail = False, "no scriptable audio route change on a simulator/emulator (device step)"
            elif action == "lowStorage":
                ok, detail = self.low_storage(int(args.get("leaveMb", 200)))
            elif action == "freeStorage":
                ok, detail = self.free_storage()
            elif action == "screenshot":
                self.screenshot(args.get("name", "shot"))
            elif action in ("foreground", "relaunch"):
                self.foreground()
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

    def defines(self, phase: str, extra: list) -> list:
        d = ["DANAVIEW_EDITOR=true", "DANAVIEW_AUTO_CAPTIONS=true", "DV_E2E_HOST=true", f"DV_E2E_PHASE={phase}", *extra]
        if self.platform == "ios":
            d.append(f"DV_E2E_FIXTURES={FIXTURES}")
            if self.models:
                d.append(f"DV_E2E_MODELS={self.models}")
        return [f"--dart-define={x}" for x in d]

    @staticmethod
    def stop(proc: subprocess.Popen) -> None:
        if proc.poll() is not None:
            return
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except OSError:
            proc.terminate()

    def run_phase(self, test: str, phase: str, expect_death: bool, extra=(), sample_memory=False, timeout=None) -> bool:
        logf = self.out / "logs" / f"{Path(test).stem}-{phase or 'run'}.log"
        cmd = ["flutter", "test", test, "-d", self.device, *self.defines(phase, list(extra))]
        self.log(f"phase {phase}: {' '.join(cmd)}")
        self.died = False
        limit = timeout or self.timeout
        mem = open(self.out / "memory-host.csv", "a") if sample_memory else None
        if mem:
            mem.write("epoch_s,pid,bytes\n")
        last_pid, last_sample = None, 0.0
        with open(logf, "w") as fh:
            proc = subprocess.Popen(cmd, cwd=ROOT, stdout=fh, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.time() + limit
            tick = 0
            while proc.poll() is None:
                tick += 1
                if tick % 30 == 0:
                    try:
                        self.collect()
                    except OSError:
                        pass
                if sample_memory and time.time() - last_sample >= 30:
                    last_sample = time.time()
                    got = self.app_pid()
                    if got:
                        pid, size = got
                        if last_pid is not None and pid != last_pid and time.time() - self.kill_requested_at > 60:
                            self.crashes.append(f"app pid changed {last_pid} -> {pid} without a requested kill")
                            self.log(f"CRASH? {self.crashes[-1]}")
                        last_pid = pid
                        mem.write(f"{int(time.time())},{pid},{size}\n")
                        mem.flush()
                for req in self.list_requests():
                    self.serve_one(req)
                    if self.died:
                        # The test that asked is gone: stop flutter so it does not uninstall the app.
                        time.sleep(3)
                        self.stop(proc)
                if time.time() > deadline:
                    self.log(f"TIMEOUT phase {phase} after {limit}s")
                    self.stop(proc)
                    break
                time.sleep(0.3)
            proc.wait()
        if mem:
            mem.close()
        try:
            self.collect()
        except OSError:
            pass
        text = logf.read_text(errors="replace")
        for marker in ("Lost connection to device", "Service protocol connection closed"):
            if marker in text and not self.died:
                self.crashes.append(f"{phase}: '{marker}' in the log")
        if expect_death:
            ok = self.died
            self.log(f"phase {phase}: {'killed by the host as requested' if ok else 'FAILED (the app was not killed)'}")
            return ok
        ok = proc.returncode == 0
        self.log(f"phase {phase}: {'PASS' if ok else 'FAIL'} (exit {proc.returncode}, see {logf.name})")
        return ok

    def death(self) -> bool:
        if self.platform == "ios":
            self.sh("xcrun", "simctl", "uninstall", self.device, APP_ID)
        else:
            self.adb("uninstall", APP_ID)
        self.log("clean start: app uninstalled")
        results = {}
        for job in DEATH_JOBS:
            ok = self.run_phase(DEATH_TEST, f"die-{job}", expect_death=True, timeout=1800)
            results[f"die-{job}"] = ok
            if not ok:
                break
        results["verify"] = self.run_phase(DEATH_TEST, "verify", expect_death=False, timeout=1800)
        self.summary("death", results)
        return all(results.values())

    def soak(self, minutes: int, seed: int, captions: bool) -> bool:
        extra = [f"DV_SOAK_MINUTES={minutes}"]
        if seed:
            extra.append(f"DV_SOAK_SEED={seed}")
        if not captions:
            extra.append("DV_SOAK_CAPTIONS=false")
        if self.platform == "android":
            self.free_storage()
        ok = self.run_phase(SOAK_TEST, "soak", expect_death=False, extra=extra, sample_memory=True, timeout=(minutes + 60) * 60)
        if self.platform == "android":
            self.free_storage()
        self.summary("soak", {"soak": ok})
        return ok and not self.crashes

    def summary(self, what: str, results: dict) -> None:
        lines = [f"{what} {time.strftime('%Y-%m-%d %H:%M')} {self.platform} {self.device}"]
        lines += [f"  {k}: {'ok' if v else 'FAIL'}" for k, v in results.items()]
        lines += [f"  crash: {c}" for c in self.crashes]
        for name in ("soak-summary.json", "soak-death.json"):
            f = self.out / "files" / name
            if f.exists():
                lines.append(f"  {name}: {f}")
        with open(self.out / "summary.txt", "a") as fh:
            fh.write("\n".join(lines) + "\n")
        self.log("\n".join(lines))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-p", "--platform", choices=["ios", "android"], required=True)
    ap.add_argument("-d", "--device", required=True)
    ap.add_argument("-m", "--models", default=os.environ.get("DV_E2E_MODELS_DIR", ""), help="folder with the tiny model and VAD (iOS)")
    ap.add_argument("--phase-timeout", type=int, default=3600)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("soak")
    s.add_argument("--minutes", type=int, default=60)
    s.add_argument("--seed", type=int, default=0)
    s.add_argument("--no-captions", action="store_true")
    sub.add_parser("death")
    a = sub.add_parser("all")
    a.add_argument("--minutes", type=int, default=60)
    a.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()
    host = Host(args.platform, args.device, os.path.expanduser(args.models) if args.models else "", args.phase_timeout)
    if args.cmd == "soak":
        return 0 if host.soak(args.minutes, args.seed, not args.no_captions) else 1
    if args.cmd == "death":
        return 0 if host.death() else 1
    ok = host.death()
    ok = host.soak(args.minutes, args.seed, True) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
