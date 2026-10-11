// OWNER: UX-08
//
// EditorController with FakeEditorEngine and fake / in-memory repositories (BUILD_PLAN UX-08):
// open (exact seek, failures, read-only, migration, recovery), apply/undo/redo, coalescing,
// transactions (one history entry, per-frame state coalescing, transients, cancel), autosave
// requested on commit and flushed on hide/close, PlanSync scheduled once per commit, save
// failures, shell status and back steps, the provider's keepAlive, and the poster capture.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_messages.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/editor_lifecycle.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_session.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/state/plan_compiler_port.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' hide MediaUnavailable;
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_core/testing.dart';
import 'package:danaview_editor_core/eval.dart' show ProjectOpenWarning;
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' hide MediaAccessFailure;

import '../support/support.dart';
import 'state_support.dart';

/// Records save reasons.
class RecordingRepository extends FakeProjectRepository {
  /// Reasons of every save, in order.
  final List<SaveReason> reasons = [];

  /// When set, saves wait for it.
  Completer<void>? holdSaves;

  @override
  Future<SaveReceipt> save(EditSession session, {required SaveReason reason}) async {
    reasons.add(reason);
    final hold = holdSaves;
    if (hold != null) await hold.future;
    return super.save(session, reason: reason);
  }
}

/// A project with one 3 s text item at 0 (30 fps).
EditProject textProject(FakeProjectRepository repo, {String name = 'Trip'}) {
  final empty = repo.seedEmpty(name);
  final s = EditSession(empty, ids: SeededIdGenerator(11));
  final out = s.apply(const AddText(0));
  expect(out.changed, isTrue, reason: '$out');
  repo.seed(s.committedProject);
  return s.committedProject;
}

Future<void> drain() => Future<void>.delayed(Duration.zero);

ItemId onlyItem(EditProject p) => p.tracks.expand((t) => t.items).single.id;

