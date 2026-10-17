// OWNER: CORE-03
//
// Canonical track order, bands and display order (ARCH §6.2, §11.4, D-09).

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';

import 'model_fixtures.dart';

List<String> ids(Iterable<Track> ts) => [for (final t in ts) t.id];

void main() {
  final video0 = track('tr_v0', TrackKind.video, main: true);
  final video1 = track('tr_v1', TrackKind.video);
  final overlay0 = track('tr_o0', TrackKind.overlay);
  final overlay1 = track('tr_o1', TrackKind.overlay);
  final text0 = track('tr_t0', TrackKind.text);
  final sub0 = track('tr_s0', TrackKind.subtitle);
  final audio0 = track('tr_a0', TrackKind.audio);
  final audio1 = track('tr_a1', TrackKind.audio);
  final canonical = [video0, video1, overlay0, overlay1, text0, sub0, audio0, audio1];

  group('TrackKind', () {
    test('canonicalOrder is video, overlay, text, subtitle, audio', () {
      final sorted = [...TrackKind.values]..sort((a, b) => a.canonicalOrder.compareTo(b.canonicalOrder));
      expect(sorted, [TrackKind.video, TrackKind.overlay, TrackKind.text, TrackKind.subtitle, TrackKind.audio]);
    });

    test('bands bottom to top: video 0, overlay 1, text 2, subtitle 3, audio none', () {
      expect(TrackKind.video.band, 0);
      expect(TrackKind.overlay.band, 1);
      expect(TrackKind.text.band, 2);
      expect(TrackKind.subtitle.band, 3);
      expect(TrackKind.audio.band, isNull);
    });

    test('isVisual is everything except audio', () {
      expect(TrackKind.values.where((k) => k.isVisual), [TrackKind.video, TrackKind.overlay, TrackKind.text, TrackKind.subtitle]);
    });
  });

  group('TrackOrder', () {
    test('isCanonical', () {
      expect(TrackOrder.isCanonical(canonical), isTrue);
      expect(TrackOrder.isCanonical(const []), isTrue);
      expect(TrackOrder.isCanonical([audio0, video0]), isFalse);
      expect(TrackOrder.isCanonical([video0, text0, overlay0]), isFalse);
      expect(TrackOrder.isCanonical([video0, sub0, text0]), isFalse);
    });

    test('bandsAscend ignores audio lanes', () {
      expect(TrackOrder.bandsAscend(canonical), isTrue);
      expect(TrackOrder.bandsAscend([video0, audio0, overlay0]), isTrue);
      expect(TrackOrder.bandsAscend([overlay0, video0]), isFalse);
      expect(TrackOrder.bandsAscend([text0, overlay0]), isFalse);
    });

    test('insertIndexFor puts a new lane at the top of its kind group', () {
      expect(TrackOrder.insertIndexFor(canonical, TrackKind.video), 2);
      expect(TrackOrder.insertIndexFor(canonical, TrackKind.overlay), 4);
      expect(TrackOrder.insertIndexFor(canonical, TrackKind.text), 5);
      expect(TrackOrder.insertIndexFor(canonical, TrackKind.subtitle), 6);
      expect(TrackOrder.insertIndexFor(canonical, TrackKind.audio), 8);
      expect(TrackOrder.insertIndexFor(const [], TrackKind.audio), 0);
      expect(TrackOrder.insertIndexFor([video0], TrackKind.overlay), 1);
      expect(TrackOrder.insertIndexFor([audio0], TrackKind.video), 0);
      expect(TrackOrder.insertIndexFor([video0, audio0], TrackKind.text), 1);
    });

    test('inserting at insertIndexFor always keeps the order canonical', () {
      final ts = <Track>[];
      var n = 0;
      for (final k in [TrackKind.audio, TrackKind.text, TrackKind.video, TrackKind.subtitle, TrackKind.overlay, TrackKind.audio, TrackKind.video, TrackKind.overlay, TrackKind.text]) {
        ts.insert(TrackOrder.insertIndexFor(ts, k), track('tr_${n++}', k));
        expect(TrackOrder.isCanonical(ts), isTrue, reason: 'after adding $k');
      }
      expect(ts.map((t) => t.kind), [
        TrackKind.video, TrackKind.video, TrackKind.overlay, TrackKind.overlay, TrackKind.text, TrackKind.text, TrackKind.subtitle, TrackKind.audio, TrackKind.audio,
      ]);
    });

    test('mainTrack is the first video track', () {
      expect(TrackOrder.mainTrack(canonical)?.id, 'tr_v0');
      expect(TrackOrder.mainTrack([overlay0, audio0]), isNull);
    });

    test('zOrder lists visual lanes bottom to top; zRankOf matches', () {
      expect(ids(TrackOrder.zOrder(canonical)), ['tr_v0', 'tr_v1', 'tr_o0', 'tr_o1', 'tr_t0', 'tr_s0']);
      expect(TrackOrder.zRankOf(canonical, video0.id), 0);
      expect(TrackOrder.zRankOf(canonical, sub0.id), 5);
      expect(TrackOrder.zRankOf(canonical, audio0.id), isNull);
      expect(TrackOrder.zRankOf(canonical, const TrackId('tr_none')), isNull);
    });

    test('displayOrder (D-09): subtitle, text, overlays, extra video, main, then audio', () {
      expect(ids(TrackOrder.displayOrder(canonical)), ['tr_s0', 'tr_t0', 'tr_o1', 'tr_o0', 'tr_v1', 'tr_v0', 'tr_a0', 'tr_a1']);
      expect(ids(TrackOrder.displayOrder(const [])), isEmpty);
    });

    test('displayOrder of a canonical order is reverse z for every visual lane', () {
      final d = TrackOrder.displayOrder(canonical).where((t) => t.kind.isVisual).toList();
      final z = TrackOrder.zOrder(canonical);
      expect(ids(d), ids(z.reversed));
    });
  });
}
