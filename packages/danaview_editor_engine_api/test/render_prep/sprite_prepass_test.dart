// OWNER: API-04
//
// SpritePrepass (ARCH §10.3, §14.1 step 4): files and manifest, content-addressed reuse, UI
// slices ≤ 4 ms, progress, cancellation, the hand-off to CORE-33 `compileExport`, and the V-D7
// host benchmark (1,000 cues; the device measurement is QA-04's). The wall-clock host limits are
// 4× looser without DV_PERF_STRICT=1.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'support.dart';

/// DV_PERF_STRICT=1 (a quiet dev Mac) asserts the absolute budget; otherwise (a loaded CI runner)
/// [_looseFactor] times it.
final bool _perfStrict = Platform.environment['DV_PERF_STRICT'] == '1';
const int _looseFactor = 4;
String get _perfMode => _perfStrict ? 'DV_PERF_STRICT=1' : 'loose ×$_looseFactor, no DV_PERF_STRICT';

final DateTime _when = DateTime.utc(2026, 10, 10);

/// A project with a video clip, a typewriter title and a burned subtitle track of [cues] cues.
EditProject exportProject({int cues = 3}) {
  final rate = FrameRate.fps30;
  TimeUs f(int k) => rate.timeOfFrame(k);
  final asset = MediaAsset(
    id: const MediaId('md_v'),
    kind: MediaKind.video,
    displayName: 'v',
    locator: AppRelativeLocator(AppRoot.documents, 'v.mp4'),
    ownership: MediaOwnership.managedCopy,
    fingerprint: const MediaFingerprint(sizeBytes: 1, quickHash: 'qh_v'),
    probe: MediaProbe(kind: MediaKind.video, duration: 7200 * microsPerSecond, hasVideo: true, width: 1920, height: 1080),
    origin: MediaOrigin.files,
    addedAt: _when,
  );
  final cueLen = math.max(1, 3600 * 30 ~/ math.max(cues, 1)) ;
  return EditProject(
    id: const ProjectId('pr_prepass'),
    meta: ProjectMeta(name: 'prepass', createdAt: _when, updatedAt: _when),
    timeline: Timeline(settings: const ProjectSettings(), revision: 1, tracks: [
      Track(id: const TrackId('tr_main'), kind: TrackKind.video, isMain: true, items: [
        MediaClip(id: const ItemId('it_v'), start: 0, duration: f(3600 * 30), media: const MediaId('md_v'), visual: VisualProps.neutral),
      ]),
      Track(id: const TrackId('tr_text'), kind: TrackKind.text, items: [
        TextItem(
          id: const ItemId('it_title'),
          start: 0,
          duration: f(90),
          text: 'Typed title',
          animation: TextAnimation(inKind: TextAnimKind.typewriter, inDuration: f(30)),
        ),
      ]),
      Track(
        id: const TrackId('tr_sub'),
        kind: TrackKind.subtitle,
        subtitle: const SubtitleTrackData(),
        items: [
          for (var i = 0; i < cues; i++)
            SubtitleCue(id: ItemId('it_cue$i'), start: f(i * cueLen), duration: f((i + 1) * cueLen) - f(i * cueLen), text: 'Cue number $i, <i>spoken</i> words'),
        ],
      ),
    ]),
    pool: MediaPool({asset.id: asset}),
  );
}

PlanAssetResolver resolverOf(EditProject p) =>
    MapPlanAssetResolver(originals: {const MediaId('md_v'): const ResolvedMedia(uri: 'file:///media/v.mp4', fingerprint: 'qh_v')});

