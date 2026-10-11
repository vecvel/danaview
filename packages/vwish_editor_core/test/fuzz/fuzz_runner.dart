// OWNER: CORE-34
//
// The model fuzzer's runner (BUILD_PLAN CORE-34, ARCH §21.1 "Model fuzzer"). It takes random
// projects (the CORE-08 generator) and random action sequences from every command group, and runs
// them through `EditSession`. After every step it checks:
//
// * **no exceptions escape**: every session call is guarded. A command that is refused with
//   `InternalInconsistency` is also a failure, because that rejection means an exception or a
//   broken invariant inside the command. The two exceptions are a deliberately invalid raw
//   edit, which must be refused this way, and a relink to a shorter file, which the session
//   refuses this way by design;
// * **validator**: the full `validate()` of the current project (working copy included) is empty;
// * **history model**: committed snapshots are modelled (push, coalesce, eviction). Undo, redo and
//   jump land on the identical lanes, markers and settings, and history position, length and
//   editCount match the model. History walks (undo^n then redo^n) run during the sequence and
//   again at the end;
// * **stamps never repeat**: revisions of committed changes strictly increase, and stay below
//   `nextStamp`. A revision never names two different snapshots, and a lane id plus `changedAt`
//   never names two different lanes (the cache keys of the plan, the tiles and the autosave);
// * **JSON round trip**: `decode(encode(p)) == p` without warnings, and a cold re-encode gives
//   identical bytes;
// * **compile + diff/patch identity**: the memoized preview plan validates, and
//   `applyPatch(prev, diffPlans(prev, next))` equals `next` (also through the wire codec). At
//   intervals it also equals a fresh compile without the memo;
// * **dryRun placement equals apply placement**: before each apply (and after each transaction
//   update) the dry run has the same rejection, and the same placements and created lanes by id.
//   Ids are deterministic and the runner rewinds the id counter, so both runs mint the same ids.
//
// The runner never uses package:test, so the nightly CLI (fuzz_main.dart) and the minimizer can
// call it directly. It stops at the first failure.

import 'dart:convert';
import 'dart:math';

import 'package:vwish_editor_core/codec.dart';
import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';
import 'package:vwish_editor_core/plan.dart';

import '../support/random_project.dart';
import 'fuzz_choices.dart';
import 'fuzz_coverage.dart';
import 'fuzz_generator.dart';
import 'fuzz_known_defects.dart';

/// Session settings and check intervals of one run.
final class FuzzConfig {
  /// Creates a config.
  const FuzzConfig({
    this.history = const HistoryPolicy(),
    this.policy = const EditPolicy(),
    this.freshCompileEvery = 25,
    this.wireEvery = 10,
    this.reencodeEvery = 10,
  });

  /// History limits of the session.
  final HistoryPolicy history;

  /// Command policy of the session.
  final EditPolicy policy;

  /// Every n-th plan is also compiled without the memo and compared.
  final int freshCompileEvery;

  /// Every n-th patch also goes through the wire codec.
  final int wireEvery;

  /// Every n-th JSON check also re-encodes the decoded project with a cold codec.
  final int reencodeEvery;

  /// The config a seed uses: mostly defaults, sometimes a short history (eviction), a small byte
  /// budget, the reject overlap policy or tight D-14 caps.
  factory FuzzConfig.forSeed(int seed) {
    final r = Random(seed * 7 + 3);
    final history = switch (r.nextInt(10)) {
      0 => HistoryPolicy(maxEntries: 3 + r.nextInt(30)),
      1 => HistoryPolicy(maxApproxBytes: 2000 + r.nextInt(20000)),
      _ => const HistoryPolicy(),
    };
    final policy = switch (r.nextInt(10)) {
      0 => const EditPolicy(overlap: OverlapPolicy.reject),
      1 => const EditPolicy(maxConcurrentVideoLayers: 2, maxVisualSequences: 3),
      2 => const EditPolicy(maxItems: 120),
      _ => const EditPolicy(),
    };
    return FuzzConfig(history: history, policy: policy);
  }

  /// JSON for fixtures.
  Map<String, Object?> toJson() => {
        'history': {'maxEntries': history.maxEntries, 'maxApproxBytes': history.maxApproxBytes},
        'policy': {
          'overlap': policy.overlap.name,
          'defaultImageUs': policy.defaultImageUs,
          'defaultTextUs': policy.defaultTextUs,
          'defaultCueUs': policy.defaultCueUs,
          'maxConcurrentVideoLayers': policy.maxConcurrentVideoLayers,
          'maxVisualSequences': policy.maxVisualSequences,
          'maxItems': policy.maxItems,
        },
      };

