// OWNER: CORE-32
//
// Compile memoization (ARCH §11.1 rule 3, §11.8). A session keeps one [PlanMemo] and compiles
// every preview plan through it ([PlanMemo.compile], or [PlanMemo.options] for a plain
// `compilePlan`); a one-item edit then re-lowers only that item and its transition neighbours:
//
// * **Visual lowering** ([ClipLoweringMemo], used by the compiler): per clip **object** (the model
//   is immutable and structurally shared, so an unedited clip is the identical object in the next
//   snapshot) plus a context signature — the compiler's `ClipLoweringKey`: what the clip shows
//   (asset identity and its resolved entry, look/LUT), its lane z (track order), backdrop blur
//   (background setting), target, hold-frame capability, canvas, frame rate and canvas mapping.
//   Track visibility is decided before lookup (hidden lanes are not lowered).
// * **Transition edits** ([TransitionLayerMemo], used by `TransitionLoweringStage`): per input
//   layer object (a memoized visual layer is identical across compiles) plus the edit (range,
//   helper channels from the neighbours and the transition, masks), so only the edited item and
//   its transition neighbours are re-edited.
// * **Audio** ([AudioSegMemo], used by `AudioLoweringStage`): per clip object plus the segment's
//   context — the picture layer's range and map (so transition neighbours and speed edits
//   invalidate it), the transitions touching the clip, track mute/solo, the asset entry and
//   `maxAudioSpeed`.
// * [PlanMemo.compile] then adopts the compiled transition-edited layers (which the compiler gave
//   their packing `seq`) as the memoized results, so an unchanged layer is the **identical**
//   object in consecutive plans and `diffPlans` decides it with a pointer check (identity-first).
//
// Entries live in `Expando`s keyed by model or layer objects, so they disappear with the
// snapshots that hold them; nothing is ever stale because every lookup compares the full key.
// Hit and miss counters are for tests and benchmarks.

import '../model/items.dart';
import '../model/project.dart';
import 'asset_resolver.dart';
import 'compiler.dart';
import 'lowering_audio.dart';
import 'lowering_transitions.dart';
import 'lowering_visual.dart';
import 'render_plan.dart';
import 'sprite_request.dart';

/// The memo of one editing session (file header).
final class PlanMemo implements ClipLoweringMemo {
  /// Creates an empty memo.
  PlanMemo();

  Expando<_ClipEntry> _clips = Expando<_ClipEntry>('PlanMemo.clips');

  /// The transition-edit memo (pass to `TransitionLoweringStage`; [options] does).
  final PlanTransitionMemo transitions = PlanTransitionMemo();

  /// The audio segment memo (pass to `AudioLoweringStage`; [options] does).
  final PlanAudioMemo audio = PlanAudioMemo();

  /// Visual lowerings reused since creation or the last [resetStats].
  int hits = 0;

  /// Visual lowerings computed since creation or the last [resetStats].
  int misses = 0;

  @override
  LoweredClip? lookup(MediaClip clip, ClipLoweringKey key) {
    final e = _clips[clip];
    if (e != null && (identical(e.key, key) || e.key == key)) {
      hits++;
      return e.lowered;
    }
    misses++;
    return null;
  }

  @override
  void store(MediaClip clip, ClipLoweringKey key, LoweredClip lowered) => _clips[clip] = _ClipEntry(key, lowered);

  /// Forgets everything.
  void clear() {
    _clips = Expando<_ClipEntry>('PlanMemo.clips');
    transitions.clear();
    audio.clear();
    resetStats();
  }

  /// Zeroes every counter.
  void resetStats() {
    hits = 0;
    misses = 0;
    transitions.hits = 0;
    transitions.misses = 0;
    audio.hits = 0;
    audio.misses = 0;
  }

  /// Compile options for a memoized compile with the standard lowering stages
  /// (`standardLoweringStages`): [base]'s fields with this memo and its stage memos.
  CompileOptions options({
    CompileOptions base = const CompileOptions(),
    SpriteManifest? sprites,
    double maxAudioSpeed = defaultMaxAudioSpeed,
  }) =>
      CompileOptions(
        rev: base.rev,
        output: base.output,
        holdFrame: base.holdFrame,
        memo: this,
        stages: standardLoweringStages(
          sprites: sprites,
          maxAudioSpeed: maxAudioSpeed,
          memo: audio,
          transitionMemo: transitions,
        ),
      );

