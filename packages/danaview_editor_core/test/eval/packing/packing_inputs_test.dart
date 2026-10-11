// OWNER: CORE-36
//
// packingInputsOf (ARCH §13.5, §11.7): the inputs derived from the model equal the media layers
// of the hand-compiled contract plans (CORE-29 fixtures; CORE-30 re-checks against its compiler),
// the lowering rules (hidden lanes, images, pending stills, missing media, overlap transitions,
// BlurOfMain backdrops, z), and the incremental PackingInputCache.

import 'dart:io';

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

import '../../support/random_project.dart';

const FrameRate rate = FrameRate.fps30;
TimeUs f(int k) => rate.timeOfFrame(k);
final DateTime when = DateTime.utc(2026, 10, 9);

MediaAsset asset(String id, MediaKind kind, {TimeUs duration = 10000000, AssetStatus status = AssetStatus.ready, DerivedSpec? derived}) =>
    MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: id,
      locator: AppRelativeLocator(AppRoot.documents, id),
      ownership: MediaOwnership.managedCopy,
      fingerprint: const MediaFingerprint(sizeBytes: 1, quickHash: 'q'),
      probe: MediaProbe(kind: kind, duration: duration, hasVideo: true, width: 1920, height: 1080),
      origin: MediaOrigin.files,
      derived: derived,
      status: status,
      addedAt: when,
    );

MediaClip clip(String id, int k0, int k1, String media, {TimeUs sourceIn = 0}) => MediaClip(
      id: ItemId(id),
      start: f(k0),
      duration: f(k1) - f(k0),
      media: MediaId(media),
      sourceIn: sourceIn,
      visual: VisualProps.neutral,
    );

EditProject project(List<Track> tracks, {ProjectSettings settings = const ProjectSettings(), List<MediaAsset> assets = const []}) =>
    EditProject(
      id: const ProjectId('pr_pack'),
      meta: ProjectMeta(name: 'p', createdAt: when, updatedAt: when),
      timeline: Timeline(settings: settings, tracks: tracks),
      pool: MediaPool({for (final a in assets) a.id: a}),
    );

Track mainLane(List<TimelineItem> items, {List<Transition> transitions = const []}) =>
    Track(id: const TrackId('tr_main'), kind: TrackKind.video, isMain: true, items: items, transitions: transitions);

final MediaAsset clipA = asset('md_clipA0000001', MediaKind.video);
final MediaAsset clipB = asset('md_clipB0000001', MediaKind.video);

/// The model equivalents of the CORE-29 contract plans with media layers.
final Map<String, EditProject> compileFixtures = {
  'transition_cross_dissolve.json': project([
    mainLane([clip('it_left00000001', 0, 60, 'md_clipA0000001'), clip('it_right0000001', 60, 150, 'md_clipB0000001', sourceIn: 533334)],
        transitions: const [
          Transition(id: TransitionId('tx_cd'), left: ItemId('it_left00000001'), right: ItemId('it_right0000001'), kind: TransitionKind.crossDissolve, durationFrames: 12),
        ]),
  ], assets: [clipA, clipB]),
  'transition_dip_to_white.json': project([
    mainLane([clip('it_left00000001', 0, 60, 'md_clipA0000001'), clip('it_right0000001', 60, 150, 'md_clipB0000001', sourceIn: 333334)],
        transitions: const [
          Transition(id: TransitionId('tx_dw'), left: ItemId('it_left00000001'), right: ItemId('it_right0000001'), kind: TransitionKind.dipToWhite, durationFrames: 12),
        ]),
  ], assets: [clipA, clipB]),
  'backdrop_blur_portrait.json': project(
    [mainLane([clip('it_main0000001', 0, 90, 'md_clipA0000001')])],
    settings: const ProjectSettings(canvas: CanvasSpec(aspect: AspectRatio.portrait9x16), background: BlurOfMainBackground(0.6)),
    assets: [clipA],
  ),
  'overlay_pip_chroma_mask.json': project([
    mainLane([clip('it_main0000001', 0, 120, 'md_clipA0000001')]),
    Track(id: const TrackId('tr_pip'), kind: TrackKind.overlay, items: [clip('it_pip00000001', 15, 105, 'md_clipB0000001')]),
  ], assets: [clipA, clipB]),
  'hold_pending_still.json': project([
    mainLane([clip('it_before000001', 0, 30, 'md_clipA0000001'), clip('it_freeze000001', 30, 120, 'md_still0000001')]),
  ], assets: [
    clipA,
    asset('md_still0000001', MediaKind.still,
        duration: 0, status: const PendingStatus('job'), derived: const StillSpec(MediaId('md_clipA0000001'), 1000000, sourceQuickHash: 'q')),
  ]),
  'effects_every_static_key.json': project([
    mainLane([clip('it_fx0000000001', 0, 30, 'md_clipA0000001'), clip('it_hlg000000001', 30, 60, 'md_hlg000000001'), clip('it_pq0000000001', 60, 90, 'md_pq0000000001')]),
  ], assets: [clipA, asset('md_hlg000000001', MediaKind.video, duration: 5000000), asset('md_pq0000000001', MediaKind.video, duration: 5000000)]),
  'minimal_preview.json': project([mainLane([clip('it_clip00000001', 0, 90, 'md_clipA0000001')])], assets: [clipA]),
};

