// OWNER: QA-05
//
// Support code of the QA-05 robustness soak (BUILD_PLAN M6, ARCH §21 "Performance and soak"):
// configuration, the report, the memory sampler, the error recorder and the editor helpers the
// random soak (`soak_test.dart`) and the process-death phases (`process_death_test.dart`) share.
// Everything runs against the real app wiring and the production engine through QA-00's
// `E2eApp` / `E2eEditor` (integration_test/editor/support).
//
// Report lines: every event prints `DV_SOAK <kind> <detail>` (one line, no media paths, no user
// content) and the run summary is written to `<shared>/e2e_out/soak-<name>.json`, which the host
// driver (`tool/soak_host.py`) collects into build/soak/<platform>/<device>/.

// ignore_for_file: implementation_imports, avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/action_binding.dart' show EditorActionSource;
import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor/src/editor/flows/export/export_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show EditorPhase;
import 'package:danaview_editor/src/editor/state/media_health_controller.dart';
import 'package:danaview_editor/src/editor/state/tasks_controller.dart';
import 'package:danaview_editor_core/eval.dart' show validate;
import 'package:danaview_editor_core/model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../editor/support/e2e.dart';

/// Run configuration (`--dart-define`s; the host driver passes them).
abstract final class SoakConfig {
  /// Length of the random soak in minutes (`DV_SOAK_MINUTES`, 60 by default: the BUILD_PLAN hour).
  static const int minutes = int.fromEnvironment('DV_SOAK_MINUTES', defaultValue: 60);

  /// Seed of the random op sequence (`DV_SOAK_SEED`; 0 picks one from the clock and prints it, so
  /// every run can be replayed with the same sequence).
  static const int seedDefine = int.fromEnvironment('DV_SOAK_SEED');

  /// Whether the soak runs Auto captions (`DV_SOAK_CAPTIONS`, on by default; needs the tiny model
  /// staged in `DV_E2E_MODELS`).
  static const bool captions = bool.fromEnvironment('DV_SOAK_CAPTIONS', defaultValue: true);

  /// Allowed memory growth over the run (BUILD_PLAN QA-05: <= 10 %).
  static const double memoryGrowthLimit = 0.10;

  /// The seed of this run.
  static final int seed = seedDefine != 0 ? seedDefine : DateTime.now().millisecondsSinceEpoch % 1000000;
}

/// Prints one report line.
void soakLog(String kind, String detail) => print('DV_SOAK $kind ${detail.replaceAll('\n', ' ')}');

/// Writes [value] as `<shared>/e2e_out/soak-<name>.json` for the host.
void soakWriteJson(String name, Object? value) {
  final dir = Directory(E2eConfig.outDir)..createSync(recursive: true);
  final f = File('${dir.path}/soak-$name.json');
  final tmp = File('${f.path}.tmp')..writeAsStringSync(const JsonEncoder.withIndent(' ').convert(value), flush: true);
  tmp.renameSync(f.path);
}

// -------------------------------------------------------------------------------------------------
// Memory
// -------------------------------------------------------------------------------------------------

/// One resident-set sample.
final class MemorySample {
  /// Creates a sample.
  const MemorySample(this.at, this.rssBytes);

  /// Time since the soak started.
  final Duration at;

  /// Resident set size of the app process (`ProcessInfo.currentRss`).
  final int rssBytes;

  /// JSON form.
  Map<String, Object?> toJson() => {'s': at.inMilliseconds / 1000, 'rssMb': (rssBytes / (1 << 20)).toStringAsFixed(1)};
}

/// The verdict on memory growth.
final class MemoryVerdict {
  /// Creates the verdict.
  const MemoryVerdict({required this.baselineBytes, required this.endBytes, required this.peakBytes, required this.samples});

  /// Median RSS of the baseline window (right after the warm-up).
  final int baselineBytes;

  /// Median RSS of the last tenth of the run.
  final int endBytes;

  /// Highest sample.
  final int peakBytes;

  /// Samples used.
  final int samples;

  /// (end − baseline) / baseline.
  double get growth => baselineBytes == 0 ? 0 : (endBytes - baselineBytes) / baselineBytes;

  /// Whether growth is within [SoakConfig.memoryGrowthLimit].
  bool get ok => growth <= SoakConfig.memoryGrowthLimit;

  @override
  String toString() => 'baseline ${_mb(baselineBytes)} MB, end ${_mb(endBytes)} MB, peak ${_mb(peakBytes)} MB, '
      'growth ${(growth * 100).toStringAsFixed(1)} % (limit ${(SoakConfig.memoryGrowthLimit * 100).round()} %, $samples samples)';

  static String _mb(int b) => (b / (1 << 20)).toStringAsFixed(1);
}