  /// Reads [toJson].
  factory FuzzConfig.fromJson(Map<String, Object?> j) {
    final h = j['history']! as Map<String, Object?>;
    final p = j['policy']! as Map<String, Object?>;
    return FuzzConfig(
      history: HistoryPolicy(maxEntries: h['maxEntries']! as int, maxApproxBytes: h['maxApproxBytes']! as int),
      policy: EditPolicy(
        overlap: OverlapPolicy.values.byName(p['overlap']! as String),
        defaultImageUs: p['defaultImageUs']! as int,
        defaultTextUs: p['defaultTextUs']! as int,
        defaultCueUs: p['defaultCueUs']! as int,
        maxConcurrentVideoLayers: p['maxConcurrentVideoLayers']! as int,
        maxVisualSequences: p['maxVisualSequences']! as int,
        maxItems: p['maxItems']! as int,
      ),
    );
  }
}

/// The project a seed starts from: usually a CORE-08 random project (10–79 items, every rate,
/// some generator features off). One seed in twenty starts from an empty main lane.
EditProject fuzzProject(int seed) {
  final rates = FrameRate.supportedProjectRates;
  final spec = RandomProjectSpec(
    items: 10 + (seed * 37) % 70,
    frameRate: FrameRate(rates[(seed * 7) % rates.length], 1),
    transitions: seed % 5 != 1,
    ramps: seed % 7 != 2,
    keyframes: seed % 3 != 0 || seed % 9 == 0,
    links: seed % 4 != 3,
    markers: seed % 6 != 4,
  );
  final p = randomProject(seed, spec);
  if (seed % 20 != 7) return p;
  final main = p.tracks.firstWhere((t) => t.isMain);
  return p.copyWith(timeline: Timeline(settings: p.settings, tracks: [main.copyWith(items: const [], transitions: const [])]));
}

/// A foreign project for cross-project pastes of run [seed] (index 0..2): another rate sometimes.
EditProject foreignProject(int seed, int index) {
  final rates = FrameRate.supportedProjectRates;
  return randomProject(1000003 + seed * 3 + index,
      RandomProjectSpec(items: 14, frameRate: FrameRate(rates[(seed + index) % rates.length], 1)));
}

/// One fuzz case: the start project, the config and the step choices (random from [seed], or a
/// recording).
final class FuzzCase {
  /// Creates a case.
  FuzzCase({required this.seed, required this.project, required this.config, required this.steps, this.recorded})
      : assert(recorded == null || recorded.length == steps);

  /// The standard case of [seed].
  factory FuzzCase.forSeed(int seed, {int steps = 500}) =>
      FuzzCase(seed: seed, project: fuzzProject(seed), config: FuzzConfig.forSeed(seed), steps: steps);

  /// Seeds the step randomness, the foreign projects and the id tag.
  final int seed;

  /// The start project.
  final EditProject project;

  /// Session settings.
  final FuzzConfig config;

  /// Number of steps.
  final int steps;

  /// Recorded choices per step (replay), or null for random choices.
  final List<List<int>>? recorded;

  /// This case replaying [choices] (same seed, project and config).
  FuzzCase replaying(List<List<int>> choices, {EditProject? project}) =>
      FuzzCase(seed: seed, project: project ?? this.project, config: config, steps: choices.length, recorded: choices);
}

/// What a fuzz check found.
enum FuzzCheck {
  /// An exception escaped a session call (or the runner).
  exception,

  /// A command was refused with `InternalInconsistency` (a bug inside the command).
  internalInconsistency,

  /// The validator found violations.
  validator,

  /// Undo/redo/jump or the history bookkeeping disagreed with the model.
  history,

  /// A revision or lane stamp was reused for different content, or stamps went backwards.
  stamps,

  /// The JSON round trip was not the identity.
  json,

  /// The compiled plan was invalid, or diff/patch was not the identity.
  plan,

  /// The dry run disagreed with the apply.
  dryRun,

  /// A deliberately invalid edit was accepted, or a refused edit changed the project.
  expectation,

  /// A probe injected by a test fired (minimizer tests).
  injected,
}

/// The first failure of a run.
final class FuzzFailure {
  /// Creates a failure.
  const FuzzFailure(this.check, this.step, this.message, {this.action, this.codes = const [], this.defect});

  /// What failed.
  final FuzzCheck check;

  /// The step (the step count for the final history walk).
  final int step;

  /// Details.
  final String message;

  /// The action of the step, if any.
  final String? action;

  /// Stable details of the failure: the sorted violation codes (validator, refusals) or the
  /// exception type. Ids and times are left out, so the minimizer can keep the failure while it
  /// changes them.
  final List<String> codes;

  /// The open defect of fuzz_known_defects.dart this failure matches, or null. Set even when the
  /// run does not tolerate known defects (regression fixtures and their minimization use it).
  final String? defect;

