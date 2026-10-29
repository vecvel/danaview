# Danaview CI scripts (editor jobs)

<!-- OWNER: INT-01 -->

CI has two lanes (docs/v1.2/CI_LANES.md): the required gate `.github/workflows/danaview-ci.yml` (ARCH §22) and the non-blocking nightly device lane `.github/workflows/danaview-device.yml`. They run one job per script in this directory. Each job checks out the repo, looks for its script and runs it with `bash`. If the script doesn't exist yet, the job prints a skip notice and passes. The ticket that owns a script creates it. Every script also runs locally with the same command.

## Jobs, scripts and owners

| Job | Runner | Script | Owner | Runs on |
|---|---|---|---|---|
| `workflow-lint` | ubuntu-latest | (inline) actionlint 1.7.7 + shellcheck on `danaview-ci.yml`, `danaview-device.yml` | INT-01 | PR, push |
| `dart-core` | GitHub-hosted `macos-26` (JSON goldens carry arm64 float results) | `core.sh test` | CORE-01 | PR, push |
| `dart-core-benchmark` | ubuntu-latest (steady timings; the gate is host-normalized to the dev-Mac baseline) | `core.sh benchmark` | CORE-35 | PR, push |
| `flutter-packages` | GitHub-hosted `macos-26` (goldens are rendered on macOS) | `flutter_packages.sh` | INT-01 | PR, push |
| `whisper-host` | ubuntu-latest (plain, TSan, ASan) + GitHub-hosted `macos-26` | `whisper_host.sh` | AI-03 | PR, push |
| `android-unit` | ubuntu-latest | `android_unit.sh` | ENG-09 | PR, push |
| `ios` | GitHub-hosted `macos-26` (Xcode 26.6, iOS 26.5 simulator) | `ios.sh --no-device-build --runner-tests-only` with `DANAVIEW_IOS_RUNNER_LANE=gate` (RunnerTests minus `ios_device_lane_classes.txt`) | ENG-09 | PR, push, dispatch |
| `gate` | ubuntu-latest | (inline) fails when any job above failed; the one required check | INT-01 | PR, push, dispatch |
| `android-emulator` (device lane) | ubuntu-latest, KVM, API 35 x86_64 (`reactivecircus/android-emulator-runner`) | `android_emulator.sh` | ENG-09 | cron 02:30 UTC, dispatch |
| `ios-soak` (device lane) | GitHub-hosted `macos-26` | `ios.sh --no-device-build --runner-tests-only` with `DANAVIEW_IOS_RUNNER_LANE=device` | ENG-09 | cron 02:30 UTC, dispatch |
| `ios-device` (device lane) | GitHub-hosted `macos-26` | `ios.sh --no-runner-tests` (device build, D-41 check, every integration_test suite) | ENG-09 | cron 02:30 UTC, dispatch |
| `nightly` (device lane) | ubuntu-latest | `nightly.sh` → every `nightly.d/*.sh` | INT-01 | cron 02:30 UTC, dispatch |

Other scripts in this directory and their owners:

| Script | Owner | Used by |
|---|---|---|
| `check_ios_min_os.sh` | ENG-09 | `ios.sh`; INT-05's iOS release lane (D-41) |
| `ios_device_lane_classes.txt` | INT-01 | `ios.sh` (`DANAVIEW_IOS_RUNNER_LANE`): the RunnerTests classes of the device lane |
| `check_native_libs.sh` | AI-04 | INT-05's Android release workflow step |
| `e2e_ios.sh` | QA-01 | run by hand on the self-hosted Mac (simulators) |
| `e2e_android.sh` | QA-02 | run by hand on a machine with the Android emulators |
| `nightly.d/core_fuzz.sh` | CORE-34 | `nightly` |
| `nightly.d/ai_eval.sh` | QA-06 | `nightly` |
| `nightly.d/overflow_full.sh` | QA-09 | `nightly` |
| `nightly.d/<name>.sh` | the ticket that adds it | `nightly` |

## Triggers

- **Pull requests and pushes to `main`** that touch `packages/danaview_editor*/**`, `packages/danaview_transcription/**`, `packages/danaview_whisper/**`, `test/architecture/**`, `scripts/ci/editor/**` or the workflow itself. `packages/danaview_features/**` and `docs/v1.1/editor/BUILD_PLAN.md` also trigger it, because the architecture test guards `danaview_features` (ARCH §4.2 rule 1, ARCH §1.3 Material scan) and reads the BUILD_PLAN owns lists.
- **Nightly** (cron `30 2 * * *`): `danaview-device.yml` (the device lane), which opens or closes the `ci-nightly` issue.
- **Manual** (`workflow_dispatch`): either workflow; `danaview-ci.yml`'s input `device_lane` adds the device lane on any branch.

