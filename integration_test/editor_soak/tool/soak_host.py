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
  grantNotifications      Android: `pm grant ... POST_NOTIFICATIONS` (E2eExport.start asks for it);
                          iOS: nothing to grant (ok)
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
-d <serial> stage; ... stage-models <dir>), and pass the same models folder with -m so `death` can
stage them again after its uninstall.

Windows (Git Bash or cmd, QA-05 W1-W7): runs unmodified. `flutter` is started by its full path
(flutter.bat; override with DV_FLUTTER), phases run in a new process group and are stopped with
`taskkill /T`, `flutter test` gets --no-uninstall on Android (the next phase reads the app's state
and the staged files), `death` stages the fixtures and models again after its uninstall, the host
grants POST_NOTIFICATIONS once the app is installed and answers grantNotifications, and the 60 s
speech WAV of the captions death phase is built with ffmpeg (afconvert on macOS), pushed to
e2e_fixtures/ and passed as DV_SOAK_SPEECH60 with its device path.

  python -I integration_test/editor_soak/tool/soak_host.py -p android -d emulator-5554 -m C:/dev/models all

Self-test (no device; checks the commands built for both platforms and the 60 s WAV):

  python3 -I integration_test/editor_soak/tool/soak_host.py -p ios -d SELFTEST selftest

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
import wave
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
MODEL_FILES = ["ggml-tiny-q5_1.bin", "ggml-silero-v6.2.0.bin"]
SPEECH60 = "soak_speech_60s.wav"
IS_WINDOWS = os.name == "nt"


def flutter_executable() -> str:
    """W1: the full path of flutter (flutter.bat on Windows, which subprocess cannot start by its
    bare name). DV_FLUTTER overrides it."""
    override = os.environ.get("DV_FLUTTER", "")
    if override:
        return override
    for name in (("flutter.bat", "flutter.exe", "flutter") if IS_WINDOWS else ("flutter",)):
        found = shutil.which(name)
        if found:
            return found
    return "flutter"


def popen_group_kwargs() -> dict:
    """W2: a new process group for a phase, so stop() ends flutter and its children."""
    if IS_WINDOWS:
        return {"creationflags": getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x200)}
    return {"start_new_session": True}


