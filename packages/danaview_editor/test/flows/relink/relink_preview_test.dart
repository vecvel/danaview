// OWNER: FIX-UX-40-1
//
// QA-01 s10: after "Relink several" applies, every asset is relinked and the banner goes, but the
// preview kept showing the offline placeholders until the project was reopened. The relink commit
// compiled the plan against the availability report from before the relink (the real monitor only
// re-checks after the commit), and the re-check's report did not compile the plan again. These
// tests run INT-02's DefaultPlanCompiler over a pool fake whose availability lookup lags the
// re-check exactly like CORE-28's `AvailabilityMonitor.last`, and prove the relinked media reaches
// the next plan the fake engine's preview holds.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/flows/relink/relink_controller.dart';
import 'package:danaview_editor/src/editor/state/default_plan_compiler.dart';
import 'package:danaview_editor/src/editor/state/media_health_controller.dart';
import 'package:danaview_editor/src/editor/state/plan_compiler_port.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show EditOutcome, EditSession;
import 'package:danaview_editor_core/plan.dart' show PlanLayerKind, RenderPlan;
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show MediaPickSource;
import 'package:danaview_editor_engine_api/testing.dart';

import 'relink_support.dart';

const _roots = StoreRoots(support: '/fake/support', cache: '/fake/cache', documents: '/fake/documents');

/// A pool whose availability behaves like CORE-28's monitor: [truth] is what a check would find
/// (the relink updates it), [last] is the latest report a check produced (what INT-02's compiler
/// reads), and it only moves when a watcher subscribes (MediaHealthController.refresh) or the test
/// emits.
class _MonitorPool extends ScriptedRelinkPool {
  Map<MediaId, MediaAvailability> truth = {};
  MediaAvailabilityReport? last;

  @override
  Stream<MediaAvailabilityReport> watchAvailability(EditSession session) async* {
    calls.add('watchAvailability');
    // A check runs on listen (after a microtask, like the real checker).
    await Future<void>.delayed(Duration.zero);
    availability = Map.of(truth);
    final r = MediaAvailabilityReport(Map.of(truth));
    last = r;
    yield r;
  }

  @override
  Future<EditOutcome> relink(EditSession session, Map<MediaId, PickedMedia> picks) async {
    final out = await super.relink(session, picks);
    if (out.rejection == null) {
      // The files are back; the next check will say so.
      for (final id in picks.keys) {
        truth[id] = MediaAvailability.available;
      }
    }
    return out;
  }
}

PickedMedia _pick(String name) => PickedMedia(uri: 'file:///picked/$name', displayName: name, origin: MediaOrigin.files);

void main() {
  late RelinkRig rig;
  late _MonitorPool pool;
  late FakeMediaAccess access;

  List<MediaAsset> three() => [videoAsset('md_1', name: 'a.mov'), videoAsset('md_2', name: 'b.mov'), videoAsset('md_3', name: 'c.mov')];

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  FakePreviewSession preview() => rig.harness.engine.sessions.last;
  RenderPlan plan() => preview().plan!;
  RelinkController relink() => rig.container.read(relinkControllerProvider(rig.id).notifier);
  Set<String> mediaUris(RenderPlan p) => {
        for (final l in p.layers)
          if (l.kind == PlanLayerKind.media && l.asset != null) p.assets[l.asset]!.uri,
      };

  Future<void> start(List<MediaAsset> assets) async {
    pool = _MonitorPool();
    pool.truth = {for (final a in assets) a.id: MediaAvailability.missing};
    access = FakeMediaAccess(editorRoots: const ['/fake/support/danaview/editor']);
    // The original copies are gone.
    for (final a in assets) {
      final l = a.locator as AppRelativeLocator;
      access.missing.add('file:///fake/${l.root.name}/${l.relPath}');
    }
    rig = RelinkRig(
      assets,
      pool: pool,
      overrides: [
        planCompilerPortProvider.overrideWithValue(
          DefaultPlanCompiler(access: access, roots: _roots, availability: (_) => pool.last, exists: (_) async => false),
        ),
      ],
    );
    rig.useContainer(rig.harness.container());
    await rig.open();
    rig.container.listen(mediaHealthControllerProvider(rig.id), (_, __) {});
    rig.container.listen(relinkControllerProvider(rig.id), (_, __) {});
    await settle();
    await rig.editor.session.planSync!.flush();
  }

  test('before the relink every clip is offline in the preview plan', () async {
    await start(three());
    expect(rig.editor.state.media.missing, hasLength(3));
    expect(plan().req?.offline.toSet(), {'md_1', 'md_2', 'md_3'});
    expect(mediaUris(plan()), isEmpty);
  });

  test('Relink several: the relinked files reach the next plan without a reopen', () async {
    await start(three());
    final c = relink();
    // Locate one alone (From Files), then the other two in one "Relink several" pick.
    rig.harness.engine.picker.nextPicks = [_pick('a.mov')];
    await c.locate(const MediaId('md_1'), MediaPickSource.files);
    await settle();
    expect(rig.container.read(relinkControllerProvider(rig.id)).rowOf(const MediaId('md_1'))!.willRelink, isTrue);
    final picks = [_pick('b.mov'), _pick('c.mov')];
    rig.harness.engine.picker.nextPicks = picks;
    pool.onAutoMatch = (p) => [
          RelinkProposal(pick: p[0], media: const MediaId('md_2'), check: const RelinkMatch(exactFingerprint: true)),
          RelinkProposal(pick: p[1], media: const MediaId('md_3'), check: const RelinkMatch(exactFingerprint: true)),
        ];
    await c.relinkSeveral(MediaPickSource.files);
    expect(await c.confirmSeveral(), isTrue, reason: '"Relink 3 files"');
    expect(pool.lastRelink!.keys.map((k) => k.value).toSet(), {'md_1', 'md_2', 'md_3'});
    await settle();
    await rig.editor.session.planSync!.flush();
    await settle();

    expect(rig.editor.state.media.missing, isEmpty, reason: 'the banner goes');
    expect(plan().req?.offline ?? const <String>[], isEmpty, reason: 'nothing offline in the preview plan');
    expect(mediaUris(plan()), {'file:///restored/a.mov', 'file:///restored/b.mov', 'file:///restored/c.mov'});

    // The preview shows the relinked clip at clip start + 10 frames.
    final clip = rig.editor.state.project!.timeline.tracks.firstWhere((t) => t.isMain).items.first as MediaClip;
    final rate = rig.editor.state.project!.settings.frameRate;
    final ack = await preview().seek(clip.start + rate.timeOfFrame(10));
    final t = ack.displayedFrameTime;
    final shown = plan().layers.where((l) => l.kind == PlanLayerKind.media && l.t0 <= t && t < l.t1).toList();
    expect(shown, hasLength(1));
    expect(plan().assets[shown.single.asset]!.uri, 'file:///restored/a.mov');
  });
}