The existing release workflows (`android-release.yml`, `linux-release.yml`, `windows-release.yml`) don't depend on this workflow. INT-05 adds the release dart-defines and the release-lane checks.

## Script contract

Every script in this directory and in `nightly.d/` must follow these rules:

- Start with `#!/usr/bin/env bash`, a `# OWNER: <ticket>` header and `set -euo pipefail`. Scripts run with `bash <script>`, so the executable bit is optional. They must work on macOS's bash 3.2: no associative arrays, no `mapfile`, and guard empty arrays under `set -u`.
- Work from any working directory: resolve the repo root from the script's own location (`"$(dirname "${BASH_SOURCE[0]}")"`). `nightly.sh` runs `nightly.d/*` from the repo root.
- Exit non-zero on failure. Skip with a notice only when a documented prerequisite of a not-yet-landed ticket is missing (for example a package that doesn't exist yet). Never skip because a tool is missing on a CI runner: fail with the install instruction instead (`ios.sh` fails early with `brew install cmake` when CMake ≥ 3.28 is missing).
- In GitHub Actions (`GITHUB_ACTIONS=true`), use `::group::`, `::notice::` and `::error::` annotations.
- Download nothing except package-manager dependency resolution (pub, CocoaPods, Gradle/Maven), apart from what a script's own ticket explicitly allows (AI-03's `whisper_host.sh` fetches ggml-tiny with a sha256 check). Keep downloads under `$DANAVIEW_CI_CACHE_DIR` (default `~/.cache/danaview-ci`), which CI caches.
- Never log media paths, transcript text or user content.

Inputs the workflow passes:

| Variable | Set for | Meaning |
|---|---|---|
| `DANAVIEW_SANITIZER` | `whisper-host` | `none`, `thread` (TSan leg) or `address` (ASan leg) |
| `DANAVIEW_CI_CACHE_DIR` | `whisper-host`, `nightly` | cache directory restored by `actions/cache` (`.ci-cache/` in the workspace) |
| `DANAVIEW_CI_EXCLUDE_TAGS` | read by `flutter_packages.sh` | test tags left out of PR runs (default `nightly`) |
| `DEVELOPER_DIR` | `ios` | Xcode 26.6 when it is installed |