  /// What the minimizer keeps fixed: the check, the known defect and [codes].
  String get signature => [check.name, if (defect != null) defect!, if (codes.isNotEmpty) codes.join(',')].join(':');

  /// JSON for fixtures and reports.
  Map<String, Object?> toJson() => {
        'check': check.name,
        'step': step,
        if (action != null) 'action': action,
        if (codes.isNotEmpty) 'codes': codes,
        if (defect != null) 'defect': defect,
        'signature': signature,
        'message': message,
      };

  /// Reads [toJson].
  factory FuzzFailure.fromJson(Map<String, Object?> j) => FuzzFailure(
        FuzzCheck.values.byName(j['check']! as String),
        j['step']! as int,
        j['message']! as String,
        action: j['action'] as String?,
        codes: [for (final c in (j['codes'] as List<Object?>?) ?? const []) c! as String],
        defect: j['defect'] as String?,
      );

  @override
  String toString() => '$signature at step $step${action == null ? '' : ' ($action)'}: $message';
}

/// The sorted, distinct codes of [violations] (a failure signature).
List<String> violationCodes(Iterable<Violation> violations) => ({for (final v in violations) v.code.name}.toList()..sort());

/// The result of a run.
final class FuzzResult {
  FuzzResult._(this.failure, this.choices, this.coverage, this.stats);

  /// The first failure, or null.
  final FuzzFailure? failure;

  /// The choices drawn per executed step (up to and including the failing one).
  final List<List<int>> choices;

  /// Command coverage of the run.
  final CommandCoverage coverage;

  /// Counters: actions by kind, history entries, plans compiled.
  final Map<String, int> stats;

  /// Whether the run passed.
  bool get passed => failure == null;
}

/// A check a test injects (minimizer tests): returns a message when [project] is "bad".
typedef FuzzProbe = String? Function(EditProject project);

/// Called before each step's action runs (replay tools print the trace with it).
typedef FuzzTrace = void Function(int step, FuzzAction action, EditSession session);

/// Internal: a failed check (unwinds the step).
final class _Fail implements Exception {
  _Fail(this.check, this.message, {this.violations = const [], this.codes = const [], this.defect});
  final FuzzCheck check;
  final String message;
  final List<Violation> violations;
  final List<String> codes;
  final String? defect;
}

/// Plan assets of the fuzz: every pool asset resolves except a deterministic ~8% (offline);
/// some have proxies; bundled looks except `noSuchLook`.
final class FuzzResolver implements PlanAssetResolver {
  /// Creates a resolver over [pool].
  FuzzResolver(this.pool);

  /// The pool.
  final MediaPool pool;

  static int _h(String s) {
    var h = 17;
    for (final u in s.codeUnits) {
      h = (h * 31 + u) & 0x3fffffff;
    }
    return h;
  }

  @override
  ResolvedMedia? original(MediaId id) {
    final a = pool[id];
    if (a == null || a.kind == MediaKind.lut || _h(id) % 13 == 0) return null;
    return ResolvedMedia(uri: 'file:///media/$id', fingerprint: a.fingerprint.quickHash);
  }

  @override
  ResolvedMedia? proxy(MediaId id) =>
      _h(id) % 5 == 1 ? ResolvedMedia(uri: 'file:///cache/proxies/$id.mp4', fingerprint: 'px_$id', isProxy: true) : null;

  @override
  ResolvedLut? builtinLook(String presetId) =>
      presetId == 'noSuchLook' ? null : ResolvedLut(uri: 'file:///app/assets/looks/$presetId.vlut', size: 33);

  @override
  ResolvedLut? importedLut(MediaId id) =>
      pool[id]?.kind == MediaKind.lut && _h(id) % 7 != 0 ? ResolvedLut(uri: 'file:///support/luts/$id.vlut', size: 17) : null;
}

/// [plan] without `req` (informational, not part of a patch).
RenderPlan withoutReq(RenderPlan plan) => RenderPlan(
      v: plan.v,
      rev: plan.rev,
      target: plan.target,
      canvas: plan.canvas,
      durUs: plan.durUs,
      assets: plan.assets,
      layers: plan.layers,
      audio: plan.audio,
    );

/// Whether [a] and [b] hold the identical lanes, markers and settings (the root revision may
/// differ).
bool sameSnapshot(Timeline a, Timeline b) {
  if (!identical(a.settings, b.settings)) return false;
  if (a.tracks.length != b.tracks.length || a.markers.length != b.markers.length) return false;
  for (var i = 0; i < a.tracks.length; i++) {
    if (!identical(a.tracks[i], b.tracks[i])) return false;
  }
  for (var i = 0; i < a.markers.length; i++) {
    if (!identical(a.markers[i], b.markers[i])) return false;
  }
  return true;
}

