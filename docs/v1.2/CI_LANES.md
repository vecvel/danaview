# CI lanes

<!-- OWNER: INT-01 (CI round 6, 2026-10-29) -->

CI runs in two lanes. The **gate** must always be green and blocks merges. The **device lane**
runs at night, reports failures and never blocks. The split moves tests between lanes; it does
not delete or skip any. Neither lane sets `DV_PERF_STRICT`, so timing limits run in their loose
mode (BUILD_STATE.md, "DV_PERF_STRICT").

## Gate: `.github/workflows/danaview-ci.yml`

Runs on pull requests and pushes to `main` (path-filtered), and on manual dispatch. Every job is
deterministic on a shared hosted runner.

| Job | What |
|---|---|
| `actionlint` | actionlint + shellcheck on both CI workflows and `android-internal.yml` |
| `dart-core`, `dart-core-benchmark` | editor_core tests and JSON goldens; benchmark rows gate regressions against a same-run host factor, not absolute budgets |
| `ai-dart`, `flutter-packages` | AI packages; Flutter packages with their macOS goldens |
| `v12-dart`, `v12-flutter` | 1.2.0 library, search and core photo; documents, features and face tracking (macOS goldens) |
| `home-preservation (HOM-15 merge gate)` | Home preservation (macOS goldens) |
| `whisper-host (linux, linux-tsan, linux-asan, macos)` | whisper.cpp host tests, plain and sanitized |
| `android-unit` | JVM unit tests |
| `ios (Xcode 26.6, iOS 26 simulator)` | RunnerTests on the simulator, **except** the classes in `scripts/ci/editor/ios_device_lane_classes.txt` (passed as `-skip-testing`) |
| `gate` | Fails when any job above failed or was cancelled. Jobs skipped by a pull request's path filters count as passed. |

**Branch protection:** require the single check `gate`. Adding or renaming a gate job then only
changes `gate`'s `needs:` list, not the protection rule.

## Device lane: `.github/workflows/danaview-device.yml`

Runs at 02:30 UTC and on manual dispatch. These suites depend on the runner, not only on the code:
the Android emulator's software GPU and encoder, AVFoundation on the iOS simulator, long soak runs.

| Job | What |
|---|---|
| `android-emulator (API 35 x86_64)` | `android_emulator.sh`: instrumented batches and device suites |
| `ios-soak` | Only the RunnerTests classes in `ios_device_lane_classes.txt` (`-only-testing`) |
| `ios-device` | Release device build, the D-41 `check_ios_min_os.sh` on the built app, then every integration_test suite (smoke, ios_preview, accuracy, av_sync, parity, conformance, preset_matrix, audio_mix) |
| `nightly` | `nightly.sh`: core fuzz, full overflow matrix, AI eval |
| `report` | Updates the `ci-nightly` issue (see below) |

### Moving a RunnerTests class between lanes

`scripts/ci/editor/ios_device_lane_classes.txt` is the only list. `ios.sh` reads it:
`DANAVIEW_IOS_RUNNER_LANE=gate` skips those classes, and `=device` runs only those classes. Add a
class only if it is a soak or perf-heavy class whose result on a shared simulator depends on
AVFoundation or the runner's load. Right now the file lists `ExportD7Tests`, `ExportStallTests`
and `KernelTimingTests`.

## Running the device lane by hand

These dispatches run on the given branch. Once `danaview-device.yml` is on `main`:

```sh
gh workflow run danaview-device.yml --ref <branch>
# a subset:
gh workflow run danaview-device.yml --ref <branch> -f android_emulator=false -f nightly=false
```

Before then, or to run the lane together with the gate, use the gate's `device_lane` input. That
input calls the device workflow from the branch:

```sh
gh workflow run danaview-ci.yml --ref <branch> -f device_lane=true
```

A dispatch does not touch the issue unless you pass `-f report_issue=true`, which works on
`danaview-device.yml` only.

## The nightly issue

After a scheduled run, the `report` job looks for the one open issue labelled `ci-nightly`:

- **When a job failed or was cancelled:** it comments on that issue with the failing jobs and the
  run link. If no such issue is open, it creates "Nightly device lane failing" and adds the label.
- **When the run is green:** it closes the open issue with a link to the green run.

Only the `report` job has `issues: write`. It uses `gh` with the run's `GITHUB_TOKEN`. When the gate
calls the device lane, the gate's calling job must grant the same permission, because a called
workflow can't ask for more than its caller. In that case `report_issue` is false, so the call never
touches the issue.

## Strict mode on real devices

Absolute budgets, such as timing, frame count and the ±25 % export bitrate, apply only with
`DV_PERF_STRICT=1`, on a quiet Mac or a real device. CI never sets it. The commands are in
[BUILD_STATE.md](BUILD_STATE.md), in the "DV_PERF_STRICT on Android" and "DV_PERF_STRICT on iOS,
macOS and the Dart tests" items:

- Android device: `DV_PERF_STRICT=1 ANDROID_SERIAL=<serial> bash scripts/ci/editor/android_emulator.sh`
- iOS RunnerTests and suites, on a quiet Mac: `DV_PERF_STRICT=1 bash scripts/ci/editor/ios.sh`
  (`DANAVIEW_IOS_SIMULATOR=<name or udid>` picks the simulator)
- Host Dart tests: `DV_PERF_STRICT=1 flutter test …`
