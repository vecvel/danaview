// OWNER: FIX-JOB-RESUME
//
// QA-05 D3: pending reverse, freeze and proxy jobs resume when the editor opens, with nothing
// reading the Tasks controller first (ARCH §15 "jobs are re-queued automatically"): after a
// process death (the project on disk holds pending assets with stale job ids) and after a close
// mid-job followed by a reopen, each pending job is re-queued exactly once.

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show EditorTaskKind;
import 'package:danaview_editor/src/editor/state/tasks_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show EngineError, EngineErrorCode, GeneratedAsset;
import 'package:danaview_editor_engine_api/testing.dart';

import 'tasks_rig.dart';

final String _videoHash = 'md_video'.padRight(40, '0');

/// A reversed rendition left pending by a killed job.
MediaAsset _staleRendition() => rigAsset('md_rev', MediaKind.video,
    status: const PendingStatus('reverse-before-kill'),
    derived: ReversedSpec(TaskIds.videoMedia, const TimeRange(3 * s, 19 * s), sourceQuickHash: _videoHash));

/// A freeze still left pending by a killed job.
MediaAsset _staleStill() => rigAsset('md_still', MediaKind.still,
    hasAudio: false, status: const PendingStatus('freeze-before-kill'), derived: StillSpec(TaskIds.videoMedia, 2 * s, sourceQuickHash: _videoHash));

MediaClip get _reversedVideo => rigClip('it_video', 'md_video', 0, 12 * s, sourceIn: 5 * s, reversed: true);

/// Completes [job] in real async: jobs resumed on open were started (and listened to) inside the
/// open's real-async zone, so their callbacks run there.
Future<void> _complete(TasksRig rig, FakeMediaJob<Object?> job, {TimeUs? duration}) =>
    rig.real(() async => job.complete(GeneratedAsset(path: '/out/${job.id}', sizeBytes: 4096, duration: duration)));

List<FakeMediaJob<Object?>> _jobs(TasksRig rig, String kind) => [for (final j in rig.jobs.created) if (j.id.startsWith('$kind-')) j];

/// Seeds a pending proxy on the silent video (a proxy job that died with the app).
Future<TasksRig> _pumpWithPending(WidgetTester tester, {bool still = false}) async {
  final rig = await TasksRig.pump(
    tester,
    video: still ? rigClip('it_video', 'md_still', 0, 2 * s) : _reversedVideo,
    extraAssets: [still ? _staleStill() : _staleRendition()],
    readTasks: false,
    engine: FakeEditorEngine(validatePlans: false),
  );
  return rig;
}

void main() {
  group('after a process death', () {
    testWidgets('a pending reverse rendition the timeline needs resumes on open without reading the Tasks controller', (tester) async {
      final rig = await _pumpWithPending(tester);
      await rig.settle();
      final reverse = _jobs(rig, 'reverse');
      expect(reverse, hasLength(1), reason: 'the editor open alone re-queues it');
      expect(rig.asset(const MediaId('md_rev')).status, PendingStatus(reverse.single.id));
      expect(rig.state.tasks.where((t) => t.kind == EditorTaskKind.reverse), hasLength(1));
      expect(TasksController.exportBlockersOf(rig.project), isNotEmpty, reason: 'export waits while it runs');

      await _complete(rig, reverse.single, duration: 16 * s);
      expect(rig.asset(const MediaId('md_rev')).status, isA<ReadyStatus>());
      expect(TasksController.exportBlockersOf(rig.project), isEmpty, reason: 'export no longer waits forever');
      expect(rig.state.tasks, isEmpty);
      await rig.settle();
      expect(_jobs(rig, 'reverse'), hasLength(1), reason: 'nothing starts it twice');
      await rig.finish();
    });

    testWidgets('a pending freeze still on the timeline resumes on open', (tester) async {
      final rig = await _pumpWithPending(tester, still: true);
      await rig.settle();
      final freeze = _jobs(rig, 'freezeFrame');
      expect(freeze, hasLength(1));
      expect(rig.asset(const MediaId('md_still')).status, PendingStatus(freeze.single.id));
      await _complete(rig, freeze.single);
      expect(rig.asset(const MediaId('md_still')).status, isA<ReadyStatus>());
      await rig.finish();
    });

    testWidgets('a pending proxy resumes on open and becomes ready', (tester) async {
      final proxied = rigAsset('md_proxied', MediaKind.video).copyWith(proxy: ProxyState.pending);
      final rig = await TasksRig.pump(tester, extraAssets: [proxied], readTasks: false);
      await rig.settle();
      final proxy = _jobs(rig, 'proxy');
      expect(proxy, hasLength(1));
      await _complete(rig, proxy.single);
      expect(rig.asset(const MediaId('md_proxied')).proxy, ProxyState.ready);
      await rig.finish();
    });

    testWidgets('an engine that cannot run jobs does not break the open', (tester) async {
      final engine = FakeEditorEngine(validatePlans: false);
      engine.log.failNext['jobs.reverse'] = const EngineError(EngineErrorCode.notSupportedOnDevice, debugDetail: 'no jobs');
      final rig = await TasksRig.pump(tester, video: _reversedVideo, extraAssets: [_staleRendition()], readTasks: false, engine: engine);
      await rig.settle();
      expect(rig.state.phase.name, 'ready');
      expect(rig.asset(const MediaId('md_rev')).status, isA<FailedStatus>(), reason: 'reported as a failed task, once');
      expect(rig.state.tasks.where((t) => t.failed), hasLength(1));
      await rig.settle();
      expect(_jobs(rig, 'reverse'), hasLength(1));
      await rig.finish();
    });
  });

  group('close mid-job, then reopen', () {
    testWidgets('the cancelled job is re-queued exactly once on reopen', (tester) async {
      final rig = await _pumpWithPending(tester);
      await rig.settle();
      final first = _jobs(rig, 'reverse').single;
      await rig.real(() async {
        await rig.editor.close();
      });
      expect(first.cancelled, isTrue);
      expect(rig.harness.repository.projects[rig.id]!.pool[const MediaId('md_rev')]!.status, isA<PendingStatus>());

      await rig.real(() => rig.editor.open());
      await rig.settle();
      final again = _jobs(rig, 'reverse');
      expect(again, hasLength(2), reason: 'one new job on reopen');
      expect(rig.asset(const MediaId('md_rev')).status, PendingStatus(again.last.id));
      await rig.settle();
      expect(_jobs(rig, 'reverse'), hasLength(2));
      await _complete(rig, again.last, duration: 16 * s);
      expect(rig.asset(const MediaId('md_rev')).status, isA<ReadyStatus>());
      await rig.finish();
    });

    testWidgets('a Tasks controller kept alive through the close resumes on reopen', (tester) async {
      final rig = await _pumpWithPending(tester);
      final hold = rig.container.listen<TasksController>(tasksControllerProvider(rig.id), (_, __) {});
      await rig.settle();
      final controller = hold.read();
      expect(_jobs(rig, 'reverse'), hasLength(1));
      await rig.real(() async {
        await rig.editor.close();
      });
      expect(controller.suspended, isTrue);

      await rig.real(() => rig.editor.open());
      await rig.settle();
      expect(identical(hold.read(), controller), isTrue);
      expect(controller.suspended, isFalse);
      final jobs = _jobs(rig, 'reverse');
      expect(jobs, hasLength(2), reason: 'resumed once, not left suspended');
      expect(controller.taskOf(const MediaId('md_rev')), jobs.last.id);
      hold.close();
      await rig.finish();
    });
  });
}
