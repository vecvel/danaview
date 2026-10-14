// OWNER: UX-35
//
// TasksController (ux.md §10.15) with fake jobs: reverse and freeze start their engine jobs into the
// project-owned paths, progress reaches EditorState.tasks (the task indicator), completion turns the
// asset ready, failure keeps a retryable row, cancel plays the clip forward / removes the still,
// proxies, other producers (track / begin), the export gating flag, quiet suspension on close and
// resuming pending assets on open.

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/state/tasks_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show unstartedJobId;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show EngineFailure, EngineErrorCode, JobPriority;
import 'package:danaview_editor_engine_api/testing.dart';

import 'tasks_rig.dart';

MediaAsset? renditionOf(TasksRig rig, ItemId id) => TasksController.renditionFor(rig.project.pool, rig.clip(id));

void main() {
  group('reverse', () {
    testWidgets('turning reverse on adds a pending rendition and starts one interactive reverse job', (tester) async {
      final rig = await TasksRig.pump(tester);
      final result = rig.tasks.reverse(TaskIds.video);
      await rig.settle();
      expect(result, isA<EditApplied>());
      expect(rig.clip(TaskIds.video).reversed, isTrue);
      expect(rig.entries, 1);
      final job = rig.job('reverse');
      expect(job.priority, JobPriority.interactive);
      final r = renditionOf(rig, TaskIds.video)!;
      expect(r.status, PendingStatus(job.id));
      expect((r.derived! as ReversedSpec).media, TaskIds.videoMedia);
      expect((r.locator as AppRelativeLocator).relPath, startsWith('danaview/editor/derived/'));
      expect(rig.state.tasks.single, EditorTaskInfo(id: job.id, kind: EditorTaskKind.reverse, label: 'Reversing a clip'));
      expect(rig.jobs.created.where((j) => j.id.startsWith('reverse-')), hasLength(1), reason: 'started once');
      await rig.finish();
    });

    testWidgets('progress updates the task indicator; done makes the rendition ready and removes the row', (tester) async {
      final rig = await TasksRig.pump(tester);
      rig.tasks.reverse(TaskIds.video);
      await rig.settle();
      final job = rig.job('reverse');
      job.report(0.45);
      await rig.settle();
      expect(rig.state.tasks.single.progress, 0.45);
      expect(rig.tasks.exportBlocked, isTrue);
      await rig.complete(job, bytes: 9000, duration: 16 * s);
      expect(rig.state.tasks, isEmpty);
      final r = renditionOf(rig, TaskIds.video)!;
      expect(r.status, AssetStatus.ready);
      expect(r.fingerprint.sizeBytes, 9000);
      expect(r.fingerprint.quickHash, (r.derived! as ReversedSpec).specHash);
      expect(rig.tasks.exportBlocked, isFalse);
      expect(rig.entries, 1, reason: 'status changes are not history');
      await rig.finish();
    });

    testWidgets('undo restores the forward clip; reverse again reuses the rendition', (tester) async {
      final rig = await TasksRig.pump(tester);
      rig.tasks.reverse(TaskIds.video);
      await rig.settle();
      await rig.complete(rig.job('reverse'));
      rig.editor.undo();
      await rig.settle();
      expect(rig.clip(TaskIds.video).reversed, isFalse);
      rig.tasks.reverse(TaskIds.video);
      await rig.settle();
      expect(rig.jobs.created.where((j) => j.id.startsWith('reverse-')), hasLength(1), reason: 'a ready rendition is reused');
      expect(rig.state.tasks, isEmpty);
      await rig.finish();
    });

    testWidgets('a failure keeps a failed row; Try again starts a new job; Dismiss removes the row', (tester) async {
      final rig = await TasksRig.pump(tester);
      rig.tasks.reverse(TaskIds.video);
      await rig.settle();
      final first = rig.job('reverse');
      first.fail(EngineFailure.of(EngineErrorCode.decodeFailed));
      await rig.settle();
      final row = rig.state.tasks.single;
      expect(row.failed, isTrue);
      expect(renditionOf(rig, TaskIds.video)!.status, const FailedStatus('decodeFailed'));
      expect(rig.tasks.canRetry(row.id), isTrue);
      expect(rig.tasks.canCancel(row.id), isFalse);
      rig.tasks.retry(row.id);
      await rig.settle();
      final second = rig.job('reverse');
      expect(second, isNot(same(first)));
      expect(rig.state.tasks.single.failed, isFalse);
      expect(renditionOf(rig, TaskIds.video)!.status, PendingStatus(second.id));
      second.fail(EngineFailure.of(EngineErrorCode.io));
      await rig.settle();
      rig.tasks.dismiss(rig.state.tasks.single.id);
      await rig.settle();
      expect(rig.state.tasks, isEmpty);
      await rig.finish();
    });

    testWidgets('cancel marks the rendition cancelled and plays the clip forward in one entry', (tester) async {
      final rig = await TasksRig.pump(tester);
      rig.tasks.reverse(TaskIds.video);
      await rig.settle();
      final job = rig.job('reverse');
      rig.tasks.cancel(job.id);
      await rig.settle();
      expect(job.cancelled, isTrue);
      expect(rig.state.tasks, isEmpty);
      expect(rig.clip(TaskIds.video).reversed, isFalse);
      expect(rig.entries, 2);
      expect(rig.state.history.undoLabel, 'Cancel reverse');
      expect(rig.project.pool.assets.values.where((a) => a.derived is ReversedSpec).single.status, const FailedStatus('cancelled'));
      expect(rig.tasks.exportBlocked, isFalse);
      await rig.finish();
    });
  });

  group('freeze frame', () {
    testWidgets('adds a pending project-owned still, inserts it at the playhead and starts the still job', (tester) async {
      final rig = await TasksRig.pump(tester);
      final result = rig.tasks.freeze(TaskIds.video, 4 * s, 3 * s);
      await rig.settle();
      expect(result, isA<EditApplied>());
      expect(rig.entries, 1);
      final main = rig.project.tracks.first.items;
      final still = main.whereType<MediaClip>().firstWhere((c) => rig.project.pool[c.media]!.kind == MediaKind.still);
      expect(still.start, 4 * s);
      expect(still.duration, 3 * s);
      final asset = rig.asset(still.media);
      final job = rig.job('freezeFrame');
      expect(asset.status, PendingStatus(job.id));
      expect(asset.ownership, MediaOwnership.projectOwned);
      expect((asset.locator as AppRelativeLocator).relPath, 'danaview/editor/projects/${rig.id.value}/assets/stills/${asset.id.value}.png');
      final spec = asset.derived! as StillSpec;
      expect(spec.media, TaskIds.videoMedia);
      expect(spec.sourceTime, 9 * s, reason: 'source in 5 s + 4 s');
      expect(rig.state.tasks.single.kind, EditorTaskKind.freeze);
      expect(rig.tasks.exportBlocked, isTrue);
      await rig.complete(job, bytes: 2048);
      expect(rig.asset(still.media).status, AssetStatus.ready);
      expect(rig.asset(still.media).fingerprint.sizeBytes, 2048);
      expect(rig.state.tasks, isEmpty);
      expect(rig.tasks.exportBlocked, isFalse);
      await rig.finish();
    });

    testWidgets('cancel removes the still with ripple in one entry', (tester) async {
      final rig = await TasksRig.pump(tester);
      rig.tasks.freeze(TaskIds.video, 4 * s, 3 * s);
      await rig.settle();
      final job = rig.job('freezeFrame');
      rig.tasks.cancel(job.id);
      await rig.settle();
      expect(rig.state.tasks, isEmpty);
      expect(rig.project.tracks.first.items.whereType<MediaClip>().where((c) => rig.project.pool[c.media]!.kind == MediaKind.still), isEmpty);
      expect(rig.project.duration, 16 * s, reason: 'ripple closed the gap');
      expect(rig.state.history.undoLabel, 'Cancel freeze frame');
      await rig.finish();
    });

    testWidgets('failure leaves a failed still and a retryable row', (tester) async {
      final rig = await TasksRig.pump(tester);
      rig.tasks.freeze(TaskIds.video, 4 * s, 3 * s);
      await rig.settle();
      rig.job('freezeFrame').fail(EngineFailure.of(EngineErrorCode.decodeFailed));
      await rig.settle();
      expect(rig.state.tasks.single.failed, isTrue);
      rig.tasks.retry(rig.state.tasks.single.id);
      await rig.settle();
      expect(rig.jobs.created.where((j) => j.id.startsWith('freezeFrame-')), hasLength(2));
      await rig.finish();
    });

    testWidgets('a refused freeze (playhead outside the clip) leaves the still unused and starts nothing', (tester) async {
      final rig = await TasksRig.pump(tester);
      final result = rig.tasks.freeze(TaskIds.video, 13 * s, 3 * s);
      await rig.settle();
      expect(result, isA<EditRejected>());
      expect(rig.jobs.created, isEmpty);
      expect(rig.state.tasks, isEmpty);
      await rig.finish();
    });
  });

  group('proxies and other producers', () {
    testWidgets('requestProxy follows the asset proxy state', (tester) async {
      final rig = await TasksRig.pump(tester);
      expect(rig.tasks.requestProxy(TaskIds.videoMedia), isTrue);
      await rig.settle();
      expect(rig.asset(TaskIds.videoMedia).proxy, ProxyState.pending);
      final job = rig.job('proxy');
      expect(job.priority, JobPriority.background);
      expect(rig.state.tasks.single.kind, EditorTaskKind.proxy);
      expect(rig.tasks.requestProxy(TaskIds.videoMedia), isFalse, reason: 'already running');
      await rig.complete(job);
      expect(rig.asset(TaskIds.videoMedia).proxy, ProxyState.ready);
      expect(rig.state.tasks, isEmpty);
      expect(rig.tasks.exportBlocked, isFalse, reason: 'proxies never gate export');
      await rig.finish();
    });

    testWidgets('track shows a job until it ends, Cancel cancels it', (tester) async {
      final rig = await TasksRig.pump(tester);
      final a = FakeMediaJob<int>('wave-a');
      final b = FakeMediaJob<int>('wave-b');
      rig.tasks.track(EditorTaskKind.waveform, a);
      rig.tasks.track(EditorTaskKind.waveform, b);
      await rig.settle();
      expect(rig.state.tasks.map((t) => t.id), ['wave-a', 'wave-b']);
      a.report(0.5);
      await rig.settle();
      expect(rig.state.tasks.first.progress, 0.5);
      a.complete(1);
      await rig.settle();
      rig.tasks.cancel('wave-b');
      await rig.settle();
      expect(b.cancelled, isTrue);
      expect(rig.state.tasks, isEmpty);
      await rig.finish();
    });

    testWidgets('begin: a driven captions task with progress, failure and retry', (tester) async {
      final rig = await TasksRig.pump(tester);
      var retried = 0;
      final h = rig.tasks.begin(EditorTaskKind.captions, onRetry: () => retried++);
      h.progress(0.2);
      await rig.settle();
      expect(rig.state.tasks.single, EditorTaskInfo(id: h.id, kind: EditorTaskKind.captions, label: 'Making captions', progress: 0.2));
      h.fail();
      await rig.settle();
      expect(rig.state.tasks.single.failed, isTrue);
      rig.tasks.retry(h.id);
      expect(retried, 1);
      final d = rig.tasks.begin(EditorTaskKind.download);
      d.complete();
      await rig.settle();
      expect(rig.state.tasks, isEmpty);
      await rig.finish();
    });
  });

  group('export gating', () {
    testWidgets('exportBlockersOf counts clips waiting for pending stills and renditions', (tester) async {
      final pendingStill = rigAsset('md_still', MediaKind.still,
          status: const PendingStatus('gone'),
          derived: StillSpec(TaskIds.videoMedia, s, sourceQuickHash: 'md_video'.padRight(40, '0')));
      final rig = await TasksRig.pump(tester, extraAssets: [pendingStill], readTasks: false);
      expect(TasksController.exportBlockersOf(rig.project), isEmpty, reason: 'the still is not used');
      final withStill = rig.project.copyWith(
        timeline: rig.project.timeline.copyWith(tracks: [
          for (final t in rig.project.tracks)
            t.isMain ? t.copyWith(items: [...t.items, rigClip('it_still', 'md_still', 16 * s, 2 * s)]) : t,
        ]),
      );
      expect(TasksController.exportBlockersOf(withStill), {const ItemId('it_still')});
      await rig.finish();
    });
  });

  group('lifecycle', () {
    testWidgets('closing the editor cancels running jobs quietly; the asset stays pending', (tester) async {
      final rig = await TasksRig.pump(tester);
      rig.tasks.reverse(TaskIds.video);
      await rig.settle();
      final job = rig.job('reverse');
      final id = renditionOf(rig, TaskIds.video)!.id;
      await rig.real(() async {
        await rig.editor.close();
      });
      expect(job.cancelled, isTrue);
      final saved = rig.harness.repository.projects[rig.id];
      if (saved != null) expect(saved.pool[id]!.status, isA<PendingStatus>());
      await rig.finish();
    });

    testWidgets('on open, pending assets the timeline needs are resumed with new jobs', (tester) async {
      final spec = ReversedSpec(TaskIds.videoMedia, const TimeRange(3 * s, 19 * s), sourceQuickHash: 'md_video'.padRight(40, '0'));
      final rendition = rigAsset('md_rev', MediaKind.video, status: const PendingStatus('stale-job'), derived: spec);
      final unused = rigAsset('md_rev2', MediaKind.video,
          status: const PendingStatus('stale-job-2'),
          derived: ReversedSpec(TaskIds.videoMedia, const TimeRange(40 * s, 50 * s), sourceQuickHash: 'md_video'.padRight(40, '0')));
      final rig = await TasksRig.pump(
        tester,
        video: rigClip('it_video', 'md_video', 0, 12 * s, sourceIn: 5 * s, reversed: true),
        extraAssets: [rendition, unused],
      );
      await rig.settle();
      final jobs = rig.jobs.created.where((j) => j.id.startsWith('reverse-')).toList();
      expect(jobs, hasLength(1), reason: 'only the rendition the reversed clip needs');
      expect(rig.asset(const MediaId('md_rev')).status, PendingStatus(jobs.single.id));
      expect(rig.asset(const MediaId('md_rev2')).status, const PendingStatus('stale-job-2'));
      expect(unstartedJobId, isEmpty);
      await rig.finish();
    });
  });
}