/// Runs fuzz cases.
final class FuzzRunner {
  FuzzRunner._(this._case, this._probe, this._trace, this._tolerateKnown)
      : _ids = FuzzIds(_case.seed),
        _now = DateTime.utc(2026, 10, 10, 12),
        _generator = ActionGenerator(foreign: (i) => foreignProject(_case.seed, i));

  /// Runs [fuzzCase]. [probe] adds an injected check after every step; [trace] sees each action
  /// before it runs. With [tolerateKnownDefects] (the default) a refusal explained by an open
  /// defect of fuzz_known_defects.dart is counted in the stats (`known:<id>`) instead of failing.
  static FuzzResult run(FuzzCase fuzzCase, {FuzzProbe? probe, FuzzTrace? trace, bool tolerateKnownDefects = true}) =>
      FuzzRunner._(fuzzCase, probe, trace, tolerateKnownDefects)._run();

  final FuzzCase _case;
  final FuzzProbe? _probe;
  final FuzzTrace? _trace;
  final bool _tolerateKnown;
  final FuzzIds _ids;
  final ActionGenerator _generator;
  DateTime _now;
  late final EditSession _s;

  final CommandCoverage _coverage = CommandCoverage();
  final Map<String, int> _stats = {};
  final List<List<int>> _choices = [];

  // History model: committed snapshots, `_states[_cursor]` is the current one.
  final List<Timeline> _states = [];
  int _cursor = 0;
  int _edits = 0;
  bool _evicted = false;

  // Stamps.
  int _lastCommittedRevision = 0;
  final Map<int, Timeline> _revisions = {};
  final Map<String, Track> _lanes = {};

  // Checks of the current project.
  EditProject? _checked;
  final ProjectJsonCodec _codec = ProjectJsonCodec();
  int _jsonChecks = 0;
  final PlanMemo _memo = PlanMemo();
  MediaPool? _resolverPool;
  FuzzResolver? _resolver;
  RenderPlan? _plan;
  int _planRev = 0;

  void _count(String what) => _stats[what] = (_stats[what] ?? 0) + 1;

  FuzzResult _run() {
    FuzzFailure? failure;
    var step = 0;
    String? action;
    FuzzAction? current;
    try {
      _s = EditSession(_case.project, ids: _ids, policy: _case.config.history, editPolicy: _case.config.policy, clock: () => _now);
      _states.add(_s.committedProject.timeline);
      _lastCommittedRevision = _s.committedProject.revision;
      _checkProject(_s.project);
      for (step = 0; step < _case.steps; step++) {
        final recorded = _case.recorded;
        final c = recorded != null ? Choices.replay(recorded[step]) : Choices.random(Random(_mix(_case.seed, step)));
        _choices.add(c.drawn);
        _now = _now.add(Duration(milliseconds: 10 * (1 + c.weighted(const [30, 30, 25, 15]) * 60 + c.below(60))));
        final a = current = _generator.next(_s.committedProject, c);
        action = a.describe();
        _trace?.call(step, a, _s);
        _execute(a);
        action = null;
      }
      action = 'final history walk';
      current = null;
      _s.transaction?.cancel();
      _checkProject(_s.project);
      _walk();
    } on _Fail catch (e) {
      // A known validator defect leaves the project invalid: the run stops there.
      final known = e.check == FuzzCheck.validator
          ? knownDefectOf(DefectContext(kind: DefectKind.validator, action: current, violations: e.violations))
          : null;
      if (known != null && _tolerateKnown) {
        _count('known:${known.id}');
        _stats['stoppedAtStep'] = step;
      } else {
        failure = FuzzFailure(e.check, step, e.message, action: action, codes: e.codes, defect: known?.id ?? e.defect);
      }
    } catch (e, st) {
      failure = FuzzFailure(FuzzCheck.exception, step, '$e\n${_trim(st)}', action: action, codes: ['${e.runtimeType}']);
    }
    _stats['historyEntries'] = _states.length - 1;
    _stats['plans'] = _planRev;
    return FuzzResult._(failure, _choices, _coverage, _stats);
  }

  /// Fails unless an open refusal defect explains [cmd] being refused with [r] and the run
  /// tolerates known defects (then it is counted in the stats).
  void _refused(String what, EditCommand cmd, InternalInconsistency r, EditProject project) {
    final known = knownDefectOf(
        DefectContext(kind: DefectKind.refusal, command: cmd, rejection: r, project: project, policy: _s.editPolicy));
    if (known != null && _tolerateKnown) {
      _count('known:${known.id}');
      return;
    }
    _fail(FuzzCheck.internalInconsistency, '$what$cmd -> $r ${r.violations.take(3).toList()} ${r.detail}',
        codes: violationCodes(r.violations), defect: known?.id);
  }