**Test tags.** `flutter_packages.sh` runs `flutter test --exclude-tags nightly`. Long suites (for example QA-09's full overflow matrix) tag their tests `nightly`, declare the tag in the package's `dart_test.yaml`, and run in full from a `nightly.d/` script. The PR subset stays untagged.

## Running locally

```sh
scripts/ci/editor/core.sh                              # dart-core + dart-core-benchmark (test | benchmark for one)
scripts/ci/editor/flutter_packages.sh                  # every editor Flutter package + test/architecture
scripts/ci/editor/flutter_packages.sh architecture     # only the root architecture tests
scripts/ci/editor/flutter_packages.sh danaview_editor_engine_api
scripts/ci/editor/nightly.sh --list                    # nightly.d scripts
scripts/ci/editor/nightly.sh overflow_full             # one nightly script (the command printed on failure)
```

```sh
scripts/ci/editor/android_emulator.sh                                     # every instrumented test package, then the engine smoke test
DANAVIEW_EMULATOR_BATCHES="effects proxy" scripts/ci/editor/android_emulator.sh   # only these batches
DANAVIEW_EMULATOR_BATCHES="drop,harness" DANAVIEW_SKIP_SMOKE=1 scripts/ci/editor/android_emulator.sh
DANAVIEW_EMULATOR_DRY_RUN=1 scripts/ci/editor/android_emulator.sh         # print the batches and commands only
```

`android_emulator.sh` needs a booted emulator or device (`ANDROID_SERIAL` picks one). It runs the engine's instrumented tests in batches, one `:danaview_editor_engine:connectedDebugAndroidTest` per test package: each direct subdirectory of `packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/` that has an `@Test`, filtered with `-Pandroid.testInstrumentationRunnerArguments.package=`. Each batch is its own instrumentation process, so a load-dependent failure or a native codec crash in one package can't abort the rest (owner decision 2026-10-15; the single-process run of the whole suite failed load-dependent tests and crashed after about 245 tests). A failed batch doesn't stop the run. The script prints a per-batch summary (batch, result, tests, failures, time), copies each batch's JUnit XML and logs to `packages/danaview_editor_engine/example/build/danaview_emulator_batches/<batch>/`, runs `integration_test/engine_smoke_test.dart` unless `DANAVIEW_SKIP_SMOKE=1`, and exits non-zero if any batch failed. `DANAVIEW_EMULATOR_BATCHES` takes space-separated batches; a comma joins packages into one batch. `DANAVIEW_GRADLE_ARGS` adds Gradle arguments (CI adds `--no-daemon`).

`flutter_packages.sh` covers `danaview_editor_engine_api`, `danaview_editor_engine` (and its `example/` when present), `danaview_transcription`, `danaview_whisper`, `danaview_editor_fonts` and `danaview_editor`: `flutter pub get`, `flutter analyze --fatal-infos --fatal-warnings`, `flutter test`. Missing packages are skipped. It then runs `flutter analyze` and `flutter test` on `test/architecture/` at the repo root (`dependency_rules_test.dart`, ARCH §4.2 rules 1–7 and the ARCH §1.3 Material scan). `danaview_editor_core` is pure Dart and runs in `core.sh`.

## Toolchain pins

- Flutter **3.44.2** stable (Dart 3.12), the same on every job (`FLUTTER_VERSION` in the workflow).
- Java 17 (Temurin) for the Gradle jobs.
- Xcode **26.6** with the iOS 26 simulator runtime. The oldest simulator runtime in use is iOS 18.2, because Xcode 26.6 offers no iOS 15/16 runtimes.
- CMake ≥ 3.28 on macOS (whisper xcframework, AI-05). On Android, SDK CMake 3.22.1 or the version AI-04 pins.
- iOS deployment target **15.0** (ARCH §3.1, D-29): app, RunnerTests, every pod (lifted by the Podfile `post_install` hook) and the new podspecs.

## macOS runner

The `ios` job and the macOS leg of `whisper-host` run on GitHub's hosted `macos-26` image (Apple silicon; free for this public repository, with a concurrency cap of 5 macOS jobs on the Free plan). Each job selects `/Applications/Xcode_26.6.app` with `xcode-select`; the image's preinstalled CocoaPods and CMake cover the toolchain step, and `ios.sh` picks the first iPhone on the newest iOS runtime (`DANAVIEW_IOS_SIMULATOR` overrides). The gate runs RunnerTests only (minus the device-lane classes); the device lane's `ios-device` job builds for the device and runs every integration suite. The QA-00 E2E suite (`DANAVIEW_E2E=1`, staged speech models) stays a manual run on a developer Mac.

A self-hosted Mac is no longer required. To bring one back, it needs:

1. A macOS version that runs Xcode 26.6 (the dev Mac runs macOS 26), with **Xcode 26.6** at `/Applications/Xcode_26.6.app` or `/Applications/Xcode.app`. Accept the licence (`sudo xcodebuild -license accept`) and run the first launch (`xcodebuild -runFirstLaunch`).
2. Simulator runtimes: **iOS 26** (default target, iPhone 17 Pro and iPad Pro) and **iOS 18.2** (QA-01 scenarios 1–3).
3. `brew install cmake` (≥ 3.28; not installed on the dev Mac today) and CocoaPods 1.16.x (`brew install cocoapods`).
4. A UTF-8 locale for CocoaPods (`export LANG=en_US.UTF-8` in the runner's `.env`; the `ios` job also sets it).
5. Register the runner (`./config.sh --labels self-hosted,macOS`) and run it as a service. It needs no signing identity: CI builds use `--no-codesign` and the simulator.

## Device lab

| Device | OS | Purpose | Status |
|---|---|---|---|
| iPhone 7 | iOS 15.8.x (final) | D-41 launch, player and editor smoke on the iOS 15 floor (AI-05, IOS-01, QA-01) | **not available**: owner default 2026-10-08 (ARCH D-43). These device checks are recorded as "deferred: no device available" |
| iPhone 8 | iOS 16.7.x (final) | D-41 smoke on iOS 16 (AI-05, IOS-01, QA-01) | **not available**: as above |
| One physical iPhone and one physical Android phone | current | QA-10 persistence and reinstall checks, real-device export and background checks | as provided by QA |

Until lab devices exist, iOS 15 and 16 are covered only at build time: both pods compile with `-Werror=unguarded-availability-new`, and `check_ios_min_os.sh` (in `ios.sh` and the release lane) fails on any strongly bound symbol or minimum OS above iOS 15.0.
