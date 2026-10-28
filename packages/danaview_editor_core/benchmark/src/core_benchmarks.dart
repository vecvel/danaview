// OWNER: CORE-35
//
// The core rows of ARCH §18.2, measured in AOT and host-normalized (see run.dart):
//
// | id                         | what is timed                                                      | p90 budget |
// |----------------------------|--------------------------------------------------------------------|------------|
// | apply_1000                 | `applyCommand` on a lane of 1,000 clips (trim, move, split, look)  | 2 ms       |
// | dry_run_1000               | `dryRun` of a drag (move) and a trim on that lane                  | 1 ms       |
// | incremental_compile_2000   | memoized preview compile + `diffPlans` after a one-clip edit       | 3 ms       |
// | full_compile_2000          | preview compile from scratch (the `Isolate.run` work)              | 60 ms      |
// | plan_encode_2000           | `PlanJson.encodePlanBytes` of that plan                            | 25 ms      |
// | open_2000                  | `.dnproj` parse + checksum + schema check + decode + repair        | 150 ms     |
// | autosave_block_2000        | incremental body encode after a one-clip edit (main isolate)       | 2 ms (*)   |
//
// (*) ARCH §18.2 assigns the autosave budget to QA-04 (on devices): the row is measured and
// regression-gated here, but a budget miss is reported without failing `--check`.
// The 2,000-item rows use `test/fixtures/projects/large_2000.json` (2,000 items + 3,000 cues,
// 32 lanes, 3 h, 300 media). Inputs for a sample (the edit, a fresh document) are prepared outside
// the timed region.

import 'dart:convert';
import 'dart:typed_data';

import 'package:danaview_editor_core/codec.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_core/store.dart';

import 'calibration.dart';
import 'harness.dart';
import 'large_project.dart';

/// ARCH §18.2 budgets (low tier, p90), µs.
abstract final class CoreBudgets {
  /// `apply` one lane at 1,000 items.
  static const int apply = 2000;

  /// `dryRun` at 1,000 items.
  static const int dryRun = 1000;

  /// Incremental compile + diff at 2,000 items.
  static const int incremental = 3000;

  /// Full compile at 2,000 items.
  static const int fullCompile = 60000;

  /// Plan encode at 2,000 items.
  static const int encode = 25000;

  /// Project open at 2,000 items (core).
  static const int open = 150000;

  /// Autosave block on the main isolate (budget owned by QA-04; reported, not gated).
  static const int autosave = 2000;
}

/// How many samples each metric takes (scaled down by `--quick`).
final class BenchSizes {
  /// Creates sizes; [quick] divides the sample counts by four.
  const BenchSizes({this.quick = false});

  /// Fewer samples (local smoke runs).
  final bool quick;

  int _n(int n) => quick ? (n ~/ 4).clamp(5, n) : n;

  /// Samples of the sub-millisecond rows.
  int get fast => _n(400);

  /// Samples of the compile/encode rows.
  int get heavy => _n(40);

  /// Samples of the open row.
  int get open => _n(24);
}

/// A resolver that knows every pool file, the bundled looks and the imported LUTs.
PlanAssetResolver benchResolver(EditProject p) {
  final originals = <MediaId, ResolvedMedia>{};
  final luts = <MediaId, ResolvedLut>{};
  for (final a in p.pool.assets.values) {
    if (a.kind == MediaKind.lut) {
      luts[a.id] = ResolvedLut(uri: 'file:///support/danaview/editor/luts/${a.id}.vlut', size: 33);
      continue;
    }
    final ext = switch (a.kind) {
      MediaKind.image => 'jpg',
      MediaKind.still => 'png',
      MediaKind.audio || MediaKind.recording => 'm4a',
      _ => 'mp4',
    };
    originals[a.id] = ResolvedMedia(uri: 'file:///media/${a.id}.$ext', fingerprint: a.fingerprint.quickHash);
  }
  return MapPlanAssetResolver(
    originals: originals,
    luts: luts,
    looks: {
      for (final id in const ['tealOrange', 'warm', 'mono'])
        id: ResolvedLut(uri: 'file:///app/assets/looks/$id.vlut', size: 33),
    },
  );
}