  static int _mix(int seed, int step) => (seed * 1000003 + step * 7919 + 12345) & 0x7fffffff;

  static String _trim(StackTrace st) => st.toString().split('\n').take(12).join('\n');

  static Never _fail(FuzzCheck check, String message,
          {List<Violation> violations = const [], List<String> codes = const [], String? defect}) =>
      throw _Fail(check, message, violations: violations, codes: codes, defect: defect);

  // -------------------------------------------------------------------------------------------
  // Actions.
  // -------------------------------------------------------------------------------------------

  void _execute(FuzzAction a) {
    switch (a) {
      case ApplyAction():
        _apply(a);
      case UndoAction():
        _count('undo');
        _history(() => _s.undo(), -1);
      case RedoAction():
        _count('redo');
        _history(() => _s.redo(), 1);
      case JumpAction(:final steps):
        _count('jump');
        _history(() => _s.jump(steps), steps);
      case TransactionAction():
        _transaction(a);
      case PoolEditAction():
        _poolEdit(a);
      case PoolChangeAction(:final change):
        _count('poolChange');
        final before = _s.committedProject.timeline;
        _s.applyPoolChange(change);
        if (!identical(_s.committedProject.timeline, before)) _fail(FuzzCheck.history, 'a sticky pool change replaced the timeline');
        _checkProject(_s.project);
      case ViewAction():
        _count('view');
        final before = _s.committedProject.timeline;
        _s.updateView(a.apply);
        if (!identical(_s.committedProject.timeline, before)) _fail(FuzzCheck.history, 'a view update replaced the timeline');
        _checkProject(_s.project);
      case HistoryWalkAction():
        _count('walk');
        _walk();
    }
  }

  void _apply(ApplyAction a) {
    _count('apply');
    for (final change in a.before) {
      _s.applyPoolChange(change);
    }
    final cmd = a.command;
    final committed = _s.committedProject;
    final txOpen = _s.transaction != null;
    final mark = _ids.position;
    final pre = txOpen
        ? dryRun(committed, cmd, EditContext(ids: _ids, policy: _s.editPolicy, now: _now, limits: _s.limits))
        : _s.dryRun(cmd);
    _ids.position = mark;
    final out = _s.apply(cmd, coalesceKey: a.coalesceKey);
    final r = out.rejection;
    _coverage.record(cmd, r != null ? CommandResult.rejected : (out.noop ? CommandResult.noop : CommandResult.applied),
        rejectionCode: r?.code);
    if (a.expect == ApplyExpectation.internalInconsistency) {
      // The limits run before the post-step validation, so an overlap may also exceed a D-14 cap.
      if (r is! InternalInconsistency && r is! LimitExceeded) _fail(FuzzCheck.expectation, 'an invalid raw edit was not refused: $out');
    } else if (r is InternalInconsistency) {
      _refused('', cmd, r, committed);
    }
    _compareDryRun(pre, out, _s.committedProject, 'apply');
    if (!out.changed) {
      if (!identical(_s.committedProject.timeline, committed.timeline)) {
        _fail(FuzzCheck.expectation, 'a refused or no-op command replaced the timeline ($out)');
      }
    } else {
      final merged = _s.committedProject.meta.editCount == committed.meta.editCount;
      if (merged) {
        if (a.coalesceKey == null) _fail(FuzzCheck.history, 'an apply without a coalescing key did not count as an edit');
        _states[_cursor] = _s.committedProject.timeline;
        _count('coalesced');
      } else {
        _push(_s.committedProject.timeline);
      }
      _committedRevisionAdvanced();
    }
    _checkModel();
    _checkProject(_s.project);
  }

  void _history(HistoryStep? Function() op, int delta) {
    final before = _s.committedProject;
    final target = (_cursor + delta).clamp(0, _states.length - 1);
    final st = op();
    if (target == _cursor) {
      if (st != null) _fail(FuzzCheck.history, 'history moved with nothing to move ($st)');
      if (!identical(_s.committedProject.timeline, before.timeline)) _fail(FuzzCheck.history, 'an empty history step changed the timeline');
    } else {
      if (st == null) _fail(FuzzCheck.history, 'history did not move (cursor $_cursor -> $target of ${_states.length - 1})');
      if (st.steps != (target - _cursor).abs()) _fail(FuzzCheck.history, 'step count ${st.steps} for ${target - _cursor}');
      if (!identical(st.project, _s.committedProject)) _fail(FuzzCheck.history, 'HistoryStep.project is not the session project');
      _cursor = target;
      _committedRevisionAdvanced();
    }
    _checkModel();
    _checkProject(_s.project);
  }