void main() {
  group('open', () {
    test('opens the project and the preview, sends the plan and seeks exactly to the quantized playhead', () async {
      final repo = RecordingRepository();
      final project = textProject(repo);
      final rig = ControllerRig(repository: repo, id: project.id);
      await rig.open(initialPlayhead: 1234567);

      final c = rig.controller;
      final rate = project.settings.frameRate;
      final t = rate.quantize(1234567);
      expect(c.state.phase, EditorPhase.ready);
      expect(c.state.project!.name, 'Trip');
      expect(c.state.history.canUndo, isFalse);
      expect(c.state.save.phase, SavePhase.clean);
      expect(c.state.preview.phase, PreviewPhase.ready, reason: 'first frame after the first plan');
      expect(rig.engine.calls, containsAllInOrder(['openPreview', 'preview.seek']));
      expect(rig.preview.plan, isNotNull);
      expect(rig.preview.time, t);
      expect(rig.session.openedAt, t);
      expect(rig.session.initialSeek!.displayedFrameTime, t);
      expect(c.state.project!.view.playhead, t);
      expect(rig.preview.config.canvasWidth, project.settings.canvas.widthPx);
      expect(c.shellStatus.value.phase, EditorShellPhase.ready);
      expect(c.shellStatus.value.projectName, 'Trip');
      await c.close();
    });

    test('clamps the initial playhead to the project', () async {
      final repo = RecordingRepository();
      final project = textProject(repo);
      final rig = ControllerRig(repository: repo, id: project.id);
      await rig.open(initialPlayhead: 99 * microsPerSecond);
      expect(rig.session.openedAt, project.settings.frameRate.quantize(project.duration));
      await rig.controller.close();
    });

    test('an unknown id fails with ProjectNotFound and the shell shows notFound', () async {
      final repo = RecordingRepository();
      final rig = ControllerRig(repository: repo, id: const ProjectId('pj_missing'));
      await rig.open();
      expect(rig.controller.state.phase, EditorPhase.failed);
      expect(rig.controller.state.failure, isA<ProjectNotFound>());
      expect(rig.controller.shellStatus.value.phase, EditorShellPhase.notFound);
      expect(rig.controller.shellStatus.value.failureTitle, "This project isn't available");
      expect(rig.engine.calls, isNot(contains('openPreview')));
      final out = await rig.controller.close();
      expect(out.saved, isTrue);
      expect(rig.released, 1);
    });

    test('a newer schema fails with ProjectNeedsNewerApp; corrupt with ProjectCorrupt', () async {
      for (final (kind, type) in [(StoreFailureKind.newerSchema, ProjectNeedsNewerApp), (StoreFailureKind.corrupt, ProjectCorrupt)]) {
        final repo = RecordingRepository();
        final project = textProject(repo);
        repo.failNext['open'] = StoreFailure(kind);
        final rig = ControllerRig(repository: repo, id: project.id);
        await rig.open();
        expect(rig.controller.state.failure.runtimeType, type);
        expect(rig.controller.shellStatus.value.phase, EditorShellPhase.failed);
      }
    });

    test('read-only projects open, edit in memory and never save', () async {
      final repo = RecordingRepository();
      final project = textProject(repo);
      repo.openResults[project.id] = (p) => LoadedProject(project: p, health: ProjectHealth.readOnlyNewer);
      final rig = ControllerRig(repository: repo, id: project.id);
      await rig.open();
      final c = rig.controller;
      expect(c.readOnly, isTrue);
      expect(c.state.save, SaveStatus.readOnly);
      expect(rig.eventsOf<EditorToast>().map((e) => e.message), contains(EditorMessages.openedReadOnly));
      expect(c.apply(const AddMarker(0)), isA<EditApplied>());
      expect(c.state.save, SaveStatus.readOnly);
      expect(repo.autosaveRequests, 0);
      expect((await c.saveNow(manual: true)).skipped, isTrue);
      c.onAppHidden();
      await c.close();
      expect(repo.reasons, isEmpty);
    });

    test('migration, repairs, recovery and exceeded limits are surfaced as events', () async {
      final repo = RecordingRepository();
      final project = textProject(repo);
      final recovery = RecoverableSession(
        projectId: project.id,
        projectName: 'Trip',
        journalRevision: 9,
        mainRevision: 3,
        journalSavedAt: DateTime.utc(2026, 10, 10),
      );
      repo.openResults[project.id] = (p) => LoadedProject(
            project: p,
            migratedFrom: 1,
            warnings: const [ProjectOpenWarning('repairedOverlap')],
            pendingRecovery: recovery,
          );
      final engine = FakeEditorEngine(validatePlans: false)
        ..caps = const EditorCapabilities(supported: true, maxConcurrentVideoLayers: 0, maxVisualSequences: 0);
      final rig = ControllerRig(repository: repo, id: project.id, engine: engine);
      await rig.open();
      await drain();
      final toasts = rig.eventsOf<EditorToast>().map((e) => e.message).toList();
      expect(toasts, containsAll([EditorMessages.migrated, EditorMessages.repaired]));
      expect(rig.eventsOf<EditorRecoveryAvailable>().single.session, recovery);
      expect(rig.controller.state.phase, EditorPhase.ready);
      await rig.controller.close();
    });

    test('a preview that fails to start leaves the editor editable with a failed preview', () async {
      final repo = RecordingRepository();
      final project = textProject(repo);
      final engine = FakeEditorEngine(validatePlans: false);
      engine.failNext['openPreview'] = EngineFailure.of(EngineErrorCode.gpuUnavailable);
      final rig = ControllerRig(repository: repo, id: project.id, engine: engine);
      await rig.open();
      final c = rig.controller;
      expect(c.state.phase, EditorPhase.ready);
      expect(c.state.preview.phase, PreviewPhase.failed);
      expect(c.state.preview.failure!.engineCode, EngineErrorCode.gpuUnavailable);
      expect(c.apply(const AddMarker(0)), isA<EditApplied>());
      await c.restartPreview();
      await rig.settle();
      expect(c.state.preview.phase, PreviewPhase.ready);
      expect(rig.preview.plan!.rev, c.state.project!.timeline.revision);
      await c.close();
    });

    test('an engine failure from PlanSync marks the preview failed; "Restart preview" recovers it', () async {
      final repo = RecordingRepository();
      final project = textProject(repo);
      final rig = ControllerRig(repository: repo, id: project.id);
      await rig.open();
      final c = rig.controller;
      expect(c.state.preview.phase, PreviewPhase.ready);
      rig.engine.failNext['preview.setPlan'] = EngineFailure.of(EngineErrorCode.decodeFailed);
      await c.restartPreview();
      await rig.settle();
      expect(c.state.preview.phase, PreviewPhase.failed);
      expect(c.state.preview.failure, const PreviewFailed(engineCode: EngineErrorCode.decodeFailed));
      expect(rig.eventsOf<EditorAnnouncement>().map((e) => e.text), contains('Preview stopped'));
      expect(EditorMessages.forFailure(c.state.preview.failure!).action, EditorMessageAction.restartPreview);
      await c.restartPreview();
      await rig.settle();
      expect(c.state.preview.phase, isNot(PreviewPhase.failed));
      expect(rig.sync.currentStatus, isNot(PlanSyncStatus.failed));
      await c.close();
    });
  });

  group('apply', () {
    late RecordingRepository repo;
    late EditProject project;
    late ControllerRig rig;

    setUp(() async {
      repo = RecordingRepository();
      project = textProject(repo);
      rig = ControllerRig(repository: repo, id: project.id);
      await rig.open();
    });

    tearDown(() => rig.controller.close());

    test('a commit updates state, schedules one plan patch, requests one autosave and emits an event', () async {
      final c = rig.controller;
      final schedules = rig.sync.schedules;
      final result = c.apply(const AddMarker(500000, name: 'Beat'));
      expect(result, isA<EditApplied>());
      expect(c.state.history.canUndo, isTrue);
      expect(c.state.history.undoLabel, (result as EditApplied).label);
      expect(c.state.save.phase, SavePhase.edited);
      expect(c.state.project!.timeline.markers, hasLength(1));
      expect(rig.sync.schedules, schedules + 1);
      expect(repo.autosaveRequests, 1);
      await drain();
      expect(rig.eventsOf<EditorCommitted>().single.label, result.label);
      final compiles = rig.sync.stats.compiles;
      await rig.settle();
      expect(rig.sync.stats.compiles, greaterThan(compiles - 1));
      expect(rig.sync.currentStatus, PlanSyncStatus.idle);
      expect(c.shellStatus.value.save, EditorSaveIndicator.edited);
      expect(c.shellStatus.value.canUndo, isTrue);
      expect(c.shellStatus.value.undoLabel, result.label);
    });

    test('a rejection is an info toast with copy, a warning haptic, and changes nothing', () async {
      final c = rig.controller;
      final before = c.state;
      final schedules = rig.sync.schedules;
      final result = c.apply(const SetText(ItemId('it_nope'), 'x'));
      expect(result, isA<EditRejected>());
      final rejection = (result as EditRejected).reason;
      expect(rejection, isA<ItemNotFound>());
      await drain();
      final toast = rig.eventsOf<EditorToast>().last;
      expect(toast.kind, EditorToastKind.info);
      expect(toast.message, EditorMessages.forRejection(rejection));
      expect(rig.eventsOf<EditorHaptic>().last.kind, EditorHapticKind.warning);
      expect(rig.eventsOf<EditorRejected>().single.rejection, rejection);
      expect(c.state, before);
      expect(rig.sync.schedules, schedules);
      expect(repo.autosaveRequests, 0);
    });

    test('a no-op command records nothing', () {
      final c = rig.controller;
      final id = onlyItem(project);
      final text = (project.index.item(id)! as TextItem).text;
      final schedules = rig.sync.schedules;
      expect(c.apply(SetText(id, text)), isA<EditUnchanged>());
      expect(c.state.history.length, 0);
      expect(rig.sync.schedules, schedules);
      expect(repo.autosaveRequests, 0);
    });

    test('typing coalesces into one history entry within the window', () {
      final c = rig.controller;
      final id = onlyItem(project);
      final key = SetText(id, '').coalesceKey;
      c.apply(SetText(id, 'H'), coalesceKey: key);
      rig.clock.advance(const Duration(milliseconds: 300));
      c.apply(SetText(id, 'Hi'), coalesceKey: key);
      expect(c.state.history.length, 1);
      expect((c.state.project!.index.item(id)! as TextItem).text, 'Hi');
      rig.clock.advance(const Duration(seconds: 2));
      c.apply(SetText(id, 'Hi!'), coalesceKey: key);
      expect(c.state.history.length, 2);
      expect(repo.autosaveRequests, 3, reason: 'every commit requests an autosave; the store debounces');
    });

    test('the selection keeps only items that still exist and item inspectors close with them', () {
      final c = rig.controller;
      final id = onlyItem(project);
      c.select(id);
      c.openInspector(TextInspector(id));
      c.openInspector(TransformInspector(id));
      expect(c.state.selection.primary, id);
      c.apply(DeleteItems({id}));
      expect(c.state.selection.items, isEmpty);
      expect(c.state.inspector, isNull);
    });

    test('nothing is applied before open or after close', () async {
      final c = rig.controller;
      await c.close();
      expect(c.apply(const AddMarker(0)), isA<EditUnchanged>());
      expect(c.undo(), isFalse);
      expect(c.beginTransaction('Move').isOpen, isFalse);
    });
  });

  group('undo and redo', () {
    late RecordingRepository repo;
    late EditProject project;
    late ControllerRig rig;

    setUp(() async {
      repo = RecordingRepository();
      project = textProject(repo);
      rig = ControllerRig(repository: repo, id: project.id);
      await rig.open();
    });

    tearDown(() => rig.controller.close());

    test('each undo, redo and jump schedules exactly one plan patch', () async {
      final c = rig.controller;
      final id = onlyItem(project);
      c.apply(SetText(id, 'One'));
      c.apply(SetText(id, 'Two'));
      c.apply(const AddMarker(0));
      var schedules = rig.sync.schedules;
      expect(c.undo(), isTrue);
      expect(rig.sync.schedules, ++schedules);
      expect(c.state.history.position, 2);
      expect(c.redo(), isTrue);
      expect(rig.sync.schedules, ++schedules);
      c.jumpHistory(-3);
      expect(rig.sync.schedules, ++schedules, reason: 'N steps, one patch');
      expect(c.state.history.position, 0);
      expect((c.state.project!.index.item(id)! as TextItem).text, (project.index.item(id)! as TextItem).text);
      expect(c.undo(), isFalse);
      expect(rig.sync.schedules, schedules);
      await rig.settle();
      expect(rig.sync.currentStatus, PlanSyncStatus.idle);
      expect(rig.eventsOf<EditorHistoryMoved>().last.labels, hasLength(3));
    });

    test('undo restores the selection to the affected items and toasts on touch, at most three in a row', () async {
      final c = rig.controller;
      final id = onlyItem(project);
      for (final t in ['a', 'b', 'c', 'd', 'e']) {
        c.apply(SetText(id, t));
      }
      c.clearSelection();
      for (var i = 0; i < 5; i++) {
        c.undo();
      }
      expect(c.state.selection.items, {id});
      await drain();
      final toasts = rig.eventsOf<EditorToast>().where((t) => t.message.title.startsWith('Undid')).toList();
      expect(toasts, hasLength(3));
      expect(toasts.every((t) => t.touchOnly), isTrue);
      expect(toasts.first.message.title, 'Undid Edit text');
      expect(rig.eventsOf<EditorAnnouncement>().where((a) => a.text.startsWith('Undid')), hasLength(5));
      // A commit resets the streak.
      c.apply(const AddMarker(0));
      c.undo();
      await drain();
      expect(rig.eventsOf<EditorToast>().last.message.title, startsWith('Undid'));
    });

    test('undo and redo request an autosave', () {
      final c = rig.controller;
      c.apply(const AddMarker(0));
      c.undo();
      c.redo();
      expect(repo.autosaveRequests, 3);
    });
  });

  group('transactions', () {
    late RecordingRepository repo;
    late EditProject project;
    late ControllerRig rig;

    setUp(() async {
      repo = RecordingRepository();
      project = textProject(repo);
      rig = ControllerRig(repository: repo, id: project.id);
      await rig.open();
    });

    tearDown(() => rig.controller.close());

    test('commit records one history entry, one plan patch and one autosave request', () async {
      final c = rig.controller;
      final id = onlyItem(project);
      final schedules = rig.sync.schedules;
      final tx = c.beginTransaction('Move clip');
      expect(tx.isOpen, isTrue);
      tx.update(MoveItems({id}, 1 * microsPerSecond));
      tx.update(MoveItems({id}, 2 * microsPerSecond));
      expect(tx.working.index.item(id)!.start, 2 * microsPerSecond, reason: 'updates replace, never accumulate');
      expect(rig.sync.schedules, schedules, reason: 'structural gesture changes reach the preview on commit');
      expect(repo.autosaveRequests, 0);
      final result = tx.commit();
      expect(result, isA<EditApplied>());
      expect(tx.isOpen, isFalse);
      expect(c.state.history.length, 1);
      expect(c.state.history.undoLabel, 'Move clip');
      expect(c.state.inTransaction, isFalse);
      expect(c.state.project!.index.item(id)!.start, 2 * microsPerSecond);
      expect(rig.sync.schedules, schedules + 1);
      expect(repo.autosaveRequests, 1);
      expect(tx.commit(), isA<EditUnchanged>(), reason: 'closed transactions are no-ops');
    });

    test('state emission is coalesced to one per frame', () {
      final c = rig.controller;
      final id = onlyItem(project);
      final seen = <EditorState>[];
      final remove = c.addListener(seen.add, fireImmediately: false);
      final tx = c.beginTransaction('Move clip');
      for (var i = 1; i <= 5; i++) {
        tx.update(MoveItems({id}, i * 100000));
      }
      expect(seen, isEmpty, reason: 'nothing before the frame');
      expect(rig.frames.pending, 1);
      rig.frames.flush();
      expect(seen, hasLength(1));
      expect(seen.single.inTransaction, isTrue);
      expect(seen.single.project!.index.item(id)!.start, 500000);
      remove();
      tx.cancel();
    });

    test('cancel restores the base project and records nothing', () {
      final c = rig.controller;
      final id = onlyItem(project);
      final base = c.state.project;
      final schedules = rig.sync.schedules;
      final tx = c.beginTransaction('Move clip');
      tx.update(MoveItems({id}, 1 * microsPerSecond));
      rig.frames.flush();
      expect(c.state.project, isNot(same(base)));
      tx.cancel();
      expect(tx.isOpen, isFalse);
      expect(c.state.project, same(base));
      expect(c.state.inTransaction, isFalse);
      expect(c.state.history.length, 0);
      expect(rig.sync.schedules, schedules);
      expect(repo.autosaveRequests, 0);
    });

    test('a refused update shows the base; a new transaction or an apply cancels the open one', () {
      final c = rig.controller;
      final id = onlyItem(project);
      final tx = c.beginTransaction('Trim');
      expect(tx.update(MoveItems({id}, -5 * microsPerSecond)), isA<EditRejected>());
      expect(tx.working.index.item(id)!.start, 0);
      final second = c.beginTransaction('Move');
      expect(tx.isOpen, isFalse);
      c.apply(const AddMarker(0));
      expect(second.isOpen, isFalse);
      expect(c.transaction, isNull);
      expect(c.state.history.length, 1);
    });

    test('property-only updates send transients; commit clears them after the plan applies', () async {
      final c = rig.controller;
      c.applyPoolChange(AddAssets([imageAsset('md_photo1')]));
      final inserted = c.apply(InsertMedia([const MediaId('md_photo1')], 0, mode: InsertMode.newLane));
      expect(inserted, isA<EditApplied>(), reason: '$inserted');
      final clip = c.state.project!.tracks.expand((t) => t.items).whereType<MediaClip>().single.id;
      await rig.settle();
      final tx = c.beginTransaction('Opacity');
      tx.update(SetVisual([clip], const VisualProps(transform: Transform2D(opacity: 0.4))));
      tx.update(SetVisual([clip], const VisualProps(transform: Transform2D(opacity: 0.5))));
      await rig.settle();
      expect(rig.preview.transients.keys, contains(clip));
      expect(rig.sync.stats.transientsSent, greaterThanOrEqualTo(1));
      final schedules = rig.sync.schedules;
      tx.commit();
      expect(rig.sync.schedules, schedules + 1);
      await rig.settle();
      expect(rig.preview.transients, isEmpty);
      expect(rig.preview.plan!.rev, c.state.project!.timeline.revision);
    });

    test('structural updates send no transients', () async {
      final c = rig.controller;
      final id = onlyItem(project);
      final tx = c.beginTransaction('Move');
      tx.update(MoveItems({id}, 1 * microsPerSecond));
      await rig.settle();
      expect(rig.sync.stats.transientsSent, 0);
      tx.cancel();
    });

    test('the app going inactive cancels the gesture and requests an autosave', () {
      final c = rig.controller;
      final id = onlyItem(project);
      final tx = c.beginTransaction('Move');
      tx.update(MoveItems({id}, 1 * microsPerSecond));
      c.onAppInactive();
      expect(tx.isOpen, isFalse);
      expect(c.state.project!.index.item(id)!.start, 0);
      expect(repo.autosaveRequests, 1);
      expect(rig.engine.calls, contains('preview.pause'));
    });
  });

  group('save, hide and close', () {
    test('hide saves the edits (lifecycle save) and only flushes when nothing changed', () async {
      final repo = RecordingRepository();
      final project = textProject(repo);
      final rig = ControllerRig(repository: repo, id: project.id);
      await rig.open();
      final c = rig.controller;
      c.onAppHidden();
      await rig.settle();
      expect(repo.reasons, isEmpty);
      expect(repo.calls, contains('flush:${project.id}'));
      c.apply(const AddMarker(0));
      c.onAppHidden();
      await rig.settle();
      expect(repo.reasons, [SaveReason.lifecycle]);
      expect(c.state.save.phase, SavePhase.saved);
      await c.close();
      expect(repo.reasons, [SaveReason.lifecycle], reason: 'nothing new to save on close');
    });

    test('close flushes the edits, disposes the preview, closes the project and releases the provider', () async {
      final repo = RecordingRepository();
      final project = textProject(repo);
      final rig = ControllerRig(repository: repo, id: project.id);
      await rig.open();
      final c = rig.controller;
      c.apply(const AddMarker(0));
      final first = c.close();
      expect(identical(first, c.close()), isTrue);
      final out = await first;
      expect(out.saved, isTrue);
      expect(repo.reasons, [SaveReason.close]);
      expect(repo.projects[project.id]!.timeline.markers, hasLength(1));
      expect(repo.calls.last, 'close:${project.id}');
      expect(rig.preview.disposed, isTrue);
      expect(rig.session.isOpen, isFalse);
      expect(c.state.phase, EditorPhase.closed);
      expect(rig.released, 1);
    });

    test('close never throws and reports a failed flush', () async {
      final repo = RecordingRepository();
      final project = textProject(repo);
      final rig = ControllerRig(repository: repo, id: project.id);
      await rig.open();
      final c = rig.controller;
      c.apply(const AddMarker(0));
      repo.failNext['save'] = const StoreFailure(StoreFailureKind.diskFull);
      final out = await c.close();
      expect(out.saved, isFalse);
      expect(out.failure, const SaveFailed(StoreFailureKind.diskFull));
      expect(rig.released, 1);
      expect(rig.session.isOpen, isFalse);
    });

    test('flushBeforeClose gives up after the timeout', () async {
      final repo = RecordingRepository()..holdSaves = Completer<void>();
      final project = textProject(repo);
      final rig = ControllerRig(repository: repo, id: project.id);
      final c = EditorController(
        id: project.id,
        session: EditorSession(project.id),
        repository: repo,
        engine: rig.engine,
        frames: ManualFrames(),
        flushTimeout: const Duration(milliseconds: 50),
      );
      await c.open();
      c.apply(const AddMarker(0));
      expect(await c.flushBeforeClose(), isFalse);
      repo.holdSaves!.complete();
      await c.close();
    });

    test('a save failure shows "Couldn\'t save" once per failure streak', () async {
      final repo = RecordingRepository();
      final project = textProject(repo);
      final rig = ControllerRig(repository: repo, id: project.id);
      await rig.open();
      final c = rig.controller;
      final full = EditorMessages.forFailure(const SaveFailed(StoreFailureKind.diskFull));
      c.apply(const AddMarker(0));
      repo.failNext['save'] = const StoreFailure(StoreFailureKind.diskFull);
      expect((await c.saveNow()).ok, isFalse);
      expect(c.state.save.phase, SavePhase.failed);
      expect(c.shellStatus.value.save, EditorSaveIndicator.failed);
      repo.failNext['save'] = const StoreFailure(StoreFailureKind.diskFull);
      await c.saveNow();
      await drain();
      List<EditorToast> errors() => rig.eventsOf<EditorToast>().where((t) => t.kind == EditorToastKind.error).toList();
      expect(errors(), hasLength(1));
      expect(errors().single.message, full);
      expect(full.title, "Couldn't save changes: your device is full");
      final ok = await c.saveNow(manual: true);
      expect(ok.ok, isTrue);
      expect(c.state.save.phase, SavePhase.saved);
      await drain();
      expect(rig.eventsOf<EditorToast>().last.message, EditorMessages.saved);
      c.apply(const AddMarker(100000));
      repo.failNext['save'] = const StoreFailure(StoreFailureKind.diskFull);
      await c.saveNow();
      await drain();
      expect(errors(), hasLength(2), reason: 'a new streak');
      await c.close();
    });

    test('autosave statuses of the store drive SaveStatus (FileProjectRepository)', () async {
      final mem = InMemoryProjectRepository(clock: () => DateTime.utc(2026, 10, 11));
      final fake = FakeProjectRepository();
      final project = textProject(fake);
      await mem.seed(project);
      final rig = ControllerRig(repository: mem.inner, id: project.id);
      await rig.open();
      final c = rig.controller;
      c.apply(const AddMarker(0));
      expect(c.state.save.phase, SavePhase.edited);
      await mem.inner.flush(project.id);
      await rig.settle();
      expect(c.state.save.phase, SavePhase.saved);
      final out = await c.close();
      expect(out.saved, isTrue);
      final reopened = await mem.open(project.id);
      expect(reopened.project.timeline.markers, hasLength(1));
      await mem.close(project.id);
      await mem.dispose();
    });
  });

  group('selection, inspector, modes and back', () {
    late RecordingRepository repo;
    late EditProject project;
    late ControllerRig rig;

    setUp(() async {
      repo = RecordingRepository();
      project = textProject(repo);
      rig = ControllerRig(repository: repo, id: project.id);
      await rig.open();
    });

    tearDown(() => rig.controller.close());

    test('select modes, selectAt, selectAll and item inspectors following the primary item', () {
      final c = rig.controller;
      final a = onlyItem(project);
      c.apply(const AddText(4 * microsPerSecond));
      final b = c.state.project!.tracks.expand((t) => t.items).map((i) => i.id).firstWhere((i) => i != a);
      c.select(a);
      c.openInspector(TextInspector(a));
      c.select(b);
      expect(c.state.inspector, TextInspector(b));
      c.select(a, mode: SelectMode.toggle);
      expect(c.state.selection.items, {a, b});
      c.select(a, mode: SelectMode.toggle);
      expect(c.state.selection.items, {b});
      c.selectAll();
      expect(c.state.selection.items, {a, b});
      final lane = c.state.project!.index.locate(a)!.track.id;
      c.selectAt(lane, 1000);
      expect(c.state.selection.items, {a});
      c.openInspector(const CanvasInspector());
      c.clearSelection();
      expect(c.state.inspector, const CanvasInspector(), reason: 'project panels stay');
      c.setTool(ToolId.text);
      expect(c.state.tool, ToolId.text);
    });

    test('ripple and snapping persist in the view state; other modes are session-only', () {
      final c = rig.controller;
      expect(c.state.modes.centerPlayhead, isTrue);
      c.setModes((m) => m.copyWith(ripple: false, multiSelect: true));
      expect(c.state.modes.ripple, isFalse);
      expect(c.state.modes.multiSelect, isTrue);
      expect(c.state.project!.view.rippleEnabled, isFalse);
      expect(c.state.history.length, 0, reason: 'modes are not history');
    });

    test('back steps: cancel gesture, close panel, clear selection, then nothing', () {
      final c = rig.controller;
      final id = onlyItem(project);
      c.select(id);
      c.openInspector(TextInspector(id));
      c.beginTransaction('Move').update(MoveItems({id}, 100000));
      expect(c.dismissForBack(EditorBackStep.cancelGesture), isTrue);
      expect(c.dismissForBack(EditorBackStep.cancelGesture), isFalse);
      expect(c.dismissForBack(EditorBackStep.closePanel), isTrue);
      expect(c.shellStatus.value.inspectorOpen, isFalse);
      expect(c.dismissForBack(EditorBackStep.clearSelection), isTrue);
      expect(c.dismissForBack(EditorBackStep.clearSelection), isFalse);
      expect(c.dismissForBack(EditorBackStep.exitFullscreen), isFalse);
    });

    test('media health and tasks are set by their controllers', () {
      final c = rig.controller;
      c.setMediaHealth(MediaHealth(missing: {const MediaId('md_1')}, relinkRequired: true));
      expect(c.state.media.isOk, isFalse);
      c.setTasks(const [EditorTaskInfo(id: 'j1', kind: EditorTaskKind.proxy, label: 'Optimizing a clip', progress: 0.5)]);
      expect(c.state.tasks.single.progress, 0.5);
    });

    test('memory pressure trims the engine caches', () async {
      rig.controller.onMemoryPressure();
      await rig.settle();
      expect(rig.engine.calls, contains('trimCaches.memoryPressure'));
    });
  });

  group('providers', () {
    test('the controller family keeps itself alive until close() completes', () async {
      final h = EditorTestHarness();
      final id = h.repository.seedEmpty('Provider').id;
      final container = h.container();
      final c = container.read(editorControllerProvider(id).notifier);
      expect(container.read(editorSessionProvider(id)), same(c.session));
      await Future<void>.delayed(Duration.zero);
      expect(container.exists(editorControllerProvider(id)), isTrue, reason: 'keepAlive while open');
      await c.open();
      expect(c.state.phase, EditorPhase.ready);
      expect(container.read(editorControllerProvider(id)).project!.name, 'Provider');
      await c.close();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(container.exists(editorControllerProvider(id)), isFalse);
      expect(h.repository.calls, contains('close:$id'));
    });

    test('the default plan compiler port compiles with every media offline', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(planCompilerPortProvider), same(ResolvingPlanCompilerPort.offline));
    });
  });

  group('poster', () {
    test('captures an engine thumbnail of the clip under the playhead', () async {
      final repo = RecordingRepository();
      final project = textProject(repo);
      final rig = ControllerRig(repository: repo, id: project.id);
      await rig.open();
      final c = rig.controller;
      expect(await EditorPosterCapture.capture(EditSession(project)), isNull, reason: 'not attached');
      c.applyPoolChange(AddAssets([imageAsset('md_photo2')]));
      c.apply(InsertMedia([const MediaId('md_photo2')], 0, mode: InsertMode.newLane));
      final target = EditorPosterCapture.targetOf(c.state.project!);
      expect(target, isNotNull);
      expect(target!.$1.media, const MediaId('md_photo2'));
      expect(target.$2, 0, reason: 'images show their only frame');
      final bytes = await EditorPosterCapture.capture(rig.session.edit);
      expect(bytes, isNull, reason: 'the fake engine returns empty strips');
      final request = rig.engine.thumbnails.requests.last;
      expect(request.framesPerTile, 1);
      expect(request.heightPx, EditorPosterCapture.heightPx);
      expect(request.media.uri, 'file:///fake/md_photo2.png');
      await c.close();
    });

    test('no visual clip means no poster', () {
      final repo = RecordingRepository();
      final project = textProject(repo);
      expect(EditorPosterCapture.targetOf(project), isNull);
    });
  });
}