/// Samples the app's RSS. Growth compares the median of the baseline window (the first samples
/// after [markBaseline], at least 5) with the median of the last tenth of the run (at least 5), so
/// single spikes (an export, a captions run) do not decide the verdict; both windows are taken
/// with the editor idle between ops.
final class MemorySampler {
  final Stopwatch _clock = Stopwatch()..start();
  final List<MemorySample> samples = [];
  int? _baselineIndex;

  /// Takes a sample now.
  MemorySample sample() {
    final s = MemorySample(_clock.elapsed, ProcessInfo.currentRss);
    samples.add(s);
    return s;
  }

  /// The warm-up is over: samples from now on form the baseline window.
  void markBaseline() => _baselineIndex = samples.length;

  /// Whether [markBaseline] was called.
  bool get hasBaseline => _baselineIndex != null;

  /// The verdict, or null with fewer than 10 samples after the baseline.
  MemoryVerdict? verdict() => computeVerdict([for (final s in samples) s.rssBytes], _baselineIndex ?? 0);

  /// The verdict over [rss] with the baseline window starting at [from] (pure; see the class doc).
  static MemoryVerdict? computeVerdict(List<int> rss, int from) {
    final tail = rss.sublist(math.min(from, rss.length));
    if (tail.length < 10) return null;
    final window = math.max(5, tail.length ~/ 10);
    final base = _median(tail.take(window).toList());
    final end = _median(tail.skip(tail.length - window).toList());
    return MemoryVerdict(baselineBytes: base, endBytes: end, peakBytes: tail.reduce(math.max), samples: tail.length);
  }

  static int _median(List<int> v) {
    final s = [...v]..sort();
    return s[s.length ~/ 2];
  }
}

// -------------------------------------------------------------------------------------------------
// Errors
// -------------------------------------------------------------------------------------------------

/// Records every error the framework reports (FlutterError) while still forwarding it to the test
/// binding, so an unhandled exception both fails the test and is attributed to the op that ran.
final class SoakErrors {
  FlutterExceptionHandler? _previous;

  /// Framework errors, as `op: summary`.
  final List<String> framework = [];

  /// The op running now (for attribution).
  String current = 'boot';

  /// Starts recording.
  void install() {
    _previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final summary = '${details.exceptionAsString().split('\n').first} (${details.library ?? '?'})';
      framework.add('$current: $summary');
      soakLog('error', 'framework error during $current: $summary');
      _previous?.call(details);
    };
  }

  /// Stops recording (must run before the test ends: the binding checks the handler).
  void uninstall() {
    if (_previous != null) FlutterError.onError = _previous;
    _previous = null;
  }
}

// -------------------------------------------------------------------------------------------------
// Editor helpers
// -------------------------------------------------------------------------------------------------

/// Helpers over an open project shared by the soak and the process-death phases.
extension SoakEditor on E2eEditor {
  /// Runs [action] through the registry like a tool tile; returns the registry's answer (a disabled
  /// action is a normal outcome in a random soak, not a failure).
  Future<EditorActionResult> tryInvoke(EditorActionId action, {EditorActionSource source = EditorActionSource.toolTile}) async {
    final registry = container.read(editorActionRegistryProvider);
    final result = registry.invoke(action, context(source));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return result;
  }

  /// The tasks controller of the open project.
  TasksController get tasks => container.read(tasksControllerProvider(id));

  /// Export controller.
  ExportController get export => container.read(exportControllerProvider(id).notifier);

  /// Export sheet state.
  ExportUiState get exportState => container.read(exportControllerProvider(id));

  /// The video clips on the timeline.
  List<MediaClip> get videoClips => [
        for (final c in items<MediaClip>())
          if (project.pool[c.media]?.kind == MediaKind.video) c,
      ];

  /// The clip whose asset is called [name], or null.
  MediaClip? clipNamed(String name) => items<MediaClip>().where((c) => project.pool[c.media]?.displayName == name).firstOrNull;

  /// Re-checks the media's availability (what the app does on resume) and waits for the report.
  Future<void> refreshMediaHealth() async {
    final sub = container.listen(mediaHealthControllerProvider(id), (_, __) {});
    try {
      container.read(mediaHealthControllerProvider(id).notifier).refresh();
      await tester.pump();
      await E2eApp.pumpUntil(tester, () => sub.read().checked, what: 'the media health report');
    } finally {
      sub.close();
    }
  }

  /// Every problem with the project as edited now: validator violations (ARCH §6.9) and an editor
  /// that is not ready.
  List<String> problems() => [
        if (state.phase == EditorPhase.failed) 'editor failed: ${state.failure}',
        for (final v in validate(project)) 'violation: $v',
      ];
}