  void _transaction(TransactionAction a) {
    _count('transaction');
    final base = _s.committedProject;
    final tx = _s.begin('Fuzz gesture');
    if (!identical(_s.committedProject.timeline, base.timeline)) _fail(FuzzCheck.history, 'begin changed the committed timeline');
    EditOutcome? lastChanged;
    for (final cmd in a.updates) {
      final mark = _ids.position;
      final o = tx.update(cmd);
      final after = _ids.position;
      final r = o.rejection;
      _coverage.record(cmd, r != null ? CommandResult.rejected : (o.noop ? CommandResult.noop : CommandResult.applied),
          rejectionCode: r?.code);
      if (r is InternalInconsistency) _refused('transaction update ', cmd, r, base);
      _ids.position = mark;
      final pv = tx.preview;
      if (pv == null) _fail(FuzzCheck.dryRun, 'no transaction preview after an update');
      _ids.position = max(after, _ids.position);
      _compareDryRun(pv, o, _s.project, 'transaction update');
      if (o.changed) {
        lastChanged = o;
        if (_s.project.revision <= _lastCommittedRevision) _fail(FuzzCheck.stamps, 'a transaction update did not take a fresh stamp');
      } else if (!identical(_s.project.timeline, base.timeline)) {
        _fail(FuzzCheck.history, 'a refused or no-op update does not show the base');
      }
      if (!identical(_s.committedProject.timeline, base.timeline)) _fail(FuzzCheck.history, 'an update changed the committed timeline');
      _checkProject(_s.project);
    }
    switch (a.end) {
      case TransactionEnd.commit:
        final out = tx.commit();
        if (out.changed) {
          _push(_s.committedProject.timeline);
          if (lastChanged == null) _fail(FuzzCheck.history, 'commit recorded an entry although no update changed anything');
          if (_s.committedProject.revision != lastChanged.project.revision) {
            _fail(FuzzCheck.stamps, 'commit did not keep the last update stamp');
          }
          _committedRevisionAdvanced();
        } else if (!identical(_s.committedProject.timeline, base.timeline)) {
          _fail(FuzzCheck.history, 'an empty commit changed the timeline');
        }
        if (tx.isOpen || _s.transaction != null) _fail(FuzzCheck.history, 'commit left the transaction open');
      case TransactionEnd.cancel:
        tx.cancel();
        if (!identical(_s.project.timeline, base.timeline)) _fail(FuzzCheck.history, 'cancel did not restore the base');
      case TransactionEnd.leaveOpen:
        _count('transactionLeftOpen');
    }
    _checkModel();
    _checkProject(_s.project);
  }

  void _poolEdit(PoolEditAction a) {
    _count('poolEdit');
    final before = _s.committedProject;
    final out = _s.applyPoolEdit(a.edit, adjust: a.adjust);
    final r = out.rejection;
    if (r is InternalInconsistency && a.edit is! RelinkAssets) {
      _fail(FuzzCheck.internalInconsistency, '${a.describe()} -> $r', codes: violationCodes(r.violations));
    }
    if (out.changed) {
      if (out.project.meta.editCount != before.meta.editCount + 1) _fail(FuzzCheck.history, 'a pool edit did not count as an edit');
      _push(_s.committedProject.timeline);
      _committedRevisionAdvanced();
    } else if (!identical(_s.committedProject, before)) {
      _fail(FuzzCheck.expectation, 'a refused or empty pool edit changed the committed project');
    }
    _checkModel();
    _checkProject(_s.project);
  }

  /// Undo every entry, then redo every entry, checking each position (JSON and plan at every
  /// eighth position and at both ends).
  void _walk() {
    final top = _s.committedProject.timeline;
    final n = _cursor;
    var undone = 0;
    while (true) {
      final st = _s.undo();
      if (st == null) break;
      if (_cursor == 0) _fail(FuzzCheck.history, 'undo went past the oldest entry');
      _cursor--;
      undone++;
      _committedRevisionAdvanced();
      _checkModel();
      _checkProject(_s.project, light: _cursor % 8 != 0);
    }
    if (undone != n) _fail(FuzzCheck.history, 'undo^n stopped after $undone of $n entries');
    if (!_evicted && !sameSnapshot(_s.committedProject.timeline, _case.project.timeline)) {
      _fail(FuzzCheck.history, 'undo^n did not restore the start project');
    }
    _checkProject(_s.project);
    for (var i = 0; i < n; i++) {
      if (_s.redo() == null) _fail(FuzzCheck.history, 'redo $i of $n did nothing');
      _cursor++;
      _committedRevisionAdvanced();
      _checkModel();
      _checkProject(_s.project, light: _cursor % 8 != 0);
    }
    if (!sameSnapshot(_s.committedProject.timeline, top)) _fail(FuzzCheck.history, 'undo^n then redo^n did not restore the project');
    _checkProject(_s.project);
  }

