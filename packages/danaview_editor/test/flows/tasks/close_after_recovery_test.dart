// OWNER: FIX-M15
//
// QA-02 M-15: after a recovery restore the editor never closed (s09 recover: Close timed out, the
// preview's deck players were never released, no engine error). A restored session is the case
// that resumes background jobs, and since FIX-QA05-D5 those wait for the first media resolve; the
// close awaited the open, whose first plan waited for that resolve. These tests pin the fix: the
// close never waits on a job resume or a media resolve, it drops the pending resume work at once,
// and every release step runs.
//
// The s09 path itself is pinned too: a restored session in `EditorScreen` with the real
// controller (not a DetachedEditorShell), "Close editor" tapped through EditorLifecycle, onClose
// within the tier timeout and the preview disposed.
//
// QA-02 M-15 follow-up (FIX-M15 fixer, 2026-10-17): run against the previous lib code (HEAD
// 490bf96 lifecycle + controller), the s09-path test still reaches onClose (after the lifecycle's
// 3 s `_release` timeout) but never disposes the preview. So the Dart close explains the deck
// players that were never released, not the editor that stayed on screen for 30 s with "Saved".
// requestClose's early return is ruled out for this path ("Saved", not "Saving…", means `_closing`
// was false, and the tap reached requestClose here), and the shell is the controller, not a
// DetachedEditorShell. The remaining Dart-side gap is `_exit`, which leaves in a post-frame
// callback: if no frame comes (on Android vsync arrives through the main thread's Choreographer,
// so a main thread blocked in a native release stalls it) the editor stays. The new logs tell the
// cases apart on the device: "[EditorLifecycle] close requested" (or "close request ignored"),
// "release: end" / "close still running", "leaving the editor", then "exit callback". A run with
// "leaving the editor" and no "exit callback" points at the native main thread (Android lane).
//
// The rig compiler behaves like INT-02's (resolve answers from a snapshot each compile refreshes
// first), and its first refresh waits for a gate the test may never open (a resolve that never
// comes).

import 'dart:async';

import 'package:flutter/widgets.dart' show Size, SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/editor_lifecycle.dart' show EditorLifecycle;
import 'package:danaview_editor/src/editor/editor_scope.dart';
import 'package:danaview_editor/src/editor/editor_screen.dart' show DetachedEditorShell, editorShellProvider;
import 'package:danaview_editor/src/editor/layout/editor_shell_strings.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_dock.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_host.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_session.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/state/plan_compiler_port.dart';
import 'package:danaview_editor/src/editor/state/tasks_controller.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show AddText, EditSession;
import 'package:danaview_editor_core/plan.dart' show MapPlanAssetResolver;
import 'package:danaview_editor_core/store.dart' show RecoverableSession;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show EditorCapabilities, EngineMedia, PlanTransient, RenderPlan;
import 'package:danaview_editor_engine_api/testing.dart';

import '../../support/support.dart';
import 'tasks_rig.dart';

final String _videoHash = 'md_video'.padRight(40, '0');

/// A reverse rendition that was being produced when the app was killed.
MediaAsset _staleRendition() => rigAsset('md_rev', MediaKind.video,
    status: const PendingStatus('reverse-before-kill'),
    derived: ReversedSpec(TaskIds.videoMedia, const TimeRange(3 * s, 19 * s), sourceQuickHash: _videoHash));

MediaClip get _reversedVideo => rigClip('it_video', 'md_video', 0, 12 * s, sourceIn: 5 * s, reversed: true);

/// A proxy that was pending when the app was killed.
MediaAsset _pendingProxy() => rigAsset('md_proxied', MediaKind.video).copyWith(proxy: ProxyState.pending);

/// Bound for "the close completes": far below the 3 s flush timeout, so a close that waited on
/// anything (even a bounded wait) fails.
const Duration _closeBound = Duration(milliseconds: 1500);

final class _GatedPort implements PlanCompilerPort {
  Completer<void> firstResolve = Completer<void>();
  final Set<MediaId> offline = {};
  int compiles = 0;

  @override
  SessionPlanCompiler forSession(EditSession session, EditorCapabilities capabilities) => _GatedCompiler(this);
}

final class _GatedCompiler implements SessionPlanCompiler {
  _GatedCompiler(this._port) {
    _inner = ResolvingSessionPlanCompiler((_) => _snapshot);
  }

