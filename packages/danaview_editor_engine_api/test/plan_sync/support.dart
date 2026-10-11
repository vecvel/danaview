// OWNER: API-02
//
// Builders for the PlanSync tests: a one-lane project of [n] clips over one video asset, a
// resolver for it, a manual clock for transient coalescing and a controllable compile.

import 'dart:async';

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

final DateTime when = DateTime.utc(2026, 10, 10);

const MediaId mediaId = MediaId('md_v');

MediaAsset videoAsset() => MediaAsset(
      id: mediaId,
      kind: MediaKind.video,
      displayName: 'v',
      locator: AppRelativeLocator(AppRoot.documents, 'v.mp4'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: const MediaFingerprint(sizeBytes: 1000, quickHash: 'qh_v'),
      probe: MediaProbe(
          kind: MediaKind.video, duration: 600 * microsPerSecond, hasVideo: true, hasAudio: true, width: 1920, height: 1080),
      origin: MediaOrigin.files,
      addedAt: when,
    );

/// Clip id of index [i].
ItemId clipId(int i) => ItemId('it_c$i');

/// A main lane of [n] back-to-back one-second clips.
EditProject project({int n = 3, int revision = 1}) {
  final rate = FrameRate.fps30;
  return EditProject(
    id: const ProjectId('pr_sync'),
    meta: ProjectMeta(name: 'sync', createdAt: when, updatedAt: when),
    timeline: Timeline(
      settings: const ProjectSettings(),
      revision: revision,
      tracks: [
        Track(id: const TrackId('tr_main'), kind: TrackKind.video, isMain: true, items: [
          for (var i = 0; i < n; i++)
            MediaClip(
              id: clipId(i),
              start: rate.timeOfFrame(30 * i),
              duration: rate.timeOfFrame(30 * (i + 1)) - rate.timeOfFrame(30 * i),
              media: mediaId,
              sourceIn: rate.timeOfFrame(30 * i),
              visual: VisualProps.neutral,
            ),
        ]),
      ],
    ),
    pool: MediaPool({mediaId: videoAsset()}),
  );
}

PlanAssetResolver resolverOf(EditProject p) => MapPlanAssetResolver(originals: {
      for (final a in p.pool.assets.values) a.id: ResolvedMedia(uri: 'file:///media/${a.id}', fingerprint: 'qh_${a.id}'),
    });

/// [p] with the opacity of clip [i] set to [opacity] (a param-only change) and a new [revision].
EditProject withOpacity(EditProject p, int i, double opacity, {required int revision}) {
  final out = applyCommand(
    p,
    SetVisual([clipId(i)], VisualProps(transform: Transform2D(opacity: opacity))),
    EditContext(ids: SeededIdGenerator(1), now: when),
  );
  return out.project.copyWith(timeline: out.project.timeline.copyWith(revision: revision));
}

/// A memoized compile counting its calls.
final class CountingCompiler {
  final PlanMemo memo = PlanMemo();
  int calls = 0;

  Future<RenderPlan> call(EditProject p) async {
    calls++;
    return memo.compile(p, PlanTarget.preview, resolverOf(p)).plan;
  }
}

/// A compile whose results the test releases one at a time.
final class GatedCompiler {
  final PlanMemo memo = PlanMemo();
  final List<(EditProject, Completer<RenderPlan>)> inFlight = [];
  int calls = 0;

  Future<RenderPlan> call(EditProject p) {
    calls++;
    final c = Completer<RenderPlan>();
    inFlight.add((p, c));
    return c.future;
  }

  /// Completes the oldest compile.
  void release() {
    final (p, c) = inFlight.removeAt(0);
    c.complete(memo.compile(p, PlanTarget.preview, resolverOf(p)).plan);
  }
}

/// A manual clock: time moves only through [advance], which fires due timers in order.
final class ManualClock implements PlanSyncClock {
  Duration _now = Duration.zero;
  final List<_ManualTimer> _timers = [];

  @override
  Duration now() => _now;

  @override
  Timer timer(Duration delay, void Function() callback) {
    final t = _ManualTimer(_now + delay, callback);
    _timers.add(t);
    return t;
  }

  void advance(Duration d) {
    final end = _now + d;
    while (true) {
      final due = _timers.where((t) => t._active && t.at <= end).toList()..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final t = due.first;
      _now = t.at;
      t.fire();
    }
    _now = end;
    _timers.removeWhere((t) => !t._active);
  }
}

final class _ManualTimer implements Timer {
  _ManualTimer(this.at, this._callback);
  final Duration at;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// Opens a fake preview session.
Future<(FakeEditorEngine, FakePreviewSession)> openFake() async {
  final engine = FakeEditorEngine();
  final s = await engine.openPreview(const PreviewConfig(canvasWidth: 1920, canvasHeight: 1080, fps: 30));
  return (engine, s as FakePreviewSession);
}

/// A transient moving clip [i] to opacity [o] (param fields only).
PlanTransient transientOf(EditProject p, int i, double o) =>
    transientFor(withOpacity(p, i, o, revision: p.revision), clipId(i), resolverOf(p))!;
