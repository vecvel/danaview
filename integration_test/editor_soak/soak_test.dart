// OWNER: QA-05
//
// QA-05 (BUILD_PLAN M6): the random-edit robustness soak. One long `testWidgets` drives the real
// app (QA-00's `E2eApp` wiring, production engine) for `DV_SOAK_MINUTES` (60 by default) with a
// seeded random sequence of:
//
//   * edits through the action registry and the panels' commands: split, undo/redo, copy/paste,
//     duplicate, delete/ripple delete, text, markers, speed, transitions, zoom, select all;
//   * gestures through the timeline's drag delegate: move with snapping, trim handles; keyboard
//     frame steps;
//   * playback: play/pause, scrub gestures (begin/scrubTo/end), exact seeks;
//   * jobs: export starts that are cancelled, completed or backgrounded mid-way; Auto captions with
//     the tiny model, completed or cancelled; reverse, freeze frame and proxy jobs, waited for or
//     cancelled;
//   * interruptions: background/foreground (host), a call or Siri (Android emulator: a real GSM
//     call from the host; iOS Simulator: the inactive -> resumed lifecycle such an overlay
//     produces), audio route change (host, where the platform can do it), low storage (host, where
//     it is safe), media going offline mid-session (a sandbox file moved away and back);
//   * close/reopen of the project with a store-level validity check.
//
// A warm-up runs every op once (so the speech model, encoder and caches are loaded), then the
// memory baseline is taken. Acceptance (BUILD_PLAN QA-05): no crash (the host sees the process
// survive), no unhandled exception (FlutterError and zone errors fail the test and are attributed
// to the op), no op stuck past its bounded wait, memory growth <= 10 % (median RSS of the first
// samples after the warm-up vs the last tenth), the project always reopens valid.
//
// Run through the host driver (it serves the handshake and samples the process from outside):
//   python3 -I integration_test/editor_soak/tool/soak_host.py -p ios -d <udid> soak --minutes 60
// The same file runs without a host (`flutter test integration_test/editor_soak/soak_test.dart
// -d <device> --dart-define=DANAVIEW_EDITOR=true ...`); the host-only interruptions are then
// reported as skipped.

// ignore_for_file: implementation_imports, avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor/src/app/strings/captions_strings.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart' show EditorActionResult;
import 'package:danaview_editor/src/editor/contracts/action_binding.dart' show EditorActionSource;
import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor/src/editor/flows/export/export_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show EditorTaskKind;
import 'package:danaview_editor/src/editor/state/tasks_controller.dart' show TasksController;
import 'package:danaview_editor_core/codec.dart' show ProjectJsonCodec;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/plan.dart' show ExportContainer, ExportPresetId, VideoCodec;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../editor/support/e2e.dart';
import 'support/soak.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'QA-05 robustness soak (${SoakConfig.minutes} min)',
    (tester) async {
      final errors = SoakErrors()..install();
      try {
        await _Soak(tester, errors).run();
      } finally {
        errors.uninstall();
      }
    },
    timeout: const Timeout(Duration(minutes: SoakConfig.minutes + 45)),
  );
}

