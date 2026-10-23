<!-- OWNER: CORE-35 -->
# danaview_editor_core

The pure-Dart editing core of the Danaview video editor (ARCH §4.3). It holds the time model and
frame grid, the immutable domain model, editing commands and snapshot history, the SRT/VTT and LUT
formats, project persistence, the media pool, and the RenderPlan v1 contract that the native
engines share.

Run the checks with `dart pub get && dart analyze --fatal-infos && dart test`, or run
`scripts/ci/editor/core.sh`. That script is the dart-core CI job, and it also runs the frame-grid
vector check and the benchmark gate.

## Package boundaries

- **Dependencies (ARCH §4.2 rule 2).** The package depends only on `meta`, `collection`,
  `crypto`, `path` and `characters`. It never depends on `package:flutter` or any `danaview_*`
  package. `dart:io` and `dart:isolate` are allowed only under `lib/src/store/` (and
  `lib/store.dart`). `test/purity_test.dart` enforces these rules, the exact dependency list, the
  strict analyzer settings, the barrels and the `// OWNER:` header that every `lib/` file needs.
- **Public barrels.** These are the only imports other packages may use:

  | Barrel | Contents |
  |---|---|
  | `model.dart` | ids, time and frame grid, project/timeline/track/item model, keyframes, media pool |
  | `ops.dart` | `EditCommand`s, `applyCommand` / `dryRun`, rejections, placement, snapping, clipboard, `EditSession` + history |
  | `eval.dart` | evaluation (clip time maps, speed math, geometry, text animation, packing), `validate` / `repair` |
  | `formats.dart` | SRT, VTT, `.cube` → `.vlut` |
  | `plan.dart` | RenderPlan v1 types, compiler, lowering stages, `PlanMemo`, diff/patch, transients, validator, export compile |
  | `codec.dart` | project body codec, `.dnproj` header model, schema versions, migrations |
  | `store.dart` | repository, atomic files, journal and recovery, autosave, GC, media pool service, writer isolate |
  | `render_cache.dart` | render-range hashing and the render-cache index |
  | `testing.dart` | test support only: `MemoryStoreFs`, `InMemoryProjectRepository` (never import it from production code) |

- **Where work runs (ARCH §18.1).** Commands, `dryRun`, incremental compile + diff (≤ 300 items)
  and the autosave encode run on the UI isolate. A full compile above `compileIsolateThreshold`
  (300 items), plan encode and project open run in `Isolate.run`. Hashing and atomic writes run on
  the writer isolate. Everything in `lib/` outside `store/` stays synchronous and pure, so any
  isolate can call it.
- **Normative sources.** The RenderPlan sources are `schema/render_plan.v1.schema.json` and
  `schema/effects_reference.md`. The project body schema is `schema/project.v1.schema.json`. The
  shared frame-grid vectors in `test/fixtures/vectors/frame_grid.json` are read by the Dart, Swift
  and Kotlin tests and regenerated with `dart run tool/gen_frame_vectors.dart`.

## Authoring a command

`EditCommand` is sealed and self-dispatching (`lib/src/ops/edit_command.dart`, CORE-09). Each
command group has a `part` file under `lib/src/ops/commands/`. Group tickets add commands to their
own part file only and never edit the framework. Checklist for a new command:

1. **Purity.** `_apply(_Draft d)` edits only the draft. It does no I/O, reads no clock (use
   `ctx.now`) and mints ids only through `ctx.ids`. The same project, command and seeded context
   must give an equal outcome. Never mutate inputs, and keep values immutable (`copyWith`).
2. **Rejections are data.** Refuse with `d.reject(SomeRejection(...))` using the sealed set in
   `rejections.dart` (ARCH §7.1). Never throw for a user-reachable case. The runner turns any
   exception into `InternalInconsistency`, and that state is a bug. Rejection fields hold ids and
   numbers only, never paths or user text. A command that changes nothing must come out as `noop`
   (no history entry). Do not hand-roll an equality check: the runner detects it.
3. **One path for apply and dry run.** `dryRun` runs the same `_apply`, so a command needs no
   preview-only branch. Report placements through the draft so drag ghosts match the applied result.
4. **Validator.** The runner validates the changed lanes after every command (`validate(only:)`,
   CORE-08) and refuses results that add a violation. If the command can create a new kind of
   state, extend the validator invariants with that ticket's owner first (and `repair()` when
   stored projects could hold it). Then add tests for both the valid and the refused case.
5. **Limits.** `LayerLimits` (D-14) checks items, duration and both layer caps generically.
   Commands never check caps themselves. A reducing edit must stay possible over a cap.
6. **Fuzz registration (CORE-34).** Add the subtype name to `allCommandNames` in
   `test/fuzz/fuzz_coverage.dart`. The exhaustive `commandName` switch does not compile until you
   do. Also teach `test/fuzz/fuzz_generator.dart` to draw the command with mostly valid targets.
   The coverage test then requires the fuzzer to exercise it. A fuzz failure becomes a fixture in
   `test/fuzz/regressions/`.
7. **Tests and budgets.** Add unit tests under `test/ops/<group>/` with apply, refusal, no-op,
   undo through `EditSession`, and the dry-run/apply placement equality. Run
   `dart run benchmark/run.dart` when a command touches a hot path. The `apply_1000` and
   `dry_run_1000` rows must stay within budget.

## Schema and migration procedure