/// Visual clips of [p] (the edit targets of the 2,000-item rows).
List<MediaClip> visualClips(EditProject p) => [
      for (final t in p.tracks)
        if (t.kind == TrackKind.video || t.kind == TrackKind.overlay)
          for (final i in t.items)
            if (i is MediaClip && i.visual != null) i,
    ];

/// A one-clip appearance edit (opacity) of the [i]-th target of [clips].
EditCommand opacityEdit(List<MediaClip> clips, int i) {
  final c = clips[(i * 37) % clips.length];
  final v = c.visual!;
  return SetVisual([c.id], v.copyWith(transform: v.transform.copyWith(opacity: 0.5 + (i % 5) / 10)));
}

EditContext _ctx() => EditContext(ids: SeededIdGenerator(35), now: DateTime.utc(2026, 10, 15));

/// `apply` and `dryRun` on [lane] (a project whose main lane holds 1,000 clips).
List<MetricResult> commandBenchmarks(EditProject lane, BenchSizes sizes) {
  final ctx = _ctx();
  final items = lane.tracks.first.items;
  final rate = lane.settings.frameRate;
  final frame = rate.timeOfFrame(1);
  EditCommand applyAt(int i) {
    final item = items[(i * 53) % items.length];
    return switch (i % 4) {
      0 => TrimItem(item.id, TrimEdge.end, item.end - frame, clamp: true),
      1 => MoveItems({item.id}, -frame, clamp: true),
      2 => SplitItems({item.id}, rate.timeOfFrame(rate.frameIndexOf(item.start + item.duration ~/ 2))),
      _ => opacityEdit([item as MediaClip], i),
    };
  }

  EditCommand dragAt(int i) {
    final item = items[(i * 53) % items.length];
    return i.isEven ? MoveItems({item.id}, frame * (1 + i % 5), clamp: true) : TrimItem(item.id, TrimEdge.start, item.start + frame * 2, clamp: true);
  }

  var rejected = 0;
  final apply = measure(
    warmup: sizes.fast ~/ 2,
    samples: sizes.fast,
    body: (i) {
      final out = applyCommand(lane, applyAt(i), ctx);
      if (out.isRejected) rejected++;
      blackhole = out;
    },
  );
  if (rejected > 0) throw StateError('apply_1000: $rejected commands were rejected; the benchmark must time real edits');
  final dry = measure(
    warmup: sizes.fast ~/ 2,
    samples: sizes.fast,
    body: (i) => blackhole = dryRun(lane, dragAt(i), ctx),
  );
  return [
    MetricResult('apply_1000', apply, budgetUs: CoreBudgets.apply, label: 'apply one lane at 1,000 items'),
    MetricResult('dry_run_1000', dry, budgetUs: CoreBudgets.dryRun, label: 'dryRun at 1,000 items'),
  ];
}