  // -------------------------------------------------------------------------------------------
  // Model.
  // -------------------------------------------------------------------------------------------

  void _push(Timeline t) {
    _states
      ..removeRange(_cursor + 1, _states.length)
      ..add(t);
    _cursor = _states.length - 1;
    _edits++;
    // The session evicts the oldest entries beyond its limits.
    final evict = _states.length - 1 - _s.history.length;
    if (evict > 0) {
      _states.removeRange(0, evict);
      _cursor -= evict;
      _evicted = true;
      _count('evicted');
    }
  }

  void _committedRevisionAdvanced() {
    final rev = _s.committedProject.revision;
    if (rev <= _lastCommittedRevision) _fail(FuzzCheck.stamps, 'committed revision $rev after $_lastCommittedRevision');
    _lastCommittedRevision = rev;
  }

  void _checkModel() {
    final h = _s.history;
    if (h.position != _cursor || h.length != _states.length - 1) {
      _fail(FuzzCheck.history, 'history ${h.position}/${h.length}, model $_cursor/${_states.length - 1}');
    }
    if (!sameSnapshot(_s.committedProject.timeline, _states[_cursor])) {
      _fail(FuzzCheck.history, 'the committed timeline is not the modelled snapshot at $_cursor');
    }
    if (_s.committedProject.meta.editCount != _case.project.meta.editCount + _edits) {
      _fail(FuzzCheck.history, 'editCount ${_s.committedProject.meta.editCount}, model ${_case.project.meta.editCount + _edits}');
    }
  }

  // -------------------------------------------------------------------------------------------
  // Dry run versus apply.
  // -------------------------------------------------------------------------------------------

  void _compareDryRun(EditPreview pre, EditOutcome out, EditProject result, String what) {
    final a = pre.rejection, b = out.rejection;
    if (a is InternalInconsistency || b is InternalInconsistency) {
      if (a.runtimeType != b.runtimeType) _fail(FuzzCheck.dryRun, '$what: dry run $a, apply $b');
      return;
    }
    if (a != b) _fail(FuzzCheck.dryRun, '$what: dry run rejection $a, apply $b');
    if (!out.changed) return;
    final tracks = result.tracks;
    final created = <TrackId, NewTrack>{
      for (var i = 0; i < tracks.length; i++)
        if (out.createdTracks.contains(tracks[i].id)) tracks[i].id: NewTrack(id: tracks[i].id, kind: tracks[i].kind, index: i),
    };
    final expected = <ItemId, Placement>{};
    final index = result.index;
    for (final id in out.affected) {
      final loc = index.locate(id);
      if (loc == null) continue;
      expected[id] = Placement(loc.track.id, loc.item.range, newTrack: created[loc.track.id]);
    }
    if (pre.placements.length != expected.length) {
      _fail(FuzzCheck.dryRun, '$what: ${pre.placements.length} placements, apply affected ${expected.length}');
    }
    expected.forEach((id, p) {
      if (pre.placements[id] != p) _fail(FuzzCheck.dryRun, '$what: $id dry run ${pre.placements[id]}, apply $p');
    });
    final createdList = created.values.toList();
    if (pre.createsTracks.length != createdList.length ||
        !Iterable<int>.generate(createdList.length).every((i) => pre.createsTracks[i] == createdList[i])) {
      _fail(FuzzCheck.dryRun, '$what: dry run creates ${pre.createsTracks}, apply $createdList');
    }
  }

  // -------------------------------------------------------------------------------------------
  // Project checks: validator, stamps, JSON, plan.
  // -------------------------------------------------------------------------------------------

  final Stopwatch _clock = Stopwatch();

  /// Adds the time since [t0] µs to the `us:<what>` stat.
  void _took(String what, int t0) => _stats['us:$what'] = (_stats['us:$what'] ?? 0) + _clock.elapsedMicroseconds - t0;

  void _checkProject(EditProject p, {bool light = false}) {
    if (identical(p, _checked)) return;
    _checked = p;
    if (!_clock.isRunning) _clock.start();
    var t0 = _clock.elapsedMicroseconds;
    final violations = validate(p);
    _took('validate', t0);
    if (violations.isNotEmpty) {
      _fail(FuzzCheck.validator, '${violations.length} violations: ${violations.take(4).toList()}',
          violations: violations, codes: violationCodes(violations));
    }
    _checkStamps(p);
    final probe = _probe;
    if (probe != null) {
      final m = probe(p);
      if (m != null) _fail(FuzzCheck.injected, m);
    }
    if (light) return;
    t0 = _clock.elapsedMicroseconds;
    _checkJson(p);
    _took('json', t0);
    t0 = _clock.elapsedMicroseconds;
    _checkPlan(p);
    _took('plan', t0);
  }