/// Closes whatever sheet is open on the editor (export, captions, freeze, tasks…), cancelling a
/// running export or captions job on the way, until only the editor is left (bounded).
Future<void> soakDismissAll(WidgetTester tester, E2eEditor? ed) async {
  for (var round = 0; round < 8; round++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (ed != null && E2eApp.hasKey('export-sheet')) {
      final s = ed.exportState;
      if (s is ExportUiRunning || s is ExportUiPreparing) {
        await ed.export.cancel();
        await E2eApp.pumpUntil(tester, () => ed.exportState is! ExportUiRunning && ed.exportState is! ExportUiCancelling,
            what: 'the export to cancel', timeout: const Duration(seconds: 60));
        continue;
      }
      if (s is ExportUiNotice) {
        ed.export.backToSetup();
        continue;
      }
      if (s is ExportUiInterrupted) await ed.export.acknowledgeRecord();
    }
    String? key;
    for (final k in [
      'export-done',
      'export-interrupted-close',
      'export-finished-done',
      'export-close',
      'captions-cancel',
      'captions-close',
      'captions-hide',
      'captions-interrupted-discard',
      'freeze.cancel',
    ]) {
      if (find.byKey(ValueKey<String>(k)).hitTestable().evaluate().isNotEmpty) {
        key = k;
        break;
      }
    }
    if (key != null) {
      await E2eApp.tapKey(tester, key, ifStillThere: true);
      continue;
    }
    // Anything else on top of the editor (a menu, a sheet without a keyed close): the route's back.
    final navigators = find.byType(Navigator).evaluate().toList();
    var popped = false;
    for (final e in navigators.reversed) {
      final nav = (e as StatefulElement).state as NavigatorState;
      if (nav.canPop() && find.byType(EditorScreen).evaluate().isNotEmpty && !_editorOnTop(tester)) {
        popped = await nav.maybePop();
        if (popped) break;
      }
    }
    if (!popped) return;
  }
}

/// Whether the editor's own route is the top route (nothing modal above it).
bool _editorOnTop(WidgetTester tester) {
  final editor = find.byType(EditorScreen);
  if (editor.evaluate().isEmpty) return false;
  final route = ModalRoute.of(editor.evaluate().last);
  return route?.isCurrent ?? true;
}

/// Opens project [id] (restoring a crash-recovery journal through the Projects banner when one is
/// offered, like a user would) and attaches to its editor. Returns the editor and whether a
/// journal was restored.
Future<(E2eEditor, bool)> soakOpenProject(WidgetTester tester, ProjectId id) async {
  if (find.byType(ProjectsScreen).evaluate().isEmpty) await E2eApp.openProjectsFromHome(tester);
  final recoverable = await E2eApp.pumpWhile(tester, E2eApp.world.runtime.repository.recoverable(), what: 'recoverable()');
  final restored = recoverable.any((r) => r.projectId == id);
  if (restored) {
    await E2eApp.waitKey(tester, 'recovery-$id');
    await E2eApp.tapKey(tester, 'recovery-restore-$id');
    if (find.byType(EditorScreen).evaluate().isEmpty) {
      await E2eApp.pumpUntil(tester, () => find.byType(EditorScreen).evaluate().isNotEmpty || !E2eApp.hasKey('recovery-$id'),
          what: 'the restore to finish');
      if (find.byType(EditorScreen).evaluate().isEmpty) await E2eApp.tapKey(tester, 'project-card-$id');
    }
    return (await E2eEditor.attach(tester), true);
  }
  return (await E2eEditor.openFromProjects(tester, id), false);
}

/// Opens [id] straight from the store (the editor must not hold it), validates it and closes it:
/// the "project always reopens valid" check. Returns the problems found (empty when valid).
Future<List<String>> soakStoreCheck(WidgetTester tester, ProjectId id) async {
  final repo = E2eApp.world.runtime.repository;
  final problems = <String>[];
  try {
    final loaded = await E2eApp.pumpWhile(tester, repo.open(id), what: 'store open of $id');
    for (final v in validate(loaded.project)) {
      problems.add('violation after reopen: $v');
    }
    for (final w in loaded.warnings) {
      // Repairs mean the file on disk was not valid as saved.
      problems.add('repaired on open: ${w.code}');
    }
    if (loaded.readOnly) problems.add('opened read-only');
  } on Object catch (e) {
    problems.add('store open failed: $e');
  } finally {
    try {
      await E2eApp.pumpWhile(tester, repo.close(id), what: 'store close of $id');
    } on Object {
      // Not open (open failed).
    }
  }
  return problems;
}

/// Media of the soak's projects: unique sandbox copies, so the soak can take one offline without
/// touching the copies other projects use.
abstract final class SoakMedia {
  /// A unique copy of fixture [name] tagged [tag].
  static String copy(String name, String tag) => E2eMedia.uniqueCopy(name, tag);

  /// Deletes the delivered copies the handoff kept (exports run many times in an hour; the soak
  /// keeps the sandbox bounded).
  static void dropHandoffCopies() {
    final records = E2eApp.world.engine.files.records;
    for (final r in records) {
      try {
        final f = File(r.copyPath);
        if (f.existsSync()) f.deleteSync();
      } on FileSystemException {
        // Already gone.
      }
    }
    records.clear();
  }
}
