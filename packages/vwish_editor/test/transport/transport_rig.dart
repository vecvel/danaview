// OWNER: UX-14
//
// A rig for widget tests of the transport bar and the shortcuts: the editor harness with a real
// EditorController opened on a seeded project over FakeEditorEngine, a manual ticker and clock for
// the playhead, and helpers for the fake preview.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/editor_providers.dart';
import 'package:vwish_editor/src/editor/editor_scope.dart';
import 'package:vwish_editor/src/editor/state/editor_controller.dart';
import 'package:vwish_editor/src/editor/state/playhead_controller.dart';
import 'package:vwish_editor/src/editor/state/transport_controller.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';
import 'package:vwish_editor_engine_api/testing.dart';

import '../support/support.dart';
import 'transport_support.dart';

const int s = microsPerSecond;

/// A project with text items at 0-3 s and 5-7 s and a marker at 4 s (30 fps, 7 s).
EditProject sampleProject(FakeProjectRepository repo, {String name = 'Sample'}) {
  final empty = repo.seedEmpty(name);
  final edit = EditSession(empty, ids: SeededIdGenerator(5));
  for (final cmd in <EditCommand>[const AddText(0), const AddText(5 * s, duration: 2 * s), const AddMarker(4 * s)]) {
    final out = edit.apply(cmd);
    if (!out.changed) throw StateError('$cmd -> $out');
  }
  final project = edit.committedProject;
  repo.seed(project);
  return project;
}

/// The editor harness around one widget under test.
class TransportRig {
  TransportRig._(this.harness, this.id, this.tester, this.frames, this.time);

  final EditorTestHarness harness;
  final ProjectId id;
  final WidgetTester tester;

  /// The manual ticker the playhead uses.
  final ManualTicker frames;

  /// The manual clock the playhead uses.
  final ManualClock time;

  /// The harness' fake engine.
  FakeEditorEngine get engine => harness.engine;

  /// The live fake preview.
  FakePreviewSession get preview => engine.sessions.last;

  /// The container of the pumped app.
  ProviderContainer get container => harness.containerOf(tester);

  /// The editor controller.
  EditorController get editor => container.read(editorControllerProvider(id).notifier);

  /// The playhead.
  PlayheadController get playhead => container.read(playheadProvider(id));

  /// The transport.
  TransportController get transport => container.read(transportProvider(id));

  /// Pumps [home] (built from the project id) in the harness and opens the editor.
  static Future<TransportRig> pump(
    WidgetTester tester,
    Widget Function(ProjectId id) home, {
    EditorSurface surface = SurfaceMatrix.phone,
    bool open = true,
    bool project = true,
    FakeProjectRepository? repository,
    List<Override> overrides = const [],
  }) async {
    final repo = repository ?? FakeProjectRepository();
    final id = project ? sampleProject(repo).id : repo.seedEmpty('Empty').id;
    final ticker = ManualTicker();
    final clock = ManualClock();
    final harness = EditorTestHarness(
      engine: FakeEditorEngine(validatePlans: false),
      repository: repo,
      overrides: [
        playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: clock.call)),
        ...overrides,
      ],
    );
    final rig = TransportRig._(harness, id, tester, ticker, clock);
    await harness.pumpApp(tester, EditorScope(projectId: id, child: home(id)), surface: surface);
    if (open) await rig.openEditor();
    return rig;
  }

  /// Opens the editor (real async) and lets the UI settle.
  Future<void> openEditor({TimeUs? initialPlayhead}) async {
    await tester.runAsync(() async {
      await editor.open(initialPlayhead: initialPlayhead);
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
    await tester.pump();
  }

  /// Runs [body] with real async (fake engine calls) and then pumps.
  Future<void> real(Future<void> Function() body) async {
    await tester.runAsync(() async {
      await body();
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
  }
}
