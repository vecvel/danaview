// OWNER: UX-21
//
// Waveforms on the timeline canvas (ux.md §8.6, §17.4): an audio clip, one with volume keyframes
// (selected, so the canvas draws its volume line over the scaled bars), a reversed one, a 2x one,
// a muted one, a clip still loading (centre line), and a video clip with audio on a Large lane.
// DPR 1 at 70 px/s and DPR 2 zoomed out. Ahem font; synthetic speech-like peaks.
//
// Regenerate (after reviewing the change) with:
//   flutter test --update-goldens test/caches/waveforms/waveform_golden_test.dart

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/caches/waveform_cache.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show EditorSelection, MediaHealth;
import 'package:danaview_editor/src/editor/timeline/render_timeline_canvas.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_snapshot.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_style.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_viewport.dart';
import 'package:danaview_editor_core/model.dart';

import '../../timeline/canvas/canvas_fixtures.dart';
import 'waveform_fixtures.dart';

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

/// Speech-like amplitude: phrases of about 2 s with a fast flutter inside.
double _speech(double t) {
  final phrase = math.pow(math.sin(t * 1.55).abs(), 0.7).toDouble();
  final flutter = 0.55 + 0.45 * math.sin(t * 37).abs();
  return 8 + 112 * phrase * flutter;
}

EditProject _project() {
  final main = Track(
    id: const TrackId('tr_main'),
    kind: TrackKind.video,
    isMain: true,
    items: [clip('it_v1', 'm_v', 0, 8 * s, audio: const AudioProps(volume: 0.8))],
  );
  final music = Track(
    id: const TrackId('tr_music'),
    kind: TrackKind.audio,
    audioRole: AudioRole.music,
    items: [
      clip('it_a1', 'm_snd', 0, 5 * s),
      clip('it_a2', 'm_snd', 5 * s, 4 * s, keyframes: keys({'audio.volume': [0, 60, 120]}, v: 1), audio: const AudioProps(volume: 1)),
    ],
  );
  final second = Track(
    id: const TrackId('tr_voice'),
    kind: TrackKind.audio,
    audioRole: AudioRole.voice,
    items: [
      clip('it_a3', 'm_snd', 0, 3 * s, reversed: true),
      clip('it_a4', 'm_snd', 3 * s, 2 * s, speed: const ConstantSpeed(2)),
      clip('it_a5', 'm_snd', 5 * s, 2 * s, audio: const AudioProps(muted: true)),
      clip('it_a6', 'm_snd2', 7 * s, 3 * s),
    ],
  );
  return projectOf([main, music, second], assets: [asset('m_v'), asset('m_snd', kind: MediaKind.audio), asset('m_snd2', kind: MediaKind.audio)]);
}

class _Scene {
  const _Scene(this.name, this.pxPerSecond, this.dpr);

  final String name;
  final double pxPerSecond;
  final double dpr;
}

void main() {
  late GoldenFileComparator previous;

  setUpAll(() {
    previous = goldenFileComparator;
    if (previous is LocalFileComparator) {
      final base = (previous as LocalFileComparator).basedir;
      goldenFileComparator = _TolerantComparator(base.resolve('waveform_golden_test.dart'), tolerance: 0.005);
    }
  });

  tearDownAll(() => goldenFileComparator = previous);

  for (final scene in const [_Scene('detail', 70, 1), _Scene('overview', 25, 2)]) {
    testWidgets('waveforms on the canvas: ${scene.name}, DPR ${scene.dpr.toInt()}', (tester) async {
      final metrics = TimelineMetrics(touch: false, laneHeight: LaneHeightPreset.large);
      final snap = TimelineSnapshotBuilder().build(_project(), health: MediaHealth.ok, laneHeight: LaneHeightPreset.large);
      final stack = TimelineLaneStack.of(snap.laneKinds, metrics, presets: snap.laneHeights);
      final height = stack.contentHeight + 4;
      tester.view
        ..devicePixelRatio = scene.dpr
        ..physicalSize = Size(_width, height) * scene.dpr;
      addTearDown(tester.view.reset);

      final source = ScriptedWaveformSource();
      final cache = WaveformCache(source: source, resolve: waveResolver().call, maxConcurrent: 4, builder: (p) async => WaveformPyramid.fromPeaks(p));
      addTearDown(cache.dispose);

      final viewport = TimelineViewportController(defaultMode: PlayheadFollowMode.free, platform: TargetPlatform.android)
        ..setViewport(Size(_width, height), 0)
        ..setContent(duration: snap.duration, frameRate: snap.frameRate, contentHeight: stack.contentHeight)
        ..setPxPerSecond(scene.pxPerSecond)
        ..jumpTo(scrollTimeSec: 0);
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
              selection: EditorSelection(items: {const ItemId('it_a2')}, primary: const ItemId('it_a2')),
              playhead: playhead,
              waveforms: cache,
              style: TimelineStyle.standard.withFontFamily('Ahem'),
              metrics: metrics,
            ),
          ),
        ),
      ));
      // The first pass shows centre lines; m_snd2 stays pending to show that state too.
      expect(source.jobs, hasLength(3), reason: 'video audio, music and the second song');
      for (final (i, job) in source.jobs.indexed) {
        final media = source.media[i].fingerprint;
        if (media == 'fp-m_snd2') continue;
        job.complete(peaksOf(30, _speech));
      }
      await tester.pump();
      await tester.pump();
      expect(cache.cachedCount, 2);

      final canvas = tester.renderObject<RenderTimelineCanvas>(find.byType(TimelineCanvas));
      expect(canvas.debugLastPaint!.waveformFallbacks, 1, reason: 'one clip still waits for its peaks');
      final layer = canvas.debugLayer! as OffsetLayer;
      final image = (await tester.runAsync<ui.Image>(() => layer.toImage(Offset.zero & canvas.size, pixelRatio: scene.dpr)))!;
      addTearDown(image.dispose);
      await expectLater(image, matchesGoldenFile('goldens/waveforms_${scene.name}_dpr${scene.dpr.toInt()}.png'));
    });
  }
}
