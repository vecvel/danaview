// OWNER: CORE-33
//
// compileExport (ARCH §14.1 step 3): original media only (never proxies), output canvas = output
// size and export fps with gridFps = the project rate, letterbox fit (never a silent crop), burn-in
// per settings, sprite layers from the manifest; ExportBlocked for offline media, pending
// reverses, pending stills, missing sprites and an empty timeline.

import 'package:test/test.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/plan.dart';

import '../compile_lowering/lowering_support.dart';

final MediaAsset vA = asset('md_videoA00001', MediaKind.video, duration: 20000000, proxy: ProxyState.ready);

EditProject titled({FrameRate rate = FrameRate.fps30, List<MediaAsset> extra = const [], List<TimelineItem>? main}) => project([
      mainLane(main ?? [clip('it_main0000001', 0, 90, 'md_videoA00001', rate: rate)]),
      lane('tr_text', TrackKind.text, [
        TextItem(
          id: const ItemId('it_title000001'),
          start: 0,
          duration: rate.timeOfFrame(30),
          text: 'Hello',
          animation: TextAnimation(inKind: TextAnimKind.typewriter, inDuration: rate.timeOfFrame(10)),
        ),
      ]),
      lane('tr_sub_a', TrackKind.subtitle, [SubtitleCue(id: const ItemId('it_cue00000001'), start: 0, duration: rate.timeOfFrame(30), text: 'A')],
          subtitle: const SubtitleTrackData()),
      lane('tr_sub_b', TrackKind.subtitle, [SubtitleCue(id: const ItemId('it_cue00000002'), start: 0, duration: rate.timeOfFrame(30), text: 'B')],
          subtitle: const SubtitleTrackData(burnIn: false)),
    ], assets: [vA, ...extra], settings: ProjectSettings(frameRate: rate));

(ExportCompileResult, List<SpriteRequest>) export(EditProject p, ExportSettings s,
    {ExportCapabilities caps = const ExportCapabilities(), Set<String> offline = const {}, bool manifest = true}) {
  final requests = exportSpriteRequests(p, s, capabilities: caps);
  final r = compileExport(p, s, manifest ? fakeManifest(requests) : SpriteManifest.empty,
      resolver: resolverFor(p, offline: offline, proxied: {'md_videoA00001'}), capabilities: caps, spriteRequests: requests);
  return (r, requests);
}