/// Compile, diff, encode and autosave rows on the large project [large].
List<MetricResult> planBenchmarks(EditProject large, BenchSizes sizes) {
  final resolver = benchResolver(large);
  final clips = visualClips(large);
  final ctx = _ctx();

  // Full compile (what `Isolate.run` does for > 300 items) and plan encode.
  late RenderPlan plan;
  final full = measure(
    warmup: 3,
    samples: sizes.heavy,
    body: (_) => plan = PlanMemo().compile(large, PlanTarget.preview, resolver).plan,
  );
  if (plan.layers.isEmpty) throw StateError('full compile produced no layers');
  final encode = measure(warmup: 3, samples: sizes.heavy, body: (_) => blackhole = PlanJson.encodePlanBytes(plan));

  // Incremental compile + diff after a one-clip edit.
  final memo = PlanMemo();
  var project = large;
  var previous = memo.compile(project, PlanTarget.preview, resolver).plan;
  final incremental = measure(
    warmup: 20,
    samples: sizes.fast ~/ 4,
    setup: (i) {
      final out = applyCommand(project, opacityEdit(clips, i), ctx);
      if (out.changed) project = out.project;
    },
    body: (_) {
      final next = memo.compile(project, PlanTarget.preview, resolver).plan;
      blackhole = diffPlans(previous, next);
      previous = next;
    },
  );

  // Autosave: the incremental body encode on the main isolate after a one-clip edit.
  final codec = ProjectJsonCodec();
  var saved = large;
  blackhole = codec.encodeBytes(saved);
  final autosave = measure(
    warmup: 20,
    samples: sizes.fast ~/ 2,
    setup: (i) {
      final out = applyCommand(saved, opacityEdit(clips, i + 1000), ctx);
      if (out.changed) saved = out.project;
    },
    body: (_) => blackhole = codec.encodeBytes(saved),
  );

  return [
    MetricResult('incremental_compile_2000', incremental, budgetUs: CoreBudgets.incremental, label: 'incremental compile + diff at 2,000 items'),
    MetricResult('full_compile_2000', full, budgetUs: CoreBudgets.fullCompile, label: 'full compile at 2,000 items'),
    MetricResult('plan_encode_2000', encode, budgetUs: CoreBudgets.encode, label: 'plan JSON encode at 2,000 items'),
    MetricResult('autosave_block_2000', autosave, budgetUs: CoreBudgets.autosave, label: 'autosave block on the main isolate', budgetGated: false),
  ];
}

/// Probe workloads of the encoder rows (see [CalibrationKind.isProbe]): the plan encoder and the
/// project body encoder on one-lane projects (300 and 2,000 clips; ≈ 2.6 ms and ≈ 0.85 ms on the
/// dev Mac), smaller than and shaped unlike the large fixture the rows encode.
Map<CalibrationKind, Object? Function(int)> encodeProbes() {
  final small = buildOneLaneProject(clips: 300, seed: 300);
  final plan = PlanMemo().compile(small, PlanTarget.preview, benchResolver(small)).plan;
  if (plan.layers.isEmpty) throw StateError('probe compile produced no layers');
  final body = buildOneLaneProject(clips: 2000, seed: 301);
  final codec = ProjectJsonCodec();
  return {
    CalibrationKind.planEncode: (_) => PlanJson.encodePlanBytes(plan),
    CalibrationKind.autosave: (_) => codec.encodeBytes(body),
  };
}

/// The `.dnproj` document of [body] as the repository writes it.
Uint8List documentOf(Uint8List body) =>
    DnprojFormat.build(body, app: '1.1.0+bench', savedAt: DateTime.utc(2026, 10, 15), docRevision: 1, saveId: 'sv_benchmark0001');

/// The core open pipeline of `FileProjectRepository` without I/O: parse and verify the
/// document, check the schema, migrate when needed, decode and repair (validation inside).
EditProject openDocument(Uint8List document, {Migrations? migrations}) {
  final m = migrations ?? Migrations.standard;
  final doc = DnprojFormat.parse(document);
  final compat = m.classifyHeader(doc.header);
  if (compat == SchemaCompatibility.needsNewerApp || compat == SchemaCompatibility.unsupportedOld) {
    throw StateError('benchmark document is not openable: $compat');
  }
  final raw = jsonDecode(utf8.decode(doc.body));
  if (raw is! Map<String, Object?>) throw const FormatException('body is not an object');
  var body = raw;
  if (compat == SchemaCompatibility.needsMigration) body = m.migrate(raw, from: doc.header.schema).body;
  final decoded = ProjectJsonCodec().decodeJson(body);
  final (repaired, _) = repair(decoded.project);
  return repaired;
}

/// The open row on the fixture [body] bytes.
MetricResult openBenchmark(Uint8List body, BenchSizes sizes) {
  final document = documentOf(body);
  final samples = measure(warmup: 3, samples: sizes.open, body: (_) => blackhole = openDocument(document));
  return MetricResult('open_2000', samples, budgetUs: CoreBudgets.open, label: 'project open at 2,000 items (core)');
}