class Host:
    def __init__(self, platform: str, device: str, models: str, timeout: int, out=None):
        self.platform = platform
        self.device = device
        self.models = models
        self.timeout = timeout
        self.out = Path(out) if out else ROOT / "build" / "soak" / platform / device
        for d in ("logs", "screens", "files"):
            (self.out / d).mkdir(parents=True, exist_ok=True)
        self.died = False
        self.kill_requested_at = 0.0
        self.crashes = []

    # ---- logging --------------------------------------------------------------------------------

    def log(self, msg: str) -> None:
        line = f"[soak_host {time.strftime('%H:%M:%S')}] {msg}"
        print(line, file=sys.stderr, flush=True)
        with open(self.out / "logs" / "host.log", "a", encoding="utf-8") as f:
            f.write(line + "\n")

    def sh(self, *cmd, timeout=120) -> subprocess.CompletedProcess:
        try:
            return subprocess.run(list(cmd), capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
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
        local.write_text(text, encoding="utf-8")
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

    def grant_notifications(self):
        """W5/W6: POST_NOTIFICATIONS, so an export on a fresh install never waits behind the
        system dialog. Android 12 and older have no such permission: that counts as granted."""
        if self.platform != "android":
            return True, "not needed on iOS"
        r = self.adb("shell", "pm", "grant", APP_ID, "android.permission.POST_NOTIFICATIONS")
        out = f"{r.stdout} {r.stderr}".strip()
        if r.returncode == 0:
            return True, "POST_NOTIFICATIONS granted"
        if "Unknown permission" in out or "not a changeable permission type" in out:
            return True, f"no POST_NOTIFICATIONS on this API level ({out[:120]})"
        return False, f"grant failed: {out[:200]}"

    def app_installed(self) -> bool:
        if self.platform != "android":
            return True
        return self.adb("shell", "pm", "path", APP_ID).returncode == 0

    def stage_android(self) -> None:
        """W4: pushes the fixtures (and, with -m, the models) to the app's shared folder; `adb
        uninstall` deletes Android/data/<app>/files with everything staged there."""
        self.adb("shell", "mkdir", "-p", f"{ANDROID_SHARED}/e2e_fixtures")
        n = 0
        for f in sorted(FIXTURES.iterdir()):
            if f.is_file():
                self.adb("push", str(f), f"{ANDROID_SHARED}/e2e_fixtures/", timeout=600)
                n += 1
        self.log(f"staged {n} fixtures to {ANDROID_SHARED}/e2e_fixtures")
        if not self.models:
            self.log("no -m models folder: the models were not staged again (the captions phase needs them)")
            return
        self.adb("shell", "mkdir", "-p", f"{ANDROID_SHARED}/e2e_models")
        for m in MODEL_FILES:
            src = Path(self.models) / m
            if src.is_file():
                self.adb("push", str(src), f"{ANDROID_SHARED}/e2e_models/", timeout=600)
            else:
                self.log(f"missing model {src}")
        self.log(f"staged the models to {ANDROID_SHARED}/e2e_models")

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
            elif action == "grantNotifications":
                ok, detail = self.grant_notifications()
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

    def speech_60s(self):
        """A 60 s speech WAV (speech_10s.m4a six times) for the captions death phase, so the job
        is still transcribing when the host kills it. macOS afconvert, else ffmpeg (W7); None when
        neither works."""
        target = self.out / SPEECH60
        if target.exists():
            return target
        tmp = self.out / "soak_speech_10s.wav"
        src = str(FIXTURES / "speech_10s.m4a")
        if shutil.which("afconvert"):
            r = self.sh("afconvert", "-f", "WAVE", "-d", "LEI16", src, str(tmp))
        elif shutil.which("ffmpeg"):
            r = self.sh("ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", src, "-c:a", "pcm_s16le", str(tmp))
        else:
            r = subprocess.CompletedProcess([], 127, "", "neither afconvert nor ffmpeg is on PATH")
        if r.returncode != 0:
            self.log(f"the 10 s WAV failed ({r.stderr.strip()}); the captions phase falls back to duplicated clips")
            return None
        with wave.open(str(tmp)) as src:
            params, frames = src.getparams(), src.readframes(src.getnframes())
        with wave.open(str(target), "wb") as dst:
            dst.setparams(params)
            for _ in range(6):
                dst.writeframes(frames)
        tmp.unlink()
        return target

    def speech_60s_on_device(self):
        """W7: the 60 s WAV pushed to e2e_fixtures/ on the Android device; its device path."""
        speech = self.speech_60s()
        if not speech:
            return None
        device_path = f"{ANDROID_SHARED}/e2e_fixtures/{SPEECH60}"
        self.adb("shell", "mkdir", "-p", f"{ANDROID_SHARED}/e2e_fixtures")
        r = self.adb("push", str(speech), device_path, timeout=300)
        if r.returncode != 0:
            self.log(f"pushing the 60 s WAV failed ({r.stderr.strip()}); the captions phase falls back to duplicated clips")
            return None
        return device_path

    def defines(self, phase: str, extra: list) -> list:
        d = ["DANAVIEW_EDITOR=true", "DANAVIEW_AUTO_CAPTIONS=true", "DV_E2E_HOST=true", f"DV_E2E_PHASE={phase}", *extra]
        if self.platform == "ios":
            d.append(f"DV_E2E_FIXTURES={FIXTURES}")
            if self.models:
                d.append(f"DV_E2E_MODELS={self.models}")
        if phase == "die-captions":
            speech = self.speech_60s() if self.platform == "ios" else self.speech_60s_on_device()
            if speech:
                d.append(f"DV_SOAK_SPEECH60={speech}")
        return [f"--dart-define={x}" for x in d]

    def flutter_test_cmd(self, test: str, phase: str, extra: list) -> list:
        cmd = [flutter_executable(), "test", test, "-d", self.device]
        if self.platform == "android":
            # W3: without it flutter uninstalls the app after each phase, which deletes the staged
            # fixtures and models and the state the next death phase reads.
            cmd.append("--no-uninstall")
        return [*cmd, *self.defines(phase, extra)]

    @staticmethod
    def stop(proc: subprocess.Popen) -> None:
        if proc.poll() is not None:
            return
        if IS_WINDOWS:
            # W2: no os.killpg on Windows; end the whole tree (flutter.bat, dart, adb children).
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(proc.pid)], capture_output=True)
            return
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except (OSError, AttributeError):
            proc.terminate()

    def run_phase(self, test: str, phase: str, expect_death: bool, extra=(), sample_memory=False, timeout=None) -> bool:
        logf = self.out / "logs" / f"{Path(test).stem}-{phase or 'run'}.log"
        cmd = self.flutter_test_cmd(test, phase, list(extra))
        self.log(f"phase {phase}: {' '.join(cmd)}")
        self.died = False
        limit = timeout or self.timeout
        mem = open(self.out / "memory-host.csv", "a") if sample_memory else None
        if mem:
            mem.write("epoch_s,pid,bytes\n")
        last_pid, last_sample = None, 0.0
        with open(logf, "w") as fh:
            proc = subprocess.Popen(cmd, cwd=ROOT, stdout=fh, stderr=subprocess.STDOUT, **popen_group_kwargs())
            deadline = time.time() + limit
            tick = 0
            granted = self.platform != "android"
            while proc.poll() is None:
                tick += 1
                if not granted and tick % 10 == 0 and self.app_installed():
                    # W6: the soak's own exports never ask the host, so grant once it is installed.
                    granted = True
                    ok_grant, detail = self.grant_notifications()
                    self.log(f"phase {phase}: {'' if ok_grant else 'WARNING '}{detail}")
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
        text = logf.read_text(encoding="utf-8", errors="replace")
        for line in text.splitlines():
            if "DV_SOAK summary " in line:
                (self.out / "files" / "soak-summary-log.json").write_text(line.split("DV_SOAK summary ", 1)[1])
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

    def death_lines(self) -> list:
        lines = []
        for job in [*DEATH_JOBS, "verify"]:
            f = self.out / "logs" / f"process_death_test-{'verify' if job == 'verify' else 'die-' + job}.log"
            if f.exists():
                lines += [l.strip() for l in f.read_text(encoding="utf-8", errors="replace").splitlines() if "DV_SOAK death" in l]
        (self.out / "death-results.txt").write_text("\n".join(lines) + "\n")
        return lines

    def death(self, jobs=None) -> bool:
        if self.platform == "ios":
            self.sh("xcrun", "simctl", "uninstall", self.device, APP_ID)
        else:
            self.adb("uninstall", APP_ID)
        self.log("clean start: app uninstalled")
        if self.platform == "android":
            self.stage_android()
        results = {}
        for log in (self.out / "logs").glob("process_death_test-*.log"):
            log.unlink()
        for job in jobs or DEATH_JOBS:
            ok = self.run_phase(DEATH_TEST, f"die-{job}", expect_death=True, timeout=1800)
            results[f"die-{job}"] = ok
            if not ok:
                break
        extra = [f"DV_SOAK_JOBS={','.join(jobs)}"] if jobs else []
        results["verify"] = self.run_phase(DEATH_TEST, "verify", expect_death=False, extra=extra, timeout=1800)
        for line in self.death_lines():
            self.log(line)
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
        with open(self.out / "summary.txt", "a", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        self.log("\n".join(lines))


def selftest() -> int:
    """No device: checks the commands the host builds on iOS and Android (Windows simulated for
    W1/W2), the staging after death()'s uninstall (W4), the grants (W5/W6) and the real 60 s WAV
    (W7, with afconvert or ffmpeg on this machine)."""
    import tempfile

    global IS_WINDOWS
    failures = []

    def check(cond, what):
        print(f"  {'ok  ' if cond else 'FAIL'} {what}")
        if not cond:
            failures.append(what)

    class Recorder(Host):
        def __init__(self, platform, out, models=""):
            super().__init__(platform, "emulator-5554" if platform == "android" else "SIM-UDID", models, 60, out=out)
            self.calls = []

        def sh(self, *cmd, timeout=120):
            if cmd and cmd[0] in ("afconvert", "ffmpeg"):
                return Host.sh(self, *cmd, timeout=timeout)
            self.calls.append(list(cmd))
            return subprocess.CompletedProcess(list(cmd), 0, "", "")

    with tempfile.TemporaryDirectory() as tmp:
        models = Path(tmp) / "models"
        models.mkdir()
        for m in MODEL_FILES:
            (models / m).write_bytes(b"x")

        print("iOS")
        ios = Recorder("ios", Path(tmp) / "ios", models=str(models))
        cmd = ios.flutter_test_cmd(DEATH_TEST, "die-captions", [])
        check(Path(cmd[0]).name.startswith("flutter"), f"flutter by path: {cmd[0]}")
        check("--no-uninstall" not in cmd, "no --no-uninstall on iOS")
        check(f"--dart-define=DV_E2E_FIXTURES={FIXTURES}" in cmd, "DV_E2E_FIXTURES on iOS")
        check(f"--dart-define=DV_E2E_MODELS={models}" in cmd, "DV_E2E_MODELS on iOS")
        speech = [c for c in cmd if c.startswith("--dart-define=DV_SOAK_SPEECH60=")]
        check(len(speech) == 1 and Path(speech[0].split("=", 2)[2]).is_file(), "DV_SOAK_SPEECH60 is a local WAV on iOS")
        if speech:
            with wave.open(speech[0].split("=", 2)[2]) as w:
                seconds = w.getnframes() / w.getframerate()
            check(59 <= seconds <= 61, f"the speech WAV is 60 s ({seconds:.1f} s)")
        check(ios.grant_notifications()[0] and not ios.calls, "grantNotifications: ok, nothing to run on iOS")
        check(popen_group_kwargs() == {"start_new_session": True}, "a new session on POSIX")

        print("Android")
        an = Recorder("android", Path(tmp) / "android", models=str(models))
        cmd = an.flutter_test_cmd(DEATH_TEST, "die-captions", [])
        check("--no-uninstall" in cmd, "W3 --no-uninstall on Android")
        check(not any("DV_E2E_FIXTURES" in c for c in cmd), "no host fixture path on Android")
        check(f"--dart-define=DV_SOAK_SPEECH60={ANDROID_SHARED}/e2e_fixtures/{SPEECH60}" in cmd, "W7 DV_SOAK_SPEECH60 is the device path")
        check(any(c[:4] == ["adb", "-s", "emulator-5554", "push"] and c[-1].endswith(f"e2e_fixtures/{SPEECH60}") for c in an.calls), "W7 the WAV is pushed")
        an.calls.clear()
        an.run_phase = lambda *a, **k: True
        an.death_lines = lambda: []
        an.death(["autosave"])
        uninstall = next((i for i, c in enumerate(an.calls) if "uninstall" in c), None)
        pushes = [c for c in an.calls if "push" in c]
        check(uninstall is not None and pushes and an.calls.index(pushes[0]) > uninstall, "W4 restaged after the uninstall")
        check(sum(1 for c in pushes if "e2e_models/" in c[-1]) == len(MODEL_FILES), "W4 the models are pushed again")
        check(sum(1 for c in pushes if "e2e_fixtures/" in c[-1]) == sum(1 for f in FIXTURES.iterdir() if f.is_file()), "W4 every fixture is pushed again")
        an.calls.clear()
        ok, detail = an.grant_notifications()
        check(ok and an.calls == [["adb", "-s", "emulator-5554", "shell", "pm", "grant", APP_ID, "android.permission.POST_NOTIFICATIONS"]], f"W5/W6 pm grant ({detail})")

        print("Windows (simulated)")
        saved, saved_which, saved_run = IS_WINDOWS, shutil.which, subprocess.run
        try:
            IS_WINDOWS = True
            shutil.which = lambda name: r"C:\dev\flutter\bin\flutter.bat" if name == "flutter.bat" else None
            check(flutter_executable().endswith("flutter.bat"), "W1 flutter.bat by its full path")
            check("creationflags" in popen_group_kwargs(), "W2 CREATE_NEW_PROCESS_GROUP")
            killed = []
            subprocess.run = lambda cmd, **k: killed.append(cmd)

            class Proc:
                pid = 4242

                @staticmethod
                def poll():
                    return None

            Host.stop(Proc())
            check(killed == [["taskkill", "/F", "/T", "/PID", "4242"]], "W2 taskkill /T instead of os.killpg")
        finally:
            IS_WINDOWS, shutil.which, subprocess.run = saved, saved_which, saved_run
    print("selftest: " + ("PASS" if not failures else f"FAIL ({len(failures)})"))
    return 0 if not failures else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-p", "--platform", choices=["ios", "android"], required=True)
    ap.add_argument("-d", "--device", required=True)
    ap.add_argument("-m", "--models", default=os.environ.get("DV_E2E_MODELS_DIR", ""), help="folder with the tiny model and VAD (iOS)")
    ap.add_argument("--phase-timeout", type=int, default=3600)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("selftest", help="no device: checks the commands the host builds (iOS, Android, Windows)")
    s = sub.add_parser("soak")
    s.add_argument("--minutes", type=int, default=60)
    s.add_argument("--seed", type=int, default=0)
    s.add_argument("--no-captions", action="store_true")
    dp = sub.add_parser("death")
    dp.add_argument("--jobs", default="", help="comma-separated subset of " + ",".join(DEATH_JOBS))
    a = sub.add_parser("all")
    a.add_argument("--minutes", type=int, default=60)
    a.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()
    if args.cmd == "selftest":
        return selftest()
    host = Host(args.platform, args.device, os.path.expanduser(args.models) if args.models else "", args.phase_timeout)
    if args.cmd == "soak":
        return 0 if host.soak(args.minutes, args.seed, not args.no_captions) else 1
    if args.cmd == "death":
        return 0 if host.death([j for j in args.jobs.split(",") if j] or None) else 1
    ok = host.death()
    ok = host.soak(args.minutes, args.seed, True) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