void main() {
  late Directory tmp;
  setUpAll(loadFigtree);
  setUp(() => tmp = Directory.systemTemp.createTempSync('danaview_sprites_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('writes <key>.vsprite files and returns the manifest of every request', () async {
    final pass = SpritePrepass();
    final reqs = [
      request(spec('One'), id: 'a'),
      request(spec('Two', fontSizePx: 40), scale: 2, reveal: true, id: 'b'),
      request(spec('One'), id: 'a2'), // same key as the first
    ];
    expect(reqs[0].key, reqs[2].key);
    final m = await pass.run(reqs, cacheDir: tmp.path);
    expect(m.files.keys.toSet(), {reqs[0].key, reqs[1].key});
    expect(pass.stats.unique, 2);
    expect(pass.stats.rasterized, 2);
    for (final r in reqs) {
      final f = m[r.key]!;
      final path = SpritePrepass.pathOf(tmp.path, r.key);
      expect(f.uri, File(path).uri.toString());
      final img = VspriteCodec.decodeSync(File(path).readAsBytesSync());
      expect((img.width, img.height, img.scale, img.hasReveal), (f.sw, f.sh, f.sscale, f.reveal));
      expect(f.reveal, r.reveal);
    }
    expect(m[reqs[1].key]!.sscale, 2);
    expect(tmp.listSync().whereType<File>().where((f) => f.path.contains('.tmp')), isEmpty, reason: 'atomic writes');
    expect(SpritePrepass.spritesDirOf('/c/danaview/editor'), '/c/danaview/editor/sprites');
  });

  test('content-addressed reuse: a second run rasterizes nothing; corrupt or map-less files are redone', () async {
    final pass = SpritePrepass();
    final plain = request(spec('Reuse me'), id: 'p');
    final rev = request(spec('Typed'), reveal: true, id: 't');
    final first = await pass.run([plain, rev], cacheDir: tmp.path);
    final again = await pass.run([plain, rev], cacheDir: tmp.path);
    expect(pass.stats.reused, 2);
    expect(pass.stats.rasterized, 0);
    expect(again.files, first.files);
    // Corrupt one file: rasterized again.
    File(SpritePrepass.pathOf(tmp.path, plain.key)).writeAsBytesSync([1, 2, 3]);
    await pass.run([plain, rev], cacheDir: tmp.path);
    expect((pass.stats.reused, pass.stats.rasterized), (1, 1));
    // A file without a glyph map does not satisfy a reveal request.
    final img = VspriteCodec.decodeSync(File(SpritePrepass.pathOf(tmp.path, rev.key)).readAsBytesSync());
    File(SpritePrepass.pathOf(tmp.path, rev.key))
        .writeAsBytesSync(VspriteCodec.encodeSync(VspriteImage(width: img.width, height: img.height, scale: img.scale, rgba: img.rgba)));
    expect(await pass.cachedFile(tmp.path, rev.key, needReveal: true), isNull);
    final m = await pass.run([rev], cacheDir: tmp.path);
    expect(m[rev.key]!.reveal, isTrue);
    expect(pass.stats.rasterized, 1);
  });

  test('slicing: a slice stops before the next sprite would exceed 4 ms (deterministic clock)', () async {
    var now = 0;
    // Sprite i costs 300..1500 µs on the UI isolate (a repeating pattern).
    final costs = [300, 900, 1500, 600, 1200, 400, 1500, 800];
    final pass = SpritePrepass(
      rasterizer: _TimedRasterizer(onPrepare: (i) => now += costs[i % costs.length]),
      clockMicros: () => now,
      maxBatch: 64,
    );
    final reqs = [for (var i = 0; i < 80; i++) request(spec('Timed $i', fontSizePx: 30), id: 't$i')];
    final m = await pass.run(reqs, cacheDir: tmp.path);
    expect(m.files, hasLength(80));
    final slices = pass.stats.sliceMicros;
    expect(slices.reduce((a, b) => a + b), costs.fold<int>(0, (a, b) => a + b) * 10);
    expect(slices.every((us) => us <= 4000), isTrue, reason: 'per-slice UI time <= 4 ms: $slices');
    expect(slices.length, lessThan(80), reason: 'several sprites share a slice');
  });

  test('UI slices on the host stay around the 4 ms budget; progress rises monotonically to 1', () async {
    final pass = SpritePrepass();
    // Warm up fonts and the paragraph pipeline (first-use costs are not per-slice work).
    await pass.run([request(spec('warm up'))], cacheDir: tmp.path);
    final reqs = [
      for (var i = 0; i < 120; i++)
        request(
            spec('Subtitle line $i with a few words', fontSizePx: 48, box: const TextBoxSpec(color: 0xFF000000, opacity: 0.5, paddingPx: 8, cornerRadiusPx: 4)),
            id: 'c$i'),
    ];
    final progress = <double>[];
    await pass.run(reqs, cacheDir: tmp.path, onProgress: progress.add);
    expect(progress.first, 0);
    expect(progress.last, 1);
    for (var i = 1; i < progress.length; i++) {
      expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
    }
    final slices = List.of(pass.stats.sliceMicros)..sort();
    final median = slices[slices.length ~/ 2];
    // ignore: avoid_print
    print('sprite pre-pass UI slices (debug JIT, shared host): n=${slices.length} median=$median µs max=${slices.last} µs');
    // Wall-clock slices on a loaded debug host include preemption; the rule itself is tested
    // deterministically above, and QA-04 measures release builds on devices.
    expect(median, lessThanOrEqualTo(_perfStrict ? 4000 : 4000 * _looseFactor), reason: 'median slice $median µs ($_perfMode)');
  });

  test('cancel between slices throws SpritePrepassCancelled; written files stay valid', () async {
    final pass = SpritePrepass(maxBatch: 2);
    var calls = 0;
    final reqs = [for (var i = 0; i < 10; i++) request(spec('Cancel $i'), id: 'x$i')];
    await expectLater(pass.run(reqs, cacheDir: tmp.path, isCancelled: () => ++calls > 2), throwsA(isA<SpritePrepassCancelled>()));
    final files = tmp.listSync().whereType<File>().toList();
    expect(files.where((f) => f.path.contains('.tmp')), isEmpty, reason: 'no write in flight after run() returns');
    expect(files.length, lessThan(10));
    for (final f in files) {
      expect(() => VspriteCodec.decodeSync(f.readAsBytesSync()), returnsNormally);
    }
  });

  test('hand-off to compileExport: sprite assets, base and the typewriter reveal channel', () async {
    final project = exportProject();
    final settings = ExportSettings();
    final engine = TextLayoutEngine();
    final requests = exportSpriteRequests(project, settings, metrics: engine);
    expect(requests, hasLength(4));
    expect(requests.where((r) => r.reveal), hasLength(1));
    // Without sprites the export is blocked.
    final blocked = compileExport(project, settings, SpriteManifest.empty, resolver: resolverOf(project), spriteRequests: requests);
    expect(blocked, isA<ExportBlocked>());
    expect((blocked as ExportBlocked).missingSprites.toSet(), {for (final r in requests) r.key});

    final manifest = await SpritePrepass(rasterizer: TextSpriteRasterizer(engine: engine)).run(requests, cacheDir: tmp.path);
    final ready = compileExport(project, settings, manifest, resolver: resolverOf(project), spriteRequests: requests);
    expect(ready, isA<ExportReady>());
    final plan = (ready as ExportReady).plan;
    expect(PlanValidator.validate(plan), isEmpty);
    final title = plan.layers.singleWhere((l) => l.id == 'it_title#v');
    final asset = plan.assets[title.asset]!;
    final file = manifest[requests.firstWhere((r) => r.reveal).key]!;
    expect(asset.uri, file.uri);
    expect(asset.reveal, isTrue);
    expect(title.anim[PlanChannels.reveal], isNotEmpty);
    expect(title.anim[PlanChannels.reveal]!.last.v, 'Typed title'.length.toDouble());
    // Plan sscale = file sscale / exportScale (1 for a 1080p export of a 1080p project);
    // base = sprite size / plan sscale = the layout's raster extent, rounded up to whole sprite px.
    final exportScale = exportScaleOf(project.settings.canvas, const Size2(1920, 1080));
    expect(exportScale, 1);
    expect(asset.sscale, closeTo(file.sscale / exportScale, 1e-9));
    expect(title.base!.w, closeTo(file.sw / asset.sscale!, 1e-6));
    expect(title.base!.h, closeTo(file.sh / asset.sscale!, 1e-6));
    final layout = engine.layoutSpec(textLayoutSpecFromJson(requests.firstWhere((r) => r.reveal).layoutSpec));
    expect(title.base!.w, inInclusiveRange(layout.rasterSize.width, layout.rasterSize.width + 1 / file.sscale));
  });

  test('V-D7 host benchmark: 1,000 cues prepared <= 8 s', () async {
    final project = exportProject(cues: 1000);
    final engine = TextLayoutEngine();
    final requests = exportSpriteRequests(project, ExportSettings(), metrics: engine);
    expect(requests.length, 1001);
    final pass = SpritePrepass(rasterizer: TextSpriteRasterizer(engine: engine));
    final watch = Stopwatch()..start();
    final m = await pass.run(requests, cacheDir: tmp.path);
    watch.stop();
    // ignore: avoid_print
    print('V-D7 host: ${requests.length} sprites in ${watch.elapsedMilliseconds} ms, '
        'max UI slice ${pass.stats.maxSliceMicros} µs, ${pass.stats.sliceMicros.length} slices');
    expect(m.files, hasLength(1001));
    expect(watch.elapsed, lessThanOrEqualTo(const Duration(seconds: 8) * (_perfStrict ? 1 : _looseFactor)),
        reason: '${watch.elapsedMilliseconds} ms ($_perfMode)');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// A rasterizer that reports each prepare to [onPrepare] (which advances a fake clock).
final class _TimedRasterizer extends TextSpriteRasterizer {
  _TimedRasterizer({required this.onPrepare});
  final void Function(int index) onPrepare;
  int _n = 0;

  @override
  PreparedSprite prepare(SpriteRequest request, {int maxTextureSize = defaultMaxTextureSize}) {
    final p = super.prepare(request, maxTextureSize: maxTextureSize);
    onPrepare(_n++);
    return p;
  }
}