void main() {
  test('ready: originals only, output canvas, gridFps = project rate, sprites, audio', () {
    final p = titled(rate: FrameRate.fps48);
    final (r, requests) = export(p, ExportSettings(preset: ExportPresetId.custom, fps: 24, shortSide: 720));
    final ready = r as ExportReady;
    final plan = ready.plan;
    expect(plan.target, PlanTarget.export);
    expect((plan.canvas.w, plan.canvas.h, plan.canvas.fps, plan.canvas.gridFps), (1280, 720, 24, 48));
    expect(plan.assets.values.every((a) => a.proxyUri == null), isTrue, reason: 'never proxies');
    expect(PlanValidator.validate(plan), isEmpty);
    expect(plan.req, isNull);
    expect(ready.encode.fps, 24);
    expect(ready.sprites, requests);
    expect(plan.layers.map((l) => l.id), ['it_main0000001#v', 'it_title000001#v', 'it_cue00000001#c']);
    final title = plan.layers[1];
    expect(plan.assets[title.asset]!.reveal, isTrue);
    expect(title.anim[PlanChannels.reveal]!.last.v, 5);
    expect(plan.audio.single.id, 'it_main0000001#a');
    // 720p output of a 1080p project: everything scaled by 2/3 (letterbox fit with no bars).
    expect(plan.layers.first.base, const PlanSize(1280, 720));
  });

  test('burn-in follows the settings per track', () {
    final p = titled();
    final (r, _) = export(p, ExportSettings(burnInSubtitles: {const TrackId('tr_sub_a'): false, const TrackId('tr_sub_b'): true}));
    expect((r as ExportReady).plan.layers.map((l) => l.id), ['it_main0000001#v', 'it_title000001#v', 'it_cue00000002#c']);
  });

  test('aspect mismatch letterboxes the project inside the output (content clip on every layer)', () {
    final p = titled();
    final (r, _) = export(p, ExportSettings(preset: ExportPresetId.instagramReels));
    final ready = r as ExportReady;
    expect(ready.resolved.aspectMismatch, isTrue);
    expect((ready.plan.canvas.w, ready.plan.canvas.h), (1080, 1920));
    final main = ready.plan.layers.first;
    expect(main.base, const PlanSize(1080, 607.5), reason: 'fit, not crop');
    for (final l in ready.plan.layers) {
      expect(l.cmasks.last, const CanvasMask(cx: 540, cy: 960, w: 1080, h: 607.5), reason: l.id);
    }
    expect(PlanValidator.validate(ready.plan), isEmpty);
  });

  test('blocked: offline media', () {
    final (r, _) = export(titled(), ExportSettings(), offline: {'md_videoA00001'});
    final b = r as ExportBlocked;
    expect(b.requirements.offline, ['md_videoA00001']);
    expect(b.missingSprites, isEmpty);
    expect(b.emptyTimeline, isFalse);
  });

  test('blocked: pending reverse', () {
    final p = titled(main: [clip('it_rev00000001', 0, 30, 'md_videoA00001', reversed: true, sourceIn: 1000000)]);
    final b = export(p, ExportSettings()).$1 as ExportBlocked;
    expect(b.requirements.pendingReverse, ['it_rev00000001']);
  });

  test('blocked: pending freeze still', () {
    final still = asset('md_still000001', MediaKind.still,
        w: null, h: null, status: const PendingStatus('job'), derived: const StillSpec(MediaId('md_videoA00001'), 1000000, sourceQuickHash: 'qh_md_videoA00001'));
    final p = titled(main: [clip('it_still000001', 0, 30, 'md_still000001')], extra: [still]);
    final b = export(p, ExportSettings()).$1 as ExportBlocked;
    expect(b.requirements.pendingStill, ['md_still000001']);
  });

  test('blocked: missing sprites (no manifest entries), listed by key', () {
    final p = titled();
    final (r, requests) = export(p, ExportSettings(), manifest: false);
    final b = r as ExportBlocked;
    expect(b.missingSprites.toSet(), requests.map((q) => q.key).toSet());
    expect(b.missingSprites, hasLength(2));
    expect(b.requirements.isEmpty, isTrue);
  });

  test('blocked: a typewriter sprite rasterized without its glyph-order map', () {
    final p = titled();
    final requests = exportSpriteRequests(p, ExportSettings());
    final full = fakeManifest(requests);
    final broken = SpriteManifest({
      for (final e in full.files.entries)
        e.key: SpriteFile(uri: e.value.uri, sw: e.value.sw, sh: e.value.sh, sscale: e.value.sscale, reveal: false),
    });
    final b = compileExport(p, ExportSettings(), broken, resolver: resolverFor(p)) as ExportBlocked;
    expect(b.missingSprites, [requests.firstWhere((q) => q.reveal).key]);
  });

  test('blocked: empty timeline', () {
    final p = project([mainLane(const [])]);
    final b = compileExport(p, ExportSettings(), SpriteManifest.empty, resolver: resolverFor(p)) as ExportBlocked;
    expect(b.emptyTimeline, isTrue);
  });

  test('the default request list equals exportSpriteRequests (deterministic keys)', () {
    final p = titled();
    final requests = exportSpriteRequests(p, ExportSettings());
    final r = compileExport(p, ExportSettings(), fakeManifest(requests), resolver: resolverFor(p));
    expect(r, isA<ExportReady>());
  });
}