  void _checkStamps(EditProject p) {
    final next = _s.nextStamp;
    final rev = p.revision;
    if (rev >= next) _fail(FuzzCheck.stamps, 'revision $rev is not below nextStamp $next');
    final seen = _revisions[rev];
    if (seen != null && !sameSnapshot(seen, p.timeline)) _fail(FuzzCheck.stamps, 'revision $rev names two different snapshots');
    _revisions[rev] = p.timeline;
    for (final t in p.tracks) {
      if (t.changedAt >= next) _fail(FuzzCheck.stamps, 'lane ${t.id} changedAt ${t.changedAt} is not below nextStamp $next');
      final key = '${t.id}@${t.changedAt}';
      final old = _lanes[key];
      if (old == null) {
        _lanes[key] = t;
      } else if (!identical(old, t) && old != t) {
        _fail(FuzzCheck.stamps, 'lane ${t.id} changed but kept changedAt ${t.changedAt}');
      }
    }
  }

  void _checkJson(EditProject p) {
    _jsonChecks++;
    final text = _codec.encode(p);
    final decoded = _codec.decode(text);
    if (decoded.warnings.isNotEmpty) _fail(FuzzCheck.json, 'decode warnings ${decoded.warnings.take(3).toList()}');
    if (decoded.project != p) _fail(FuzzCheck.json, 'decode(encode(p)) != p${_jsonDiff(p, decoded.project)}');
    if (_jsonChecks % _case.config.reencodeEvery == 0) {
      final cold = ProjectJsonCodec().encode(decoded.project);
      if (cold != text) _fail(FuzzCheck.json, 'a cold re-encode of the decoded project differs');
      if (jsonEncode(_codec.toJson(p)) != text) _fail(FuzzCheck.json, 'toJson differs from the cached encode');
    }
  }

  static String _jsonDiff(EditProject a, EditProject b) {
    if (a.meta != b.meta) return ' (meta)';
    if (a.view != b.view) return ' (view)';
    if (a.pool != b.pool) return ' (pool)';
    if (a.settings != b.settings) return ' (settings)';
    if (a.markers.length != b.markers.length) return ' (markers)';
    for (var i = 0; i < a.tracks.length && i < b.tracks.length; i++) {
      final x = a.tracks[i], y = b.tracks[i];
      if (x == y) continue;
      for (var j = 0; j < x.items.length && j < y.items.length; j++) {
        if (x.items[j] != y.items[j]) return ' (lane ${x.id} item ${x.items[j].id})';
      }
      return ' (lane ${x.id})';
    }
    return '';
  }

  void _checkPlan(EditProject p) {
    if (!identical(_resolverPool, p.pool)) {
      _resolverPool = p.pool;
      _resolver = FuzzResolver(p.pool);
    }
    final resolver = _resolver!;
    final rev = ++_planRev;
    final plan = _memo.compile(p, PlanTarget.preview, resolver, base: CompileOptions(rev: rev)).plan;
    final pv = PlanValidator.validate(plan);
    if (pv.isNotEmpty) {
      final d = knownDefectOf(DefectContext(kind: DefectKind.plan, planViolations: pv, project: p));
      if (d != null && _tolerateKnown) {
        _count('known:${d.id}');
      } else {
        _fail(FuzzCheck.plan, 'plan violations ${pv.take(4).toList()}',
            codes: ({for (final v in pv) v.code.name}.toList()..sort()), defect: d?.id);
      }
    }
    if (rev % _case.config.freshCompileEvery == 0) {
      final fresh = compilePlan(p, PlanTarget.preview, resolver, options: CompileOptions(rev: rev, stages: standardLoweringStages())).plan;
      if (fresh != plan) _fail(FuzzCheck.plan, 'the memoized plan differs from a fresh compile');
    }
    final prev = _plan;
    if (prev != null) {
      final patch = diffPlans(prev, plan);
      if (withoutReq(applyPatch(prev, patch)) != withoutReq(plan)) _fail(FuzzCheck.plan, 'applyPatch(prev, diff(prev, next)) != next');
      if (rev % _case.config.wireEvery == 0) {
        final wire = PlanJson.decodePatchBytes(PlanJson.encodePatchBytes(patch));
        if (withoutReq(applyPatch(prev, wire)) != withoutReq(plan)) _fail(FuzzCheck.plan, 'the patch changed through the wire codec');
      }
    }
    _plan = plan;
  }
}
