// OWNER: CORE-02
//
// Timecode display and entry (ARCH §5 "Display").

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';

void main() {
  const r30 = FrameRate.fps30;

  group('format', () {
    test('mm:ss:ff below one hour', () {
      expect(Timecode.format(0, r30), '00:00:00');
      expect(Timecode.format(r30.timeOfFrame(1), r30), '00:00:01');
      expect(Timecode.format(r30.timeOfFrame(29), r30), '00:00:29');
      expect(Timecode.format(1000000, r30), '00:01:00');
      expect(Timecode.format(r30.timeOfFrame(83 * 30 + 12), r30), '01:23:12');
      expect(Timecode.format(r30.timeOfFrame(3599 * 30 + 29), r30), '59:59:29');
    });

    test('h:mm:ss:ff from one hour', () {
      expect(Timecode.format(r30.timeOfFrame(3600 * 30), r30), '1:00:00:00');
      expect(Timecode.format(r30.timeOfFrame(3600 * 30 + 1), r30), '1:00:00:01');
      expect(Timecode.format(r30.timeOfFrame(23 * 3600 * 30 + 59 * 60 * 30 + 59 * 30 + 29), r30), '23:59:59:29');
    });

    test('counts frame indices of the project rate', () {
      expect(Timecode.format(FrameRate.fps24.timeOfFrame(23), FrameRate.fps24), '00:00:23');
      expect(Timecode.format(FrameRate.fps24.timeOfFrame(24), FrameRate.fps24), '00:01:00');
      expect(Timecode.format(FrameRate.fps60.timeOfFrame(59), FrameRate.fps60), '00:00:59');
    });

    test('a time inside a frame shows that frame', () {
      expect(Timecode.format(r30.timeOfFrame(5) + 1000, r30), '00:00:05');
      expect(Timecode.format(r30.timeOfFrame(6) - 1, r30), '00:00:05');
    });

    test('clock has no frames', () {
      expect(Timecode.clock(0), '0:00');
      expect(Timecode.clock(83500000), '1:23');
      expect(Timecode.clock(3600 * 1000000), '1:00:00');
    });
  });

  group('parse', () {
    test('m:ss', () => expect(Timecode.parse('1:23', r30), r30.timeOfFrame(83 * 30)));
    test('m:ss:ff', () => expect(Timecode.parse('1:23:12', r30), r30.timeOfFrame(83 * 30 + 12)));
    test('h:mm:ss:ff', () => expect(Timecode.parse('1:02:03:04', r30), r30.timeOfFrame((3723) * 30 + 4)));
    test('mm:ss:ff with leading zeros', () => expect(Timecode.parse('00:00:15', r30), r30.timeOfFrame(15)));

    test('seconds with a fraction floor to the grid', () {
      expect(Timecode.parse('83.5s', r30), r30.timeOfFrame(83 * 30 + 15));
      expect(Timecode.parse('83.51s', r30), r30.quantize(83510000));
      expect(Timecode.parse('2s', r30), r30.timeOfFrame(60));
    });

    test('relative seconds and frames', () {
      final base = r30.timeOfFrame(30);
      expect(Timecode.parse('+2s', r30, base: base), r30.timeOfFrame(90));
      expect(Timecode.parse('-10f', r30, base: base), r30.timeOfFrame(20));
      expect(Timecode.parse('+10f', r30, base: base), r30.timeOfFrame(40));
      expect(Timecode.parse('-1s', r30, base: base), 0);
      expect(Timecode.parse('-5s', r30, base: base), 0, reason: 'never before zero');
      expect(Timecode.parse('+0.5s', r30, base: 0), r30.timeOfFrame(15));
    });

    test('relative to an off-grid base moves from the base frame', () {
      expect(Timecode.parse('+3f', r30, base: r30.timeOfFrame(10) + 777), r30.timeOfFrame(13));
    });

    test('rejects what is not a timecode', () {
      for (final bad in ['', '  ', 'abc', '1:60', '1:23:30', '1:2:3:4:5', '::', '1:-2', '+s', '12', '1:x', '5 s']) {
        expect(Timecode.parse(bad, r30), isNull, reason: '"$bad"');
      }
    });

    test('whitespace is trimmed', () => expect(Timecode.parse('  1:23 ', r30), r30.timeOfFrame(83 * 30)));
  });

  group('round trip', () {
    test('parse(format(t)) == quantize(t) for every rate, including beyond one hour', () {
      for (final fps in FrameRate.supportedProjectRates) {
        final r = FrameRate(fps, 1);
        final times = <int>[
          0,
          1,
          999999,
          1000000,
          5333333,
          r.timeOfFrame(fps - 1) + 5,
          3599999999,
          3600 * 1000000,
          3600 * 1000000 + 17,
          25 * 3600 * 1000000 ~/ 2 + 12345,
          maxProjectDurationUs - 1,
        ];
        for (var k = 0; k < 2 * fps + 2; k++) {
          times.add(r.timeOfFrame(k));
        }
        for (final t in times) {
          expect(Timecode.parse(Timecode.format(t, r), r), r.quantize(t), reason: '$fps fps t=$t');
        }
      }
    });
  });
}