  final _GatedPort _port;
  late final ResolvingSessionPlanCompiler _inner;
  MapPlanAssetResolver _snapshot = MapPlanAssetResolver.empty;

  @override
  Future<RenderPlan> compile(EditProject project) async {
    _port.compiles++;
    final gate = _port.firstResolve;
    if (!gate.isCompleted) await gate.future;
    await Future<void>.microtask(() {});
    _snapshot = MapPlanAssetResolver(originals: {
      for (final a in project.pool.assets.values)
        if (a.status is ReadyStatus && !_port.offline.contains(a.id))
          a.id: ResolvedMedia(uri: 'file:///media/${a.id.value}', fingerprint: a.fingerprint.quickHash),
    });
    return _inner.compile(project);
  }

  @override
  PlanTransient? transientFor(EditProject working, ItemId item) => _inner.transientFor(working, item);

  @override
  EngineMedia? resolve(EditProject project, MediaId media) => _snapshot.original(media);

  @override
  void trim() => _inner.trim();
}

final class _Rig {
  _Rig(this.harness, this.repo, this.id, this.tester, this.port);

  final EditorTestHarness harness;
  final FakeProjectRepository repo;
  final ProjectId id;
  final WidgetTester tester;
  final _GatedPort port;
  Future<void>? opening;

  FakeEditorEngine get engine => harness.engine;
  EditorController get editor => harness.containerOf(tester).read(editorControllerProvider(id).notifier);
  EditorState get state => harness.containerOf(tester).read(editorControllerProvider(id));
  EditorSession get session => harness.containerOf(tester).read(editorSessionProvider(id));
  TasksController get tasks => harness.containerOf(tester).read(tasksControllerProvider(id));
  List<FakeMediaJob<Object?>> jobs(String kind) => [for (final j in engine.jobs.created) if (j.id.startsWith('$kind-')) j];

  /// Seeds a project the app was killed with, restores its journal the way the Projects screen
  /// does (`restore`, then `close`), then pumps the editor and starts opening it.
  static Future<_Rig> restoreAndOpen(WidgetTester tester, {MediaClip? video, List<MediaAsset> extraAssets = const []}) async {
    EditorAnnouncer.instance.reset();
    final repo = FakeProjectRepository();
    final empty = repo.seedEmpty('Recovered');
    final project = tasksProject(empty.id, video: video, extraAssets: extraAssets);
    repo.seed(project);
    final killed = RecoverableSession(
      projectId: project.id,
      projectName: project.name,
      journalRevision: project.docRevision + 1,
      mainRevision: project.docRevision,
      journalSavedAt: DateTime.utc(2026, 10, 16, 22, 30),
    );
    repo.recoverableSessions.add(killed);
    final port = _GatedPort();
    final harness = EditorTestHarness(
      engine: FakeEditorEngine(validatePlans: false),
      repository: repo,
      mediaPool: ScriptedPool(),
      overrides: [planCompilerPortProvider.overrideWithValue(port)],
    );
    final rig = _Rig(harness, repo, project.id, tester, port);
    await harness.pumpApp(
      tester,
      EditorScope(
        projectId: project.id,
        child: const RegionFrame(inspectorOpen: true, regions: {EditorRegion.pane: InspectorHost()}, dock: InspectorDock()),
      ),
      surface: const EditorSurface(Size(1280, 900)),
    );
    await rig.real(() async {
      // ProjectsController.restore: the journal is promoted and the project closed again.
      await repo.restore(killed);
      await repo.close(project.id);
      rig.opening = rig.editor.open();
    });
    expect(repo.recoverableSessions, isEmpty, reason: 'the restore completed');
    return rig;
  }

