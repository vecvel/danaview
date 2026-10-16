// OWNER: UX-14
//
// ENG-02 / API-02 / UX-14: an exact seek waits for a plan or patch in flight. The fake engine
// clamps seeks to the plan it holds (as the production engines do), so a seek sent right after a
// lengthening edit (paste, duplicate) would land on the old last frame; the playhead holds it until
// `PlanSync` has acknowledged the new plan.

import 'dart:async';

import 'package:danaview_editor/src/editor/state/playhead_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'transport_support.dart';

const FrameRate r30 = FrameRate.fps30;

TimeUs f(int k) => r30.timeOfFrame(k);

final DateTime when = DateTime.utc(2026, 10, 16);

MediaAsset _image(String id) => MediaAsset(
      id: MediaId(id),
      kind: MediaKind.image,
      displayName: 'photo $id',
      locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/media/$id/photo.png'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000, quickHash: id.padRight(40, '0')),
      probe: MediaProbe(kind: MediaKind.image, hasVideo: true, width: 1920, height: 1080),
      origin: MediaOrigin.files,
      addedAt: when,
    );

/// A main lane of [n] one-second photo clips (30 frames each), stamped [revision].
EditProject _project(int n, int revision) {
  const media = MediaId('md_photo');
  return EditProject(
    id: const ProjectId('pr_wait'),
    meta: ProjectMeta(name: 'wait', createdAt: when, updatedAt: when),
    timeline: Timeline(
      settings: const ProjectSettings(),
      revision: revision,
      tracks: [
        Track(id: const TrackId('tr_main'), kind: TrackKind.video, isMain: true, items: [
          for (var i = 0; i < n; i++)
            MediaClip(id: ItemId('it_c$i'), start: f(30 * i), duration: f(30 * (i + 1)) - f(30 * i), media: media, visual: VisualProps.neutral),
        ]),
      ],
    ),
    pool: MediaPool({media: _image('md_photo')}),
  );
}

RenderPlan _compile(EditProject p) => compilePlan(
      p,
      PlanTarget.preview,
      MapPlanAssetResolver(originals: {
        for (final a in p.pool.assets.values) a.id: ResolvedMedia(uri: 'file:///fake/${a.id}.png', fingerprint: 'fp-${a.id}'),
      }),
      options: CompileOptions(stages: standardLoweringStages()),
    ).plan;

class _Rig {
  late final FakeEditorEngine engine;
  late final FakePreviewSession preview;
  late final PlanSync sync;
  late final PlayheadController playhead;
  Completer<void>? gate;

  int get seeks => engine.calls.where((c) => c == 'preview.seek').length;

  /// A preview holding the 90-frame plan, a playhead attached with the plan sync.
  Future<void> open() async {
    engine = FakeEditorEngine(validatePlans: false);
    preview = await engine.openPreview(const PreviewConfig(canvasWidth: 1920, canvasHeight: 1080, fps: 30)) as FakePreviewSession;
    preview.clampSeeksToPlan = true;
    sync = PlanSync(preview, compile: (p) async {
      final g = gate;
      if (g != null) await g.future;
      return _compile(p);
    });
    sync.schedule(_project(3, 1));
    await sync.flush();
    playhead = PlayheadController(frameRate: r30, duration: f(90), ticker: ManualTicker(), clock: ManualClock().call);
    playhead.attach(preview, planSync: sync);
  }

  /// Commits the 150-frame project; its compile waits for [gate].
  void lengthen() {
    gate = Completer<void>();
    sync.schedule(_project(5, 2));
    playhead.setContent(duration: f(150));
  }

  Future<void> dispose() async {
    playhead.dispose();
    await sync.dispose();
  }
}

void main() {
  test('an exact seek after a lengthening edit waits for the patch and lands on target', () async {
    final rig = _Rig();
    await rig.open();
    rig.lengthen();
    expect(rig.sync.busy, isTrue);

    final ack = rig.playhead.seekExact(f(120));
    await Future<void>.delayed(Duration.zero);
    expect(rig.seeks, 0, reason: 'the seek is held while the plan is in flight');
    expect(rig.playhead.isWaitingForPlan, isTrue);
    expect(rig.playhead.isSeeking, isTrue);
    expect(rig.playhead.value, f(120), reason: 'the playhead moves at once');

    rig.gate!.complete();
    final a = await ack;
    expect(rig.seeks, 1);
    expect(rig.sync.lastAck!.rev, 2, reason: 'the seek went out after the patch was acked');
    expect(a!.displayedFrame, 120, reason: 'not clamped to the old 90-frame plan');
    expect(rig.playhead.value, f(120));
    expect(rig.playhead.isSeeking, isFalse);
    expect(rig.playhead.isWaitingForPlan, isFalse);
    await rig.dispose();
  });

  test('without the wait the engine would clamp (the fake models ENG-02)', () async {
    final rig = _Rig();
    await rig.open();
    rig.lengthen();
    final direct = await rig.preview.seek(f(120));
    expect(direct.displayedFrame, 89);
    rig.gate!.complete();
    await rig.sync.flush();
    await rig.dispose();
  });

  test('with nothing in flight an exact seek goes out at once', () async {
    final rig = _Rig();
    await rig.open();
    final ack = rig.playhead.seekExact(f(45));
    expect(rig.seeks, 1);
    expect(rig.playhead.isWaitingForPlan, isFalse);
    expect((await ack)!.displayedFrame, 45);
    await rig.dispose();
  });

  test('several seeks during one compile: one seek goes out, to the latest target', () async {
    final rig = _Rig();
    await rig.open();
    rig.lengthen();
    final a1 = rig.playhead.seekExact(f(100));
    final a2 = rig.playhead.seekExact(f(140));
    await Future<void>.delayed(Duration.zero);
    expect(rig.seeks, 0);
    rig.gate!.complete();
    final acks = await Future.wait([a1, a2]);
    expect(rig.seeks, 1);
    expect(acks.map((a) => a!.displayedFrame), [140, 140]);
    await rig.dispose();
  });

  test('scrub seeks do not wait for the plan', () async {
    final rig = _Rig();
    await rig.open();
    rig.lengthen();
    rig.playhead.scrubTo(f(60));
    expect(rig.seeks, 1);
    rig.gate!.complete();
    await rig.sync.flush();
    await rig.dispose();
  });

  test('a detach while the seek waits completes it with null and sends nothing', () async {
    final rig = _Rig();
    await rig.open();
    rig.lengthen();
    final ack = rig.playhead.seekExact(f(120));
    await Future<void>.delayed(Duration.zero);
    rig.playhead.detach();
    expect(await ack, isNull);
    rig.gate!.complete();
    await rig.sync.flush();
    await Future<void>.delayed(Duration.zero);
    expect(rig.seeks, 0);
    expect(rig.playhead.isWaitingForPlan, isFalse);
    await rig.dispose();
  });

  test('a failed compile does not hold the seek forever', () async {
    final rig = _Rig();
    await rig.open();
    rig.lengthen();
    final ack = rig.playhead.seekExact(f(60));
    await Future<void>.delayed(Duration.zero);
    expect(rig.seeks, 0);
    rig.gate!.completeError(StateError('compile failed'));
    final a = await ack.timeout(const Duration(seconds: 5));
    expect(rig.sync.currentStatus, PlanSyncStatus.failed);
    expect(rig.seeks, 1);
    expect(a!.displayedFrame, 60);
    await rig.dispose();
  });
}
