# 1.2.0 CI scripts (`scripts/ci/v12/`)

Scripts for the 1.2.0 jobs of `.github/workflows/danaview-ci.yml` (BUILD_PLAN v1.2 INT-101). Each job
runs only when its paths changed (the workflow's `changes` job), on every push to `main`
and on manual dispatch. Every script runs locally from any directory (`bash scripts/ci/v12/<name>.sh`)
and needs only Flutter 3.44.2; nothing is downloaded beyond pub dependency resolution.

| Script | Job | Owner | What it runs |
|---|---|---|---|
| `library.sh` | `v12-dart` | INT-101 | `danaview_library` and `danaview_search` (dart analyze `--fatal-infos`, dart test), then the core photo, colour and beauty tests of `danaview_editor_core` with its purity test |
| `documents.sh` | `v12-flutter` | INT-101 | `danaview_library_native`, `danaview_pdf`, `danaview_documents` (flutter analyze `--fatal-infos`, flutter test), `danaview_features` analyze, and the root `test/architecture` and `test/v12` |
| `face.sh` | `v12-flutter` | INT-101 | `danaview_face_tracking` (flutter analyze `--fatal-infos`, flutter test) |
| `home_preservation.sh` | `home-preservation` | HOM-15 | the 1.1 Home, player, playlist, queue, library and incoming-media tests plus HOM-06…HOM-08 with `DANAVIEW_FILES_HOME` off and on (ARCH v1.2 V2-32); the job prints a skip notice until HOM-15 creates it |
| `documents_e2e.sh` | (QA, device) | HOM-32 | documents E2E on the iOS Simulator |
| `e2e_ios.sh`, `e2e_android.sh` | (QA, device) | QA-101, QA-102 | cross-plan E2E |

Path filters (the `changes` job):

- `v12-dart`: `packages/danaview_library/**`, `packages/danaview_search/**`, `packages/danaview_domain/**`, the core photo, colour, beauty, plan and ops trees, `scripts/ci/v12/library.sh`.
- `v12-flutter`: `packages/danaview_library_native/**`, `packages/danaview_pdf/**`, `packages/danaview_documents/**`, `packages/danaview_face_tracking/**`, `packages/danaview_features/**`, `packages/danaview_library/**`, `packages/danaview_search/**`, `packages/danaview_ui_kit/**`, `test/architecture/**`, `test/v12/**`, `scripts/ci/v12/{documents,face}.sh`.
- `home-preservation`: `packages/danaview_features/lib/src/library/**`, `packages/danaview_platform/**`, `packages/danaview_library*/**`, `test/v12/preservation/**`, `test/home_screen_test.dart`, `scripts/ci/v12/home_preservation.sh`.