A `.dnproj` document is a header line plus one body line (ARCH §8.2–8.5,
`lib/src/codec/schema_version.dart`). The header's `schema` changes with every body format change.
`minReader` changes only when an older app would misread the new document (D-12).

- **Additive optional field** (older readers ignore it safely): add it to the codec with a default
  that is omitted on write, add it to `schema/project.v1.schema.json`, and keep the round-trip and
  determinism tests green. Bump `schema` only when the body would otherwise mean something
  different. Leave `minReader` unchanged.
- **Any other change:**
  1. Bump `currentProjectSchema` (and `currentProjectMinReader` if older apps would misread the
     document).
  2. Add a pure, idempotent `MigrationStep` `s<N> → s<N+1>` to the production chain in
     `lib/src/codec/migrations/`. It works on raw JSON maps, receives a private deep copy, and
     must keep keys it does not know.
  3. Freeze the old format: keep `test/fixtures/projects/s<N>/` and add `s<N+1>/` fixtures
     (`<name>.body.json` + the regenerated `.dnproj`; `REGENERATE_FIXTURES=1 dart test
     test/codec_migrations`). Every older fixture must migrate, validate and re-encode.
  4. Update the JSON schema and the codec. Then regenerate the benchmark fixture
     (`dart run benchmark/run.dart --write-fixture`).
- **Behaviour on open:** opening never writes. A migrated project is backed up as
  `backups/pre-migration-s<N>.dnproj` on its first save. A newer `schema` whose `minReader` this
  build satisfies opens read-only. Anything newer than that needs a newer app.

## RenderPlan versioning (ARCH §11.9)

- Every plan, patch and transient carries `"v"` (`renderPlanVersion`).
  `EditorCapabilities.planVersions` lists what the engine decodes, and the compiler emits the
  highest version both sides support.
- **Additive optional fields** need no bump, because decoders ignore unknown keys. **Any change of
  meaning bumps `v`.** The compiler then keeps emitting the previous version for one release.
- **Contract tests:** the hand-written fixtures in `test/fixtures/render_plans/contract/` (CORE-29)
  validate against the JSON Schema and round-trip in Dart. The iOS XCTest (IOS-08) and Android
  JUnit (AND-08) suites decode, re-encode and compare every fixture. Compile goldens (CORE-30/31)
  pin `compile(project) == plan`, and render goldens compare devices with the Dart reference
  (QA-03). A change to the plan types needs the schema, the fixtures and both native decoders
  updated in the same change set.

## Benchmarks (CORE-35)

`benchmark/run.dart` measures the core rows of ARCH §18.2 in AOT. Run with `dart run`, it compiles
itself with `dart compile exe` into `.dart_tool/danaview_benchmark/`.

| Row | Workload | p90 budget |
|---|---|---|
| `apply_1000` | trim / move / split / appearance on a lane of 1,000 clips | 2 ms |
| `dry_run_1000` | drag and trim previews on that lane | 1 ms |
| `incremental_compile_2000` | memoized compile + `diffPlans` after a one-clip edit | 3 ms |
| `full_compile_2000` | preview compile from scratch (`Isolate.run` work) | 60 ms |
| `plan_encode_2000` | `PlanJson.encodePlanBytes` | 25 ms |
| `open_2000` | `.dnproj` parse + checksum + schema check + decode + repair | 150 ms |
| `autosave_block_2000` | incremental body encode on the main isolate | 2 ms (QA-04 owns the budget; reported, not gated) |

The 2,000-item rows use `test/fixtures/projects/large_2000.json`, the ARCH §18.2 design target:
2,000 items plus 3,000 cues, 32 lanes, a 3 h timeline and 300 media. It is a project body line
written by `benchmark/src/large_project.dart` (deterministic) and regenerated with
`--write-fixture`.

```sh
dart run benchmark/run.dart                    # measure and print
dart run benchmark/run.dart --check            # CI gate (core.sh): budgets + ≤ 25 % p90 regression
dart run benchmark/run.dart --update-baseline  # rewrite benchmark/baseline.json (on the dev Mac)
dart run benchmark/run.dart --json out.json    # also write the results
```

`--check` fails when any of these hold:

- a gated row's p90 exceeds its budget × f;
- a row's p90 exceeds `baseline × f × 1.25` by more than 50 µs;
- the fixture loses its shape, validity or D-14 limits.

A failing row is measured again up to twice, and the best run counts.

**Host factor f.** `baseline.json` is recorded on the dev Mac (Apple M2, 8 cores, macOS 26.6.2,
AOT), the host the budgets were verified on; no CI runner matches it (the `dart-core-benchmark` job
on ubuntu-latest and the macos-26 VM run 1.2–2.3× slower, and ubuntu-latest machines differ from
run to run). Each run therefore times two fixed pure-Dart calibration workloads
(`benchmark/src/calibration.dart`, no package code) before and after the rows: `compute` (object
churn, maps, sorting) for the apply, dryRun and compile rows, and `codec` (JSON, double
formatting, string and byte building) for the encode, autosave and open rows, which slow down more
on x86_64. A row's f = the lower of the two p50s of its kind ÷ the baseline's `calibrationUs`. On the dev Mac f ≈ 1, so the gate there is the plain budget and
the plain 25 % rule; on a slower host both scale with it. The budgets themselves are device
budgets (§18.2 low/mid tier); device numbers are QA-04's. Refresh the baseline on the dev Mac, on
a quiet machine, and only for an intended change (`--update-baseline` writes the calibration too). The device numbers (one mid-tier Android, one iPhone)
are recorded through QA-04.
