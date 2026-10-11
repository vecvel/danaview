// OWNER: UX-20
//
// Thumbnail strips on the timeline canvas with fake tiles (ux.md §8.6, §17.3): strips from the
// cache in the clips (a normal clip, a reversed one, a 2x one and a still), placeholder cells
// where a tile has not arrived, DPR 1 and 2. Ahem font. Tiles are painted gradients that encode
// the frame number, so a wrong frame mapping shows.
//
// Regenerate (after reviewing the change) with:
//   flutter test --update-goldens test/caches/thumbnails/thumbnail_golden_test.dart

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/caches/thumbnail_cache.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show EditorSelection, MediaHealth;
import 'package:danaview_editor/src/editor/timeline/render_timeline_canvas.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_snapshot.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_style.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_viewport.dart';
import 'package:danaview_editor_core/model.dart';

import '../../timeline/canvas/canvas_fixtures.dart';
import 'thumbnail_fixtures.dart';

const _width = 700.0;

class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile, {required this.tolerance});

  final double tolerance;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(imageBytes, await getGoldenBytes(golden));
    if (result.passed || result.diffPercent <= tolerance) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}

/// A strip of [frames] frames: a vertical gradient per frame in [frameColor] plus `n % 8 + 1`
/// white ticks along the top, so the frame number can be read off the golden.
Future<ui.Image> _strip(int tile, int intervalByte, int frames) async {
  const w = 32, h = 18;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  for (var j = 0; j < frames; j++) {
    final n = tile * frames + j;
    final base = frameColor(n + intervalByte * 1000);
    final rect = Rect.fromLTWH(j * w.toDouble(), 0, w.toDouble(), h.toDouble());
    canvas.drawRect(
      rect,
      ui.Paint()
        ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [base, Color.alphaBlend(const Color(0x66000000), base)]),
    );
    for (var t = 0; t <= n % 8; t++) {
      canvas.drawRect(Rect.fromLTWH(j * w + 2.0 + t * 3, 1, 2, 4), ui.Paint()..color = const Color(0xFFFFFFFF));
    }
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(frames * w, h);
  picture.dispose();
  return image;
}

class _Scene {
  const _Scene(this.name, {required this.deliver, this.dpr = 1.0});

  final String name;
  final bool Function(ScriptedHandle h) deliver;
  final double dpr;
}

final _scenes = [
  _Scene('loaded', deliver: (_) => true),
  _Scene('partial', deliver: (h) => h.request.tileIndex == 0, dpr: 2),
];

EditProject _project() {
  final main = Track(
    id: const TrackId('tr_main'),
    kind: TrackKind.video,
    isMain: true,
    items: [
      clip('it_v1', 'm_a', 0, 12 * s),
      clip('it_v2', 'm_img', 12 * s, 4 * s),
    ],
  );
  final video2 = Track(
    id: const TrackId('tr_video2'),
    kind: TrackKind.video,
    items: [
      clip('it_v3', 'm_a', 5 * s, 4 * s, reversed: true),
      clip('it_v4', 'm_b', 9 * s, 5 * s, speed: const ConstantSpeed(2)),
    ],
  );
  return projectOf([main, video2], assets: [asset('m_a'), asset('m_b'), asset('m_img', kind: MediaKind.image, hasAudio: false)]);
}

void main() {
  late GoldenFileComparator previous;

  setUpAll(() {
    previous = goldenFileComparator;
    if (previous is LocalFileComparator) {
      final base = (previous as LocalFileComparator).basedir;
      goldenFileComparator = _TolerantComparator(base.resolve('thumbnail_golden_test.dart'), tolerance: 0.005);
    }
  });

  tearDownAll(() => goldenFileComparator = previous);

  for (final scene in _scenes) {
    testWidgets('strips on the canvas: ${scene.name}, DPR ${scene.dpr.toInt()}', (tester) async {
      final metrics = TimelineMetrics(touch: false);
      final snap = TimelineSnapshotBuilder().build(_project(), health: MediaHealth.ok);
      final stack = TimelineLaneStack.of(snap.laneKinds, metrics, presets: snap.laneHeights);
      final height = stack.contentHeight + 4;
      tester.view
        ..devicePixelRatio = scene.dpr
        ..physicalSize = Size(_width, height) * scene.dpr;
      addTearDown(tester.view.reset);

      // Pre-render the strips the cache will decode (tiles 0-3; 1 s x 8 frames, 2 s x 8, a still).
      final strips = <(int, int, int), ui.Image>{};
      await tester.runAsync(() async {
        for (final tile in [0, 1, 2, 3]) {
          for (final (interval, frames) in [(10, 8), (20, 8), (10, 1)]) {
            strips[(tile, interval, frames)] = await _strip(tile, interval, frames);
          }
        }
      });
      addTearDown(() {
        for (final i in strips.values) {
          i.dispose();
        }
      });

      final source = ScriptedThumbnailSource();
      final cache = ThumbnailCache(
        source: source,
        resolve: resolverOf().call,
        decoder: (bytes) async => strips[(bytes[0], bytes[1], bytes[2])]!.clone(),
      );
      addTearDown(cache.dispose);

      final viewport = TimelineViewportController(defaultMode: PlayheadFollowMode.free, platform: TargetPlatform.android)
        ..setViewport(Size(_width, height), 0)
        ..setContent(duration: snap.duration, frameRate: snap.frameRate, contentHeight: stack.contentHeight)
        ..setPxPerSecond(80)
        ..jumpTo(scrollTimeSec: 5);
      addTearDown(viewport.dispose);
      final playhead = ValueNotifier<TimeUs>(0);
      addTearDown(playhead.dispose);

      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: _width,
            height: height,
            child: TimelineCanvas(
              snapshot: snap,
              viewport: viewport,
              selection: EditorSelection.empty,
              playhead: playhead,
              thumbnails: cache,
              style: TimelineStyle.standard.withFontFamily('Ahem'),
              metrics: metrics,
            ),
          ),
        ),
      ));
      expect(source.requests, isNotEmpty);
      for (final h in source.handles.toList()) {
        if (scene.deliver(h)) {
          h.complete();
        } else {
          h.cancel();
        }
      }
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(cache.cachedCount, greaterThan(0));

      final canvas = tester.renderObject<RenderTimelineCanvas>(find.byType(TimelineCanvas));
      final layer = canvas.debugLayer! as OffsetLayer;
      final image = (await tester.runAsync<ui.Image>(() => layer.toImage(Offset.zero & canvas.size, pixelRatio: scene.dpr)))!;
      addTearDown(image.dispose);
      await expectLater(image, matchesGoldenFile('goldens/thumbnails_${scene.name}_dpr${scene.dpr.toInt()}.png'));
    });
  }
}