  /// Compiles [project] through this memo ([options]) and adopts the compiled transition-edited
  /// layers so they stay identical across compiles (file header).
  CompiledPlan compile(
    EditProject project,
    PlanTarget target,
    PlanAssetResolver resolver, {
    CompileOptions base = const CompileOptions(),
    SpriteManifest? sprites,
    double maxAudioSpeed = defaultMaxAudioSpeed,
  }) {
    transitions
      .._recent.clear()
      .._tracking = true;
    try {
      final compiled = compilePlan(project, target, resolver,
          options: options(base: base, sprites: sprites, maxAudioSpeed: maxAudioSpeed));
      transitions._adopt(compiled.plan);
      return compiled;
    } finally {
      transitions
        .._tracking = false
        .._recent.clear();
    }
  }
}

final class _ClipEntry {
  _ClipEntry(this.key, this.lowered);
  final ClipLoweringKey key;
  final LoweredClip lowered;
}

/// The transition part of [PlanMemo].
final class PlanTransitionMemo implements TransitionLayerMemo {
  Expando<_TxEntry> _edits = Expando<_TxEntry>('PlanMemo.transitions');

  /// Entries looked up or stored during the current [PlanMemo.compile] (tracked only there).
  final List<(PlanLayer, _TxEntry)> _recent = [];
  bool _tracking = false;

  /// Edited layers reused.
  int hits = 0;

  /// Edited layers computed.
  int misses = 0;

  @override
  PlanLayer? lookup(PlanLayer input, Object key) {
    final e = _edits[input];
    if (e != null && e.key == key) {
      hits++;
      if (_tracking) _recent.add((input, e));
      return e.output;
    }
    misses++;
    return null;
  }

  @override
  void store(PlanLayer input, Object key, PlanLayer output) {
    final e = _TxEntry(key, output);
    _edits[input] = e;
    if (_tracking) _recent.add((input, e));
  }

  /// Replaces each recent output by the plan's layer of the same id when the compiler only gave
  /// it its packing `seq` (preview plans without a letterbox clip), so the next compile returns
  /// the identical, already-packed layer.
  void _adopt(RenderPlan plan) {
    if (_recent.isEmpty) return;
    final byId = <String, PlanLayer>{};
    for (final (_, e) in _recent) {
      byId[e.output.id] = e.output;
    }
    final finals = <String, PlanLayer>{};
    for (final l in plan.layers) {
      if (byId.containsKey(l.id)) finals[l.id] = l;
    }
    for (final (input, e) in _recent) {
      final f = finals[e.output.id];
      if (f == null || identical(f, e.output)) continue;
      if (withSeq(e.output, f.seq) == f) _edits[input] = _TxEntry(e.key, f);
    }
    _recent.clear();
  }

  /// Forgets everything.
  void clear() {
    _edits = Expando<_TxEntry>('PlanMemo.transitions');
    _recent.clear();
  }
}

final class _TxEntry {
  _TxEntry(this.key, this.output);
  final Object key;
  final PlanLayer output;
}

/// The audio part of [PlanMemo].
final class PlanAudioMemo implements AudioSegMemo {
  Expando<_SegEntry> _segs = Expando<_SegEntry>('PlanMemo.audio');

  /// Segments reused.
  int hits = 0;

  /// Segments computed.
  int misses = 0;

  @override
  AudioSeg? lookup(MediaClip clip, Object key) {
    final e = _segs[clip];
    if (e != null && e.key == key) {
      hits++;
      return e.seg;
    }
    misses++;
    return null;
  }

  @override
  void store(MediaClip clip, Object key, AudioSeg seg) => _segs[clip] = _SegEntry(key, seg);

  /// Forgets everything.
  void clear() => _segs = Expando<_SegEntry>('PlanMemo.audio');
}

final class _SegEntry {
  _SegEntry(this.key, this.seg);
  final Object key;
  final AudioSeg seg;
}