RenderPlan plan(String name) => PlanJson.decodePlanBytes(File('test/fixtures/render_plans/contract/$name').readAsBytesSync());

void main() {
  group('model-derived inputs equal the compiled media layers of the contract plans', () {
    for (final e in compileFixtures.entries) {
      test(e.key, () {
        final p = plan(e.key);
        final media = [for (final l in p.layers) if (l.kind == PlanLayerKind.media) PackInput(l.id, l.z, l.t0, l.t1)]
          ..sort(comparePackInputs);
        final inputs = packingInputsOf(e.value);
        expect(inputs, media);
        final packed = packVisualLayers(inputs);
        for (final l in p.layers.where((l) => l.kind == PlanLayerKind.media)) {
          expect(packed.seqOf(l.id), l.seq, reason: l.id);
        }
      });
    }

    test('every contract plan with media layers carries the seq the packing assigns', () {
      final dir = Directory('test/fixtures/render_plans/contract');
      var checked = 0;
      for (final file in dir.listSync().whereType<File>()) {
        final name = file.uri.pathSegments.last;
        if (!name.endsWith('.json') || name.contains('expected')) continue;
        final RenderPlan p;
        try {
          p = PlanJson.decodePlanBytes(file.readAsBytesSync());
        } on Object {
          continue; // patches and transients
        }
        final media = [for (final l in p.layers) if (l.kind == PlanLayerKind.media) l];
        if (media.isEmpty) continue;
        final packed = packVisualLayers([for (final l in media) PackInput(l.id, l.z, l.t0, l.t1)]);
        for (final l in media) {
          expect(packed.seqOf(l.id), l.seq, reason: '$name ${l.id}');
        }
        checked++;
      }
      expect(checked, greaterThanOrEqualTo(10));
    });
  });

  group('lowering rules', () {
    test('z per lane: band·10000 + (laneIndexInBand + 1)·10, hidden lanes keep their index', () {
      final p = project([
        mainLane([clip('it_a', 0, 30, 'md_clipA0000001')]),
        Track(id: const TrackId('tr_v2'), kind: TrackKind.video, hidden: true, items: [clip('it_h', 0, 30, 'md_clipA0000001')]),
        Track(id: const TrackId('tr_v3'), kind: TrackKind.video, items: [clip('it_b', 0, 30, 'md_clipA0000001')]),
        Track(id: const TrackId('tr_o1'), kind: TrackKind.overlay, items: [clip('it_c', 0, 30, 'md_clipA0000001')]),
        Track(id: const TrackId('tr_o2'), kind: TrackKind.overlay, items: [clip('it_d', 0, 30, 'md_clipA0000001')]),
      ], assets: [clipA]);
      expect([for (final i in packingInputsOf(p)) (i.id, i.z)], [
        ('it_a#v', 10),
        ('it_b#v', 30),
        ('it_c#v', 10010),
        ('it_d#v', 10020),
      ]);
      expect(laneZ(TrackKind.text, 0), 20010);
      expect(laneZ(TrackKind.subtitle, 0), 30010);
    });

    test('images, ready stills, missing media and audio-only lanes are not packed', () {
      final p = project([
        mainLane([
          clip('it_img', 0, 30, 'md_img'),
          clip('it_still', 30, 60, 'md_still'),
          clip('it_gone', 60, 90, 'md_gone'),
          clip('it_vid', 90, 120, 'md_clipA0000001'),
        ]),
        Track(id: const TrackId('tr_au'), kind: TrackKind.audio, items: [
          MediaClip(id: const ItemId('it_au'), start: 0, duration: f(30), media: const MediaId('md_clipA0000001')),
        ]),
      ], assets: [
        clipA,
        asset('md_img', MediaKind.image),
        asset('md_still', MediaKind.still, derived: const StillSpec(MediaId('md_clipA0000001'), 0, sourceQuickHash: 'q')),
      ]);
      expect(packingInputsOf(p).map((i) => i.id), ['it_vid#v']);
    });

    test('pending stills are hold layers only when the engine can hold frames', () {
      final p = compileFixtures['hold_pending_still.json']!;
      expect(packingInputsOf(p).map((i) => i.id), ['it_before000001#v', 'it_freeze000001#v']);
      expect(packingInputsOf(p, holdFrame: false).map((i) => i.id), ['it_before000001#v']);
    });

    test('overlap transitions extend both clips over the window; fades and dips do not', () {
      for (final kind in TransitionKind.values) {
        for (final n in [1, 2, 7, 12]) {
          final p = project([
            mainLane([clip('it_l', 0, 60, 'md_clipA0000001'), clip('it_r', 60, 150, 'md_clipB0000001', sourceIn: f(30))],
                transitions: [Transition(id: const TransitionId('tx'), left: const ItemId('it_l'), right: const ItemId('it_r'), kind: kind, durationFrames: n)]),
          ], assets: [clipA, clipB]);
          final inputs = {for (final i in packingInputsOf(p)) i.id: i};
          if (kind.needsHandles) {
            expect(inputs['it_l#v']!.t1, f(60 + (n + 1) ~/ 2), reason: '$kind $n');
            expect(inputs['it_r#v']!.t0, f(60 - n ~/ 2), reason: '$kind $n');
            expect(packVisualLayers(inputs.values.toList()).slotCount, 2);
          } else {
            expect(inputs['it_l#v']!.t1, f(60));
            expect(inputs['it_r#v']!.t0, f(60));
            expect(packVisualLayers(inputs.values.toList()).slotCount, 1);
          }
        }
      }
    });

    test('lane filter derives only the given lanes', () {
      final p = compileFixtures['overlay_pip_chroma_mask.json']!;
      expect(packingInputsOf(p, laneFilter: {const TrackId('tr_pip')}).map((i) => i.id), ['it_pip00000001#v']);
      expect(packingInputsOf(p, laneFilter: const {}), isEmpty);
    });
  });

  group('PackingInputCache', () {
    test('re-derives only changed lanes and always equals the full derivation', () {
      final cache = PackingInputCache();
      var p = randomProject(5, const RandomProjectSpec(items: 300));
      expect(cache.inputsOf(p), packingInputsOf(p));
      final visualLanes = p.tracks.where((t) => t.kind == TrackKind.video || t.kind == TrackKind.overlay).length;
      expect(cache.lastDerived, visualLanes);
      expect(cache.inputsOf(p), packingInputsOf(p));
      expect(cache.lastDerived, 0);
      // Change one visual lane: drop its last item.
      final ti = p.tracks.indexWhere((t) => t.kind.isVisual && t.kind != TrackKind.text && t.kind != TrackKind.subtitle && t.items.isNotEmpty);
      final t = p.tracks[ti];
      final tracks = List<Track>.of(p.tracks)..[ti] = t.copyWith(items: t.items.sublist(0, t.items.length - 1), transitions: const []);
      p = p.copyWith(timeline: p.timeline.copyWith(tracks: tracks));
      expect(cache.inputsOf(p), packingInputsOf(p));
      expect(cache.lastDerived, 1);
      expect(cache.pack(p), packVisualLayers(packingInputsOf(p)));
      // A background change touches the main lane only (backdrops).
      p = p.copyWith(timeline: p.timeline.copyWith(settings: p.settings.copyWith(background: const BlurOfMainBackground(0.4))));
      expect(cache.inputsOf(p), packingInputsOf(p));
      cache.clear();
      expect(cache.inputsOf(p), packingInputsOf(p));
    });

    test('model packing on random projects satisfies the rules', () {
      for (var seed = 0; seed < 100; seed++) {
        final p = randomProject(seed);
        final inputs = packingInputsOf(p);
        final r = packVisualLayers(inputs);
        for (var i = 0; i < inputs.length; i++) {
          for (var j = i + 1; j < inputs.length; j++) {
            final a = inputs[i], b = inputs[j];
            if (a.t0 < b.t1 && b.t0 < a.t1) expect(r.seqOf(a.id) < r.seqOf(b.id), comparePackInputs(a, b) < 0);
          }
        }
      }
    });
  });
}