/// Why an op did not run (not a failure).
final class _Skip implements Exception {
  _Skip(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

final class _OpStats {
  int ran = 0;
  int skipped = 0;
  int failed = 0;
  Map<String, Object?> toJson() => {'ran': ran, 'skipped': skipped, 'failed': failed};
}

final class _Soak {
  _Soak(this.tester, this.errors) : rng = math.Random(SoakConfig.seed);

  final WidgetTester tester;
  final SoakErrors errors;
  final math.Random rng;
  final MemorySampler memory = MemorySampler();
  final Map<String, _OpStats> stats = {};
  final List<String> failures = [];
  final List<String> reopenProblems = [];
  final Map<String, String> unavailable = {};
  final Stopwatch clock = Stopwatch();

  E2eEditor? _ed;
  int _op = 0;
  int _projects = 0;
  bool _captionsReady = false;
  bool _lowStorage = false;
  final List<String> _mediaCopies = [];
  String? _offlineCandidate;

  E2eEditor get ed => _ed ?? (throw StateError('no editor open'));

  // -----------------------------------------------------------------------------------------------
  // The run
  // -----------------------------------------------------------------------------------------------

  Future<void> run() async {
    soakLog('start', 'seed ${SoakConfig.seed} minutes ${SoakConfig.minutes} platform ${Platform.operatingSystem} '
        'host ${E2eHandshake.available} captions ${SoakConfig.captions}');
    await E2eApp.launch(tester);
    if (SoakConfig.captions) {
      _captionsReady = await E2eApp.stageSpeechModel();
      if (!_captionsReady) unavailable['captions'] = 'tiny model not staged in ${E2eConfig.modelsDir}';
    } else {
      unavailable['captions'] = 'DV_SOAK_CAPTIONS=false';
    }
    await _newProject();
    clock.start();
    final deadline = DateTime.now().add(const Duration(minutes: SoakConfig.minutes));

    // Warm-up: every op once, in a fixed order.
    for (final op in _ops) {
      await _step(op);
    }
    memory.markBaseline();
    soakLog('baseline', 'warm-up done after ${clock.elapsed.inSeconds} s, $_op ops');

    final total = _ops.fold<int>(0, (s, o) => s + o.weight);
    while (DateTime.now().isBefore(deadline)) {
      var pick = rng.nextInt(total);
      final op = _ops.firstWhere((o) => (pick -= o.weight) < 0);
      await _step(op);
      if (_op % 25 == 0) await _step(_reopenOp);
      if (_op % 50 == 0) _progress();
    }

    // Wrap up: nothing left open, the project reopens valid one last time.
    await soakDismissAll(tester, _ed);
    await _step(_reopenOp);
    if (_lowStorage) await _host('freeStorage');
    await ed.close();
    _ed = null;
    final verdict = memory.verdict();
    _progress();
    final summary = {
      'seed': SoakConfig.seed,
      'minutes': SoakConfig.minutes,
      'elapsedS': clock.elapsed.inSeconds,
      'ops': _op,
      'projects': _projects,
      'platform': Platform.operatingSystem,
      'host': E2eHandshake.available,
      'stats': {for (final e in stats.entries) e.key: e.value.toJson()},
      'failures': failures,
      'frameworkErrors': errors.framework,
      'reopenProblems': reopenProblems,
      'unavailable': unavailable,
      'memory': {
        'verdict': verdict?.toString(),
        'growth': verdict?.growth,
        'ok': verdict?.ok,
        'samples': [for (final s in memory.samples) s.toJson()],
      },
    };
    soakWriteJson('summary', summary);
    // The same summary (without the samples) in the log: a failing run is uninstalled by
    // `flutter test` before the host can copy the JSON.
    soakLog('summary', jsonEncode({...summary, 'memory': {...summary['memory']! as Map<String, Object?>, 'samples': memory.samples.length}}));
    soakLog('memory', verdict?.toString() ?? 'too few samples for a verdict');
    soakLog('end', 'ops $_op, failures ${failures.length}, framework errors ${errors.framework.length}, '
        'reopen problems ${reopenProblems.length}, unavailable ${unavailable.keys.toList()}');

    expect(failures, isEmpty, reason: 'ops that hung or threw');
    expect(errors.framework, isEmpty, reason: 'unhandled framework errors');
    expect(reopenProblems, isEmpty, reason: 'the project must always reopen valid');
    expect(verdict, isNotNull, reason: 'memory samples');
    expect(verdict!.ok, isTrue, reason: 'memory growth: $verdict');
  }

  void _progress() {
    final s = memory.samples.isEmpty ? null : memory.samples.last;
    soakLog('progress', '${clock.elapsed.inMinutes} min, $_op ops, ${failures.length} failures, '
        'rss ${s == null ? '?' : (s.rssBytes / (1 << 20)).toStringAsFixed(0)} MB, project #$_projects');
  }

  Future<void> _step(_Op op) async {
    _op++;
    final n = _op;
    errors.current = '#$n ${op.name}';
    final st = stats.putIfAbsent(op.name, _OpStats.new);
    final sw = Stopwatch()..start();
    try {
      final outcome = await op.run(this);
      st.ran++;
      soakLog('op', '#$n ${op.name} ${outcome.isEmpty ? 'ok' : outcome} ${sw.elapsedMilliseconds} ms');
    } on _Skip catch (s) {
      st.skipped++;
      soakLog('op', '#$n ${op.name} skipped: ${s.reason}');
    } on TestFailure catch (e) {
      // A bounded wait ran out: the app hung on this op.
      st.failed++;
      final line = '#$n ${op.name}: stuck: ${e.message?.split('\n').first}';
      failures.add(line);
      soakLog('fail', '$line\n${e.message}');
      await _recover();
    } on Object catch (e, stack) {
      st.failed++;
      final line = '#$n ${op.name}: ${e.runtimeType}: ${'$e'.split('\n').first}';
      failures.add(line);
      soakLog('fail', '$line ${stack.toString().split('\n').take(4).join(' | ')}');
      await _recover();
    }
    memory.sample();
    await _boundProject();
  }

  /// After a failed op: close what is open and get back to an editor that is ready.
  Future<void> _recover() async {
    try {
      await soakDismissAll(tester, _ed);
      final e = _ed;
      if (e != null && find.byType(EditorScreen).evaluate().isNotEmpty && e.state.isReady) return;
      soakLog('recover', 'reopening the project');
      if (find.byType(EditorScreen).evaluate().isNotEmpty) await e?.close();
      if (e != null) {
        _ed = (await soakOpenProject(tester, e.id)).$1;
      } else {
        await _newProject();
      }
    } on Object catch (err) {
      soakLog('recover', 'reopen failed (${err.runtimeType}); starting a new project');
      failures.add('recover: could not reopen the project: $err');
      await E2eApp.launch(tester);
      await _newProject();
    }
  }

  /// Keeps the project small enough that an hour of random edits stays meaningful: past 40 items,
  /// 10 tracks or 4 minutes, the project is closed, deleted and replaced by a fresh one.
  Future<void> _boundProject() async {
    final e = _ed;
    if (e == null || find.byType(EditorScreen).evaluate().isEmpty || !e.state.isReady) return;
    final p = e.project;
    final items = p.tracks.fold<int>(0, (s, t) => s + t.items.length);
    if (items <= 40 && p.tracks.length <= 10 && p.duration <= 240000000) return;
    soakLog('rotate', 'project #$_projects has $items items, ${p.tracks.length} tracks, ${p.duration ~/ 1000000} s');
    await soakDismissAll(tester, e);
    await e.close();
    final problems = await soakStoreCheck(tester, e.id);
    reopenProblems.addAll(problems.map((x) => 'project #$_projects: $x'));
    await E2eApp.pumpWhile(tester, E2eApp.world.runtime.repository.delete(e.id), what: 'delete the old project');
    _ed = null;
    await _newProject();
  }

  Future<void> _newProject() async {
    _projects++;
    for (final f in _mediaCopies) {
      try {
        File(f).deleteSync();
      } on FileSystemException {
        // In use by a deleted project only; already gone.
      }
    }
    _mediaCopies.clear();
    final tag = 'soak$_projects';
    final media = [
      SoakMedia.copy(Fx.frameCounter, tag),
      SoakMedia.copy(Fx.toneUnderVideo, tag),
      SoakMedia.copy(Fx.clapFlash, tag),
      SoakMedia.copy(Fx.still4k, tag),
      SoakMedia.copy(Fx.speech, tag),
    ];
    _mediaCopies.addAll(media);
    _offlineCandidate = media[2];
    _ed = await E2eEditor.createProject(tester, name: 'Soak ${SoakConfig.seed} #$_projects', media: media);
    soakLog('project', '#$_projects ${_ed!.id}');
  }

  // -----------------------------------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------------------------------

  T _pick<T>(List<T> list) => list[rng.nextInt(list.length)];

  List<TimelineItem> get _allItems => [for (final t in ed.project.tracks) ...t.items];

  /// Waits [d] of real time while pumping frames.
  Future<void> _hold(Duration d) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
  }

  /// A host action; returns null (and records why) when the host cannot do it here.
  Future<E2eAck?> _host(String action, {Map<String, Object?> args = const {}, Duration timeout = const Duration(seconds: 90)}) async {
    if (!E2eHandshake.available) {
      unavailable[action] = 'no host driver';
      return null;
    }
    final ack = await E2eHandshake.request(tester, action, args: args, timeout: timeout);
    if (!ack.ok) {
      unavailable[action] = ack.detail;
      return null;
    }
    return ack;
  }

  /// The inactive -> resumed transition a call banner, Siri or Control Center produces.
  Future<void> _lifecycleBlip(Duration away) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await _hold(away);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> _seekRandom() async {
    final frames = ed.rate.frameIndexOf(ed.project.duration);
    if (frames <= 1) return;
    await ed.seekFrame(rng.nextInt(frames - 1));
  }

  Future<void> _waitEditorIdle() async {
    await E2eApp.pumpUntil(tester, () => !ed.playhead.isSeeking, what: 'the playhead to settle');
  }

  // -----------------------------------------------------------------------------------------------
  // Ops
  // -----------------------------------------------------------------------------------------------

  static final _reopenOp = _Op('reopen', 0, (s) => s._reopen());

  static final List<_Op> _ops = [
    _Op('seek', 8, (s) async {
      await s._seekRandom();
      return 'frame ${s.ed.playheadFrame}';
    }),
    _Op('scrub', 5, (s) => s._scrub()),
    _Op('play', 6, (s) => s._play()),
    _Op('frameStep', 3, (s) async {
      final key = s.rng.nextBool() ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft;
      final n = 1 + s.rng.nextInt(4);
      for (var i = 0; i < n; i++) {
        await s.ed.key(key);
      }
      await s._waitEditorIdle();
      return '$n x ${key.keyLabel}';
    }),
    _Op('split', 6, (s) => s._split()),
    _Op('undo', 6, (s) async => (await s.ed.tryInvoke(EditorActionId.undo)).name),
    _Op('redo', 4, (s) async => (await s.ed.tryInvoke(EditorActionId.redo)).name),
    _Op('copyPaste', 3, (s) => s._copyPaste()),
    _Op('duplicate', 3, (s) async {
      await s.ed.select(s._pick(s._allItems).id);
      return (await s.ed.tryInvoke(EditorActionId.duplicate)).name;
    }),
    _Op('delete', 3, (s) async {
      if (s._allItems.length <= 4) throw _Skip('keeping at least 4 items');
      await s.ed.select(s._pick(s._allItems).id);
      return (await s.ed.tryInvoke(s.rng.nextBool() ? EditorActionId.delete : EditorActionId.rippleDelete)).name;
    }),
    _Op('dragMove', 4, (s) => s._dragMove()),
    _Op('dragTrim', 4, (s) => s._dragTrim()),
    _Op('text', 3, (s) => s._text()),
    _Op('marker', 2, (s) async => (await s.ed.tryInvoke(EditorActionId.addMarker)).name),
    _Op('speed', 3, (s) => s._speed()),
    _Op('transition', 2, (s) => s._transition()),
    _Op('zoom', 3, (s) async => (await s.ed.tryInvoke(s._pick(const [EditorActionId.zoomIn, EditorActionId.zoomOut, EditorActionId.zoomFit]))).name),
    _Op('selectAll', 1, (s) async {
      final r = await s.ed.tryInvoke(EditorActionId.selectAll);
      await s.ed.tryInvoke(EditorActionId.escape);
      return r.name;
    }),
    _Op('reverse', 2, (s) => s._reverse()),
    _Op('freeze', 2, (s) => s._freeze()),
    _Op('proxy', 1, (s) => s._proxy()),
    _Op('export', 2, (s) => s._export()),
    _Op('captions', 1, (s) => s._captions()),
    _Op('background', 2, (s) => s._background()),
    _Op('inactive', 2, (s) async {
      final playing = s.rng.nextBool();
      if (playing) await s.ed.transport.play();
      await s._lifecycleBlip(Duration(milliseconds: 300 + s.rng.nextInt(2000)));
      await s.ed.waitPlaying(false);
      return playing ? 'during playback (paused)' : 'idle';
    }),
    _Op('call', 1, (s) => s._call()),
    _Op('audioRoute', 1, (s) => s._audioRoute()),
    _Op('offline', 1, (s) => s._offline()),
    _Op('lowStorage', 1, (s) => s._lowStorageOp()),
    _reopenOp,
  ];

  Future<String> _scrub() async {
    final p = ed.playhead;
    final dur = ed.project.duration;
    p.beginScrub();
    var t = rng.nextInt(math.max(1, dur));
    for (var i = 0; i < 15; i++) {
      t = (t + (rng.nextInt(2000000) - 1000000)).clamp(0, math.max(0, dur - 1));
      p.scrubTo(t);
      await tester.pump(const Duration(milliseconds: 16));
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    await E2eApp.pumpWhile(tester, p.endScrub(), what: 'end of the scrub');
    await _waitEditorIdle();
    return 'ended at frame ${ed.playheadFrame}';
  }

  Future<String> _play() async {
    if (!ed.transport.canPlay) throw _Skip('nothing to play');
    await ed.transport.play();
    await ed.waitPlaying(true);
    await _hold(Duration(milliseconds: 300 + rng.nextInt(1700)));
    await ed.transport.pause();
    await ed.waitPlaying(false);
    return 'stopped at frame ${ed.playheadFrame}';
  }

  Future<String> _split() async {
    final clips = [for (final i in ed.mainTrack.items) if (i.duration >= ed.rate.timeOfFrame(4)) i];
    if (clips.isEmpty) throw _Skip('no clip long enough');
    final c = _pick(clips);
    final first = ed.rate.frameIndexOf(c.start) + 1;
    final last = ed.rate.frameIndexOf(c.end) - 2;
    if (last <= first) throw _Skip('clip too short');
    await ed.seekFrame(first + rng.nextInt(last - first));
    await ed.select(c.id);
    return (await ed.tryInvoke(EditorActionId.split)).name;
  }

  Future<String> _copyPaste() async {
    await ed.select(_pick(_allItems).id);
    final copied = await ed.tryInvoke(rng.nextInt(4) == 0 ? EditorActionId.cut : EditorActionId.copy);
    await _seekRandom();
    final pasted = await ed.tryInvoke(EditorActionId.paste);
    return '${copied.name}/${pasted.name}';
  }

  Future<String> _dragMove() async {
    final items = [for (final i in _allItems) if (!ed.trackOf(i.id).locked) i];
    if (items.isEmpty) throw _Skip('nothing movable');
    final it = _pick(items);
    final to = ed.rate.timeOfFrame(rng.nextInt(math.max(1, ed.rate.frameIndexOf(ed.project.duration))));
    await ed.dragMove(it.id, to, overshootPx: rng.nextDouble() * 6 - 3);
    return 'to frame ${ed.rate.frameIndexOf(to)}';
  }

  Future<String> _dragTrim() async {
    final items = [for (final i in _allItems) if (i.duration >= ed.rate.timeOfFrame(6) && !ed.trackOf(i.id).locked) i];
    if (items.isEmpty) throw _Skip('nothing trimmable');
    final it = _pick(items);
    final edge = rng.nextBool() ? TrimEdge.start : TrimEdge.end;
    final span = ed.rate.frameIndexOf(it.duration);
    final delta = rng.nextInt(span ~/ 2) - span ~/ 4;
    final from = edge == TrimEdge.start ? it.start : it.end;
    final to = math.max(0, from + ed.rate.timeOfFrame(delta.abs()) * delta.sign);
    await ed.dragTrim(it.id, edge, to);
    return '${edge.name} by $delta frames';
  }

  Future<String> _text() async {
    final before = ed.items<TextItem>().length;
    final r = await ed.tryInvoke(EditorActionId.addText);
    if (r != EditorActionResult.ran) return r.name;
    await ed.waitProject((p) => ed.items<TextItem>().length > before, what: 'the new text');
    final t = ed.items<TextItem>().last;
    ed.controller.apply(SetText(t.id, 'Soak ${rng.nextInt(1 << 20)}'));
    await tester.pump();
    await soakDismissAll(tester, ed);
    return 'text added';
  }

  Future<String> _speed() async {
    final clips = ed.videoClips;
    if (clips.isEmpty) throw _Skip('no video clip');
    final speed = _pick(const [0.5, 1.0, 1.5, 2.0]);
    final r = ed.controller.apply(SetSpeed(_pick(clips).id, ConstantSpeed(speed)));
    await tester.pump();
    return '${speed}x ${r.runtimeType}';
  }

  Future<String> _transition() async {
    final items = ed.mainTrack.items;
    final cuts = [
      for (var i = 1; i < items.length; i++)
        if (items[i - 1].end == items[i].start) TransitionRef(ed.mainTrack.id, items[i - 1].id, items[i].id),
    ];
    if (cuts.isEmpty) throw _Skip('no cut');
    final frames = _pick(const [6, 10, 15]);
    final r = ed.controller.apply(SetTransition(_pick(cuts), TransitionSpec(TransitionKind.crossDissolve, frames), clamp: true));
    await tester.pump();
    return 'cross dissolve $frames f ${r.runtimeType}';
  }

  /// Waits for task [kind] to end; with [cancelAfterStart] it cancels it once it has progress.
  Future<String> _task(EditorTaskKind kind, {required bool cancelAfterStart, Duration timeout = const Duration(seconds: 120)}) async {
    String? id;
    await E2eApp.pumpUntil(
      tester,
      () {
        final t = ed.state.tasks.where((t) => t.kind == kind).firstOrNull;
        if (t != null) id = t.id;
        return t != null || id != null;
      },
      what: 'the ${kind.name} task to start',
      timeout: const Duration(seconds: 15),
    ).onError<TestFailure>((_, __) {});
    if (id == null) return 'finished before it showed';
    if (cancelAfterStart && ed.tasks.canCancel(id!)) {
      await E2eApp.pumpUntil(tester, () => (ed.tasks.progressOf(id!) ?? 0) > 0 || !ed.state.tasks.any((t) => t.id == id),
          what: 'progress of ${kind.name}', timeout: const Duration(seconds: 30));
      if (ed.tasks.canCancel(id!)) {
        ed.tasks.cancel(id!);
        await E2eApp.pumpUntil(tester, () => !ed.state.tasks.any((t) => t.id == id && !t.failed),
            what: 'the ${kind.name} task to cancel', timeout: const Duration(seconds: 30));
        return 'cancelled';
      }
    }
    await E2eApp.pumpUntil(tester, () => !ed.state.tasks.any((t) => t.id == id && !t.failed), what: 'the ${kind.name} task', timeout: timeout);
    final failed = ed.state.tasks.where((t) => t.id == id && t.failed).toList();
    if (failed.isNotEmpty) throw StateError('the ${kind.name} task failed');
    return 'completed';
  }

  Future<String> _reverse() async {
    final clips = [for (final c in ed.videoClips) if (c.duration <= 10000000) c];
    if (clips.isEmpty) throw _Skip('no short video clip');
    final clip = _pick(clips);
    await ed.select(clip.id);
    final r = await ed.tryInvoke(EditorActionId.reverse);
    if (r != EditorActionResult.ran) return r.name;
    final now = ed.item(clip.id) as MediaClip;
    if (!now.reversed) return 'turned off (plays forward)';
    final rendition = TasksController.renditionFor(ed.project.pool, now);
    if (rendition?.status is ReadyStatus) return 'reused a ready rendition';
    return _task(EditorTaskKind.reverse, cancelAfterStart: rng.nextInt(3) == 0);
  }

  Future<String> _freeze() async {
    final clips = ed.videoClips;
    if (clips.isEmpty) throw _Skip('no video clip');
    final c = _pick(clips);
    final first = ed.rate.frameIndexOf(c.start) + 1;
    final last = ed.rate.frameIndexOf(c.end) - 1;
    if (last <= first) throw _Skip('clip too short');
    await ed.seekFrame(first + rng.nextInt(last - first));
    await ed.select(c.id);
    final r = await ed.tryInvoke(EditorActionId.freeze);
    if (r != EditorActionResult.ran) return r.name;
    await E2eApp.waitKey(tester, 'freeze.sheet');
    await E2eApp.tapKey(tester, 'freeze.confirm');
    return _task(EditorTaskKind.freeze, cancelAfterStart: false);
  }

  Future<String> _proxy() async {
    final assets = [
      for (final a in ed.project.pool.assets.values)
        if (a.kind == MediaKind.video && a.status is ReadyStatus && a.proxy != ProxyState.ready && a.derived == null) a,
    ];
    if (assets.isEmpty) throw _Skip('every video has a proxy');
    final a = _pick(assets);
    if (!ed.tasks.requestProxy(a.id)) return 'not started';
    await tester.pump();
    return _task(EditorTaskKind.proxy, cancelAfterStart: rng.nextBool(), timeout: const Duration(minutes: 3));
  }

  Future<String> _export() async {
    if (ed.state.tasks.any((t) => !t.failed)) {
      // Export waits for pending renditions; let them finish first so the op measures export.
      await E2eApp.pumpUntil(tester, () => !ed.state.tasks.any((t) => !t.failed), what: 'tasks before export', timeout: const Duration(minutes: 3));
    }
    final r = await ed.tryInvoke(EditorActionId.export);
    if (r != EditorActionResult.ran) return r.name;
    await E2eApp.waitKey(tester, 'export-sheet');
    await E2eApp.pumpUntil(
      tester,
      () => ed.exportState is ExportUiSetup || ed.exportState is ExportUiNeedsRelink || ed.exportState is ExportUiWaiting || ed.exportState is ExportUiFailed,
      what: 'the export setup',
    );
    if (ed.exportState is! ExportUiSetup) {
      final blocked = ed.exportState.runtimeType;
      await soakDismissAll(tester, ed);
      return 'blocked: $blocked';
    }
    final c = ed.export;
    c.selectPreset(ExportPresetId.custom);
    c.updateSettings((s) => s.copyWith(shortSide: 720, container: ExportContainer.mp4, codec: VideoCodec.h264));
    c.setDestination(ExportDestination.files);
    await tester.pump();
    final handoffs = E2eApp.world.engine.files.records.length;
    await E2eApp.tapKey(tester, 'export-start');
    final mode = _pick(const ['cancel', 'cancel', 'complete', 'background']);
    var backgrounded = false;
    var paused = false;
    final watch = _ExportWatch(this, handoffs);
    await watch.until((s) => switch (s) {
          ExportUiRunning(:final fraction) => mode != 'complete' && fraction > 0.05,
          ExportUiCompleted() => watch.delivered,
          ExportUiFailed() => _lowStorage,
          ExportUiSetup(:final issue) => issue != null && _lowStorage,
          _ => false,
        }, what: 'the export to run');
    var outcome = '';
    final now = ed.exportState;
    if (now is ExportUiRunning) {
      if (mode == 'background') {
        final ack = await _host('background', args: {'seconds': 2 + rng.nextInt(4)});
        backgrounded = ack != null;
        if (!backgrounded) await _lifecycleBlip(const Duration(seconds: 2));
        await watch.until((s) => (s is ExportUiCompleted && watch.delivered) || s is ExportUiInterrupted,
            what: 'the export to finish after the interruption');
        paused = paused || watch.paused;
        if (ed.exportState is ExportUiInterrupted) {
          final st = ed.exportState as ExportUiInterrupted;
          outcome = 'interrupted (resumable ${st.canResume})';
          if (st.canResume) {
            await c.resume();
            await watch.until((s) => s is ExportUiCompleted && watch.delivered, what: 'the resumed export');
            outcome += ', resumed';
          }
        } else {
          outcome = 'completed after ${backgrounded ? 'background' : 'inactive'}${paused ? ' (paused in background)' : ''}';
        }
      } else {
        await c.cancel();
        await E2eApp.pumpUntil(tester, () => ed.exportState is! ExportUiRunning && ed.exportState is! ExportUiCancelling,
            what: 'the export to cancel', timeout: const Duration(seconds: 60));
        outcome = 'cancelled';
      }
    } else if (now is ExportUiCompleted) {
      outcome = 'completed${watch.paused ? ' (paused in background)' : ''}';
    } else {
      outcome = 'ended as ${now.runtimeType} (low storage)';
    }
    await soakDismissAll(tester, ed);
    SoakMedia.dropHandoffCopies();
    return outcome;
  }

  Future<String> _captions() async {
    if (!_captionsReady) throw _Skip(unavailable['captions'] ?? 'captions unavailable');
    final speech = ed.clipNamed(_mediaCopies[4].split('/').last);
    if (speech == null) throw _Skip('the speech clip was edited away');
    if (E2eApp.world.captions!.service.activeJob != null) throw _Skip('a captions job runs');
    await ed.select(speech.id);
    final r = await ed.tryInvoke(EditorActionId.autoCaptions, source: EditorActionSource.contextMenu);
    if (r != EditorActionResult.ran) return r.name;
    await E2eApp.waitKey(tester, 'captions-sheet');
    await E2eApp.pumpUntil(tester, () => E2eApp.hasKey('captions-configure') || E2eApp.hasKey('captions-consent') || E2eApp.hasKey('captions-interrupted'),
        what: 'the captions setup');
    if (!E2eApp.hasKey('captions-configure')) {
      final why = E2eApp.hasKey('captions-consent') ? 'consent view (model not staged)' : 'interrupted notice';
      await soakDismissAll(tester, ed);
      throw StateError('Auto captions did not offer the setup: $why');
    }
    final scope = find.descendant(of: find.byKey(const ValueKey('captions-scope')), matching: find.text(CaptionsStrings.selectionScope(1)));
    if (scope.evaluate().isNotEmpty) await E2eApp.tap(tester, scope, what: 'This clip');
    if (E2eApp.hasKey('captions-tier-fast')) await E2eApp.tapKey(tester, 'captions-tier-fast');
    final cuesBefore = {for (final c in ed.items<SubtitleCue>()) c.id};
    await E2eApp.tapKey(tester, 'captions-create');
    final cancel = rng.nextBool();
    final service = E2eApp.world.captions!.service;
    // Done when new cues replaced or joined the old ones ("Replace previous captions" keeps the cue
    // count, so the count alone cannot tell) and the job ended.
    bool generated() => service.activeJob == null && {for (final c in ed.items<SubtitleCue>()) c.id}.difference(cuesBefore).isNotEmpty;
    // Random edits can leave the speech clip as a piece without speech: that is an answer, not a defect.
    bool noSpeech() => find.text('No speech found').evaluate().isNotEmpty || find.text('No audio to caption').evaluate().isNotEmpty;
    var outcome = '';
    while (true) {
      await E2eApp.pumpUntil(
        tester,
        () {
          if (E2eApp.hasKey('captions-failed') && !noSpeech()) throw TestFailure('Auto captions failed: ${E2eApp.describeScreen()}');
          return generated() ||
              noSpeech() ||
              (E2eApp.hasKey('captions-needs-language') && E2eApp.hasKey('captions-candidate-en')) ||
              (cancel && service.activeJob != null && E2eApp.hasKey('captions-cancel'));
        },
        what: 'Auto captions',
        timeout: const Duration(minutes: 5),
        step: const Duration(milliseconds: 150),
      );
      if (noSpeech()) {
        outcome = 'no speech in the (edited) clip';
        break;
      }
      if (generated()) {
        outcome = '${ed.items<SubtitleCue>().where((c) => !cuesBefore.contains(c.id)).length} new cues';
        break;
      }
      if (E2eApp.hasKey('captions-needs-language')) {
        await E2eApp.tapKey(tester, 'captions-candidate-en');
        continue;
      }
      await _hold(Duration(milliseconds: 200 + rng.nextInt(1500)));
      if (service.activeJob == null) continue;
      await E2eApp.tapKey(tester, 'captions-cancel', ifStillThere: true);
      await E2eApp.pumpUntil(tester, () => service.activeJob == null, what: 'the captions job to cancel', timeout: const Duration(seconds: 60));
      outcome = 'cancelled';
      break;
    }
    await soakDismissAll(tester, ed);
    if (outcome != 'cancelled' && rng.nextBool()) {
      await ed.tryInvoke(EditorActionId.undo);
      outcome += ', undone';
    }
    return outcome;
  }

  Future<String> _background() async {
    final playing = rng.nextBool() && ed.transport.canPlay;
    if (playing) {
      await ed.transport.play();
      await ed.waitPlaying(true);
    }
    final secs = 1 + rng.nextInt(5);
    final ack = await _host('background', args: {'seconds': secs});
    if (ack == null) {
      if (playing) await ed.transport.pause();
      throw _Skip('host: ${unavailable['background']}');
    }
    await ed.waitPlaying(false);
    await ed.waitReady();
    // The preview is live again after the return (scenario 11's check, without the barcode).
    await _hold(const Duration(seconds: 1));
    final frame = await ed.capture();
    if (frame.meanLuma < 2) throw StateError('black preview 1 s after the return');
    return '$secs s${playing ? ' during playback' : ''}';
  }

  Future<String> _call() async {
    final playing = rng.nextBool() && ed.transport.canPlay;
    if (playing) {
      await ed.transport.play();
      await ed.waitPlaying(true);
    }
    final ack = await _host('call', args: {'seconds': 3});
    if (ack == null) {
      // iOS Simulator: no telephony; a call banner or Siri reaches the app as inactive -> resumed.
      await _lifecycleBlip(const Duration(seconds: 2));
    }
    await ed.waitPlaying(false);
    await ed.waitReady();
    return ack == null ? 'simulated (inactive -> resumed)' : 'host call ${ack.detail}';
  }

  Future<String> _audioRoute() async {
    final playing = ed.transport.canPlay;
    if (playing) {
      await ed.transport.play();
      await ed.waitPlaying(true);
    }
    final ack = await _host('audioRoute');
    await _hold(const Duration(milliseconds: 500));
    if (playing) {
      await ed.transport.pause();
      await ed.waitPlaying(false);
    }
    if (ack == null) throw _Skip('host: ${unavailable['audioRoute']}');
    return ack.detail;
  }

  Future<String> _offline() async {
    final path = _offlineCandidate;
    if (path == null || !File(path).existsSync()) throw _Skip('no offline candidate');
    final asset = ed.project.pool.assets.values.where((a) => a.displayName == path.split('/').last).firstOrNull;
    if (asset == null) throw _Skip('the clip is not in the pool');
    final away = '$path.away';
    File(path).renameSync(away);
    try {
      await ed.refreshMediaHealth();
      final used = ed.items<MediaClip>().any((c) => c.media == asset.id);
      if (used) {
        await E2eApp.pumpUntil(tester, () => ed.state.media.missing.contains(asset.id), what: 'the media to show offline');
      }
      // Keep editing and playing with the media offline.
      for (final op in [_ops[0], _ops[2], _ops[4], _ops[1]]) {
        await op.run(this).onError<_Skip>((e, _) => '');
      }
      if (rng.nextBool()) await _export();
    } finally {
      File(away).renameSync(path);
    }
    await ed.refreshMediaHealth();
    await E2eApp.pumpUntil(tester, () => !ed.state.media.missing.contains(asset.id), what: 'the media to come back', timeout: const Duration(seconds: 60));
    await ed.waitReady();
    return 'offline and back';
  }

  Future<String> _lowStorageOp() async {
    final ack = await _host('lowStorage', args: {'leaveMb': 200}, timeout: const Duration(minutes: 3));
    if (ack == null) throw _Skip('host: ${unavailable['lowStorage']}');
    _lowStorage = true;
    try {
      await _text();
      await ed.controller.saveNow(manual: true);
      final export = await _export();
      return 'low storage (${ack.detail}); export: $export; save: ${ed.state.save.phase.name}';
    } finally {
      await _host('freeStorage', timeout: const Duration(minutes: 3));
      _lowStorage = false;
    }
  }

  Future<String> _reopen() async {
    await soakDismissAll(tester, _ed);
    final id = ed.id;
    final live = ed.problems();
    if (live.isNotEmpty) reopenProblems.addAll(live.map((p) => 'before close: $p'));
    await ed.close();
    _ed = null;
    final problems = await soakStoreCheck(tester, id);
    reopenProblems.addAll(problems);
    final (opened, restored) = await soakOpenProject(tester, id);
    _ed = opened;
    final after = opened.problems();
    reopenProblems.addAll(after.map((p) => 'after reopen: $p'));
    if (restored) reopenProblems.add('a clean close left a recovery journal');
    return problems.isEmpty && after.isEmpty ? 'valid' : 'problems: ${[...problems, ...after]}';
  }
}

/// Drives the export sheet's states (notice, warnings) and waits for a condition with two bounds:
/// no progress for 120 s is a stall (a hang, reported with the last fraction), and an
/// unexpected failure ends the wait at once with the controller's details (copy-details text).
final class _ExportWatch {
  _ExportWatch(this.soak, this.handoffs);

  final _Soak soak;
  final int handoffs;
  bool paused = false;

  bool get delivered => E2eApp.world.engine.files.records.length > handoffs;

  Future<void> until(bool Function(ExportUiState s) done, {required String what}) async {
    final ed = soak.ed;
    final c = ed.export;
    var lastFraction = -1.0;
    var lastChange = DateTime.now();
    ExportUiFailed? failed;
    String? stalled;
    await E2eApp.pumpUntil(
      soak.tester,
      () {
        final s = ed.exportState;
        if (s is ExportUiNotice) c.confirmNotice();
        if (s is ExportUiWarnings) c.confirmWarnings();
        if (s is ExportUiRunning) {
          if (s.pausedInBackground) paused = true;
          if (s.fraction != lastFraction) {
            lastFraction = s.fraction;
            lastChange = DateTime.now();
          } else if (!s.pausedInBackground && DateTime.now().difference(lastChange) > const Duration(seconds: 120)) {
            _dumpProject(ed, 'stall-${soak._op}');
            stalled = 'no progress for 120 s at ${(s.fraction * 100).toStringAsFixed(1)} % (${s.framesDone}/${s.framesTotal} frames, '
                'phase ${s.phase.name}, project ${ed.project.duration ~/ 1000} ms)';
            return true;
          }
        } else {
          lastChange = DateTime.now();
        }
        if (done(s)) return true;
        if (s is ExportUiFailed) {
          failed = s;
          return true;
        }
        return false;
      },
      what: what,
      timeout: const Duration(minutes: 15),
      step: const Duration(milliseconds: 200),
    );
    if (stalled != null) throw TestFailure('$what: export stalled: $stalled');
    final f = failed;
    if (f != null && !done(f)) _dumpProject(ed, 'failed-${soak._op}');
    if (f != null && !done(f)) throw StateError('export failed: ${f.failure}; details: ${c.detailsOf(f.failure).replaceAll('\n', ' ')}');
  }
}

/// Writes the project as edited now (canonical body JSON) to `<shared>/e2e_out/soak-<tag>.json`,
/// so a stalled or failed export can be replayed outside the soak.
void _dumpProject(E2eEditor ed, String tag) {
  try {
    soakWriteJson(tag, jsonDecode(ProjectJsonCodec().encode(ed.project)));
    soakLog('dump', 'project written to e2e_out/soak-$tag.json');
  } on Object catch (e) {
    soakLog('dump', 'could not write the project: ${e.runtimeType}');
  }
}

final class _Op {
  _Op(this.name, this.weight, this.run);
  final String name;
  final int weight;
  final Future<String> Function(_Soak s) run;
}