  Future<void> real(Future<void> Function() body) async {
    await tester.runAsync(() async {
      await body();
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
    await tester.pump();
  }

  /// Lets the first media resolve (and the first plan) finish.
  Future<void> resolveFirst() => real(() async {
        port.firstResolve.complete();
        await opening;
      });

  /// Closes the editor and returns the outcome, failing when the close does not complete within
  /// [_closeBound].
  Future<CloseOutcome> close({void Function()? rightAfterStart}) async {
    CloseOutcome? outcome;
    Object? error;
    await real(() async {
      final closing = editor.close();
      rightAfterStart?.call();
      try {
        outcome = await closing.timeout(_closeBound);
      } on TimeoutException catch (e) {
        error = e;
      }
    });
    if (error != null) fail('close() did not complete within ${_closeBound.inMilliseconds} ms: it waited on background work');
    return outcome!;
  }

  void expectReleased({required FakePreviewSession preview}) {
    expect(preview.disposed, isTrue, reason: 'the preview (deck players) is released');
    expect(session.isOpen, isFalse, reason: 'EditorSession closed');
    expect(repo.openProjects.contains(id), isFalse, reason: 'the repository closed the project');
    expect(repo.calls.where((c) => c == 'close:$id'), hasLength(2), reason: 'once by the restore, once by the editor close');
  }

  Future<void> finish() async {
    if (!port.firstResolve.isCompleted) port.firstResolve.complete();
    await real(() async {});
    await tester.pump(const Duration(seconds: 1));
    EditorAnnouncer.instance.reset();
  }
}

/// The s09 path (QA-02 M-15): the Projects screen restores a killed session, the router pumps
/// `EditorScreen`, and the user taps "Close editor" through `EditorLifecycle` with the real
/// controller while the first media resolve never comes.
Future<void> _screenCloseAfterRestore(WidgetTester tester, {required bool dirty}) async {
  EditorAnnouncer.instance.reset();
  final repo = FakeProjectRepository();
  final empty = repo.seedEmpty('Recovered');
  final project = tasksProject(empty.id, video: _reversedVideo, extraAssets: [_staleRendition(), _pendingProxy()]);
  repo.seed(project);
  final killed = RecoverableSession(
    projectId: project.id,
    projectName: project.name,
    journalRevision: project.docRevision + 1,
    mainRevision: project.docRevision,
    journalSavedAt: DateTime.utc(2026, 10, 16, 22, 30),
  );
  repo.recoverableSessions.add(killed);
  final port = _GatedPort();
  final harness = EditorTestHarness(
    engine: FakeEditorEngine(validatePlans: false),
    repository: repo,
    mediaPool: ScriptedPool(),
    overrides: [planCompilerPortProvider.overrideWithValue(port)],
  );
  await tester.runAsync(() async {
    await repo.restore(killed);
    await repo.close(project.id);
  });
  expect(repo.recoverableSessions, isEmpty, reason: 'the restore completed');

  Future<void> settleReal() async {
    await tester.runAsync(() async {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
  }

  await harness.pumpEditor(tester, projectId: project.id, surface: const EditorSurface(Size(1280, 900)));
  await settleReal();
  await settleReal();
  final container = harness.containerOf(tester);
  final shell = container.read(editorShellProvider(project.id));
  expect(shell, isNot(isA<DetachedEditorShell>()), reason: 'the restored project is driven by the real controller');
  expect(shell, same(container.read(editorControllerProvider(project.id).notifier)));
  expect(container.read(editorControllerProvider(project.id)).phase, EditorPhase.ready,
      reason: 'attached; the first plan waits for the resolve that never comes');
  final preview = harness.engine.sessions.single;
  if (dirty) {
    final controller = container.read(editorControllerProvider(project.id).notifier);
    expect(controller.apply(const AddText(0)), isA<EditApplied>());
    await settleReal();
  }

  await tester.tap(find.bySemanticsLabel(EditorShellStrings.closeEditor));
  // Close inside the tier timeout: real time for the store, fake time for the shell's frames.
  final timeout = tester.widget<EditorLifecycle>(find.byType(EditorLifecycle)).flushTimeout!;
  final deadline = DateTime.now().add(timeout);
  while (harness.closeRequests == 0 && DateTime.now().isBefore(deadline)) {
    await settleReal();
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(harness.closeRequests, 1, reason: 'onClose within the ${timeout.inSeconds} s tier timeout (QA-02 M-15)');
  expect(find.text(EditorShellStrings.stillSavingTitle), findsNothing);
  expect(find.text(EditorShellStrings.leaveTitle), findsNothing);
  await settleReal();
  expect(preview.disposed, isTrue, reason: 'the preview (deck players) is released');
  expect(repo.openProjects.contains(project.id), isFalse, reason: 'the repository closed the project');
  if (dirty) expect(repo.projects[project.id]!.docRevision, greaterThan(project.docRevision), reason: 'the edit was saved');

  if (!port.firstResolve.isCompleted) port.firstResolve.complete();
  await settleReal();
  expect(harness.engine.jobs.created, isEmpty, reason: 'the resolve after the close starts nothing');
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  EditorAnnouncer.instance.reset();
}

void main() {
  testWidgets('s09 path: "Close editor" on the EditorScreen after a restore leaves and releases the preview', (tester) async {
    await _screenCloseAfterRestore(tester, dirty: false);
  });

  testWidgets('s09 path: "Close editor" after a restore with an unsaved edit saves, leaves and releases', (tester) async {
    await _screenCloseAfterRestore(tester, dirty: true);
  });

  testWidgets('close right after a recovery restore completes, while the first media resolve never comes', (tester) async {
    final rig = await _Rig.restoreAndOpen(tester, video: _reversedVideo, extraAssets: [_staleRendition(), _pendingProxy()]);
    expect(rig.state.phase, EditorPhase.ready, reason: 'attached; the first plan waits for the resolve');
    final preview = rig.engine.sessions.single;
    final tasks = rig.tasks;
    expect(rig.engine.jobs.created, isEmpty, reason: 'the resume waits for the first resolve');

    final outcome = await rig.close();
    expect(outcome.saved, isTrue);
    expect(rig.state.phase, EditorPhase.closed);
    rig.expectReleased(preview: preview);
    expect(tasks.suspended, isTrue, reason: 'the pending resume was dropped');

    // The resolve arrives after the close: nothing starts.
    await rig.real(() async => rig.port.firstResolve.complete());
    expect(rig.engine.jobs.created, isEmpty);
    await rig.finish();
  });

  testWidgets('close right after a recovery restore completes, with the resumed jobs running', (tester) async {
    final rig = await _Rig.restoreAndOpen(tester, video: _reversedVideo, extraAssets: [_staleRendition(), _pendingProxy()]);
    await rig.resolveFirst();
    final reverse = rig.jobs('reverse').single;
    final proxy = rig.jobs('proxy').single;
    final preview = rig.engine.sessions.single;
    final tasks = rig.tasks;
    expect(rig.state.tasks, hasLength(2));

    var cancelledAtStart = false;
    final outcome = await rig.close(rightAfterStart: () => cancelledAtStart = reverse.cancelled && proxy.cancelled);
    expect(cancelledAtStart, isTrue, reason: 'the resumed jobs stop as soon as the close starts, before its flush');
    expect(outcome.saved, isTrue);
    rig.expectReleased(preview: preview);
    expect(tasks.tasks, isEmpty, reason: 'cancelled quietly');
    expect(tasks.suspended, isTrue);
    expect(rig.repo.projects[rig.id]!.pool[const MediaId('md_rev')]!.status, isA<PendingStatus>(),
        reason: 'the rendition stays pending and resumes on the next open');
    await rig.finish();
  });

  testWidgets('close during a pending resume (a resumed proxy waits for its offline media)', (tester) async {
    final rig = await _Rig.restoreAndOpen(tester, extraAssets: [_pendingProxy()]);
    rig.port.offline.add(const MediaId('md_proxied'));
    await rig.resolveFirst();
    expect(rig.jobs('proxy'), isEmpty, reason: 'waiting for the media to come back');
    final preview = rig.engine.sessions.single;
    final tasks = rig.tasks;

    await rig.close();
    rig.expectReleased(preview: preview);
    expect(tasks.suspended, isTrue);
    expect(rig.jobs('proxy'), isEmpty);
    await rig.finish();
  });

  testWidgets('the editor reopens after a close that left the first plan behind, and the jobs resume once', (tester) async {
    final rig = await _Rig.restoreAndOpen(tester, extraAssets: [_pendingProxy()]);
    await rig.close();
    expect(rig.session.isOpen, isFalse);

    // Open again: not the left-behind open (still waiting on its first plan), a new one.
    await rig.real(() async {
      rig.opening = rig.editor.open();
    });
    expect(rig.state.phase, EditorPhase.ready);
    expect(rig.engine.sessions, hasLength(2));
    expect(rig.jobs('proxy'), isEmpty);
    await rig.resolveFirst();
    expect(rig.jobs('proxy'), hasLength(1), reason: 'the stale compile is ignored; the new session resumes once');
    expect(rig.session.initialSeek, isNotNull, reason: 'the new open finished its exact seek');

    final preview = rig.engine.sessions.last;
    await rig.close();
    expect(preview.disposed, isTrue);
    await rig.finish();
  });
}
