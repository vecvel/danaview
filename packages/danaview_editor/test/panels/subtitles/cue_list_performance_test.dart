// OWNER: UX-31
//
// The cue list with 3,000 cues (ux.md §10.9): rows are built lazily (only about a screenful exists
// at any time), the frame cost of scrolling stays within 8 ms (timed around each scroll frame's
// build, layout and paint in the test harness, after a warm-up; the device budget is QA-04's), the
// first frame stays cheap, and the cue under the playhead is kept in view while playing.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/panels/subtitles_panel.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;

import '../../support/support.dart';
import 'subtitles_rig.dart';

Finder get _rows => find.byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey<String> && k.value.startsWith('subtitles.cue.');
    });

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(of: find.byKey(SubtitlesPanelKeys.scroll), matching: find.byType(Scrollable)).first)
    .position;

void main() {
  tearDown(EditorAnnouncer.instance.reset);

  testWidgets('3,000 cues: lazily built rows and scroll frames within 8 ms', (tester) async {
    final first = Stopwatch()..start();
    final rig = await SubtitlesRig.pump(tester, cueCount: 3000, surface: const EditorSurface(Size(390, 844)));
    first.stop();
    expect(rig.cues(Subs.a), hasLength(3000));
    final built = _rows.evaluate().length;
    expect(built, inInclusiveRange(1, 40), reason: 'only the visible rows (and the cache extent) are built');

    final position = _position(tester);
    expect(position.maxScrollExtent, greaterThan(3000 * 40.0), reason: 'every row has its extent');

    Future<int> frame(double delta) async {
      final sw = Stopwatch()..start();
      position.jumpTo((position.pixels + delta).clamp(0, position.maxScrollExtent));
      await tester.pump();
      sw.stop();
      return sw.elapsedMicroseconds;
    }

    for (var i = 0; i < 30; i++) {
      await frame(220); // warm-up (JIT, text layout caches)
    }
    final times = <int>[];
    for (var i = 0; i < 240; i++) {
      times.add(await frame(i < 120 ? 180 : -150));
    }
    // A long fling: a jump of thousands of rows in one frame.
    times.add(await frame(position.maxScrollExtent * 0.8 - position.pixels));
    times.sort();
    final median = times[times.length ~/ 2] / 1000;
    final p90 = times[(times.length * 0.9).floor()] / 1000;
    final average = times.reduce((a, b) => a + b) / times.length / 1000;
    debugPrint('cue list scroll: median ${median.toStringAsFixed(2)} ms, p90 ${p90.toStringAsFixed(2)} ms, '
        'average ${average.toStringAsFixed(2)} ms, first frame ${first.elapsedMilliseconds} ms');
    expect(median, lessThanOrEqualTo(8.0), reason: 'median scroll frame');
    expect(average, lessThanOrEqualTo(8.0), reason: 'average scroll frame');
    expect(_rows.evaluate().length, inInclusiveRange(1, 40), reason: 'rows are recycled while scrolling');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('while playing, the cue under the playhead is kept in view', (tester) async {
    final rig = await SubtitlesRig.pump(tester, cueCount: 3000, surface: const EditorSurface(Size(390, 844)));
    await rig.real(() => rig.transport.play());
    expect(rig.playhead.playing.value, isTrue);
    await rig.real(() => rig.playhead.seekExact(frames(45 * 1500 + 5)));
    await tester.pump();
    final rowFinder = find.byKey(SubtitlesPanelKeys.row(Subs.many(1500)));
    expect(rowFinder, findsOneWidget);
    final view = tester.getRect(find.byKey(SubtitlesPanelKeys.scroll));
    final r = tester.getRect(rowFinder);
    expect(r.top, greaterThanOrEqualTo(view.top - 0.5));
    expect(r.bottom, lessThanOrEqualTo(view.bottom + 0.5));
    await rig.real(() => rig.transport.pause());
    await tester.pump(const Duration(seconds: 5));
  });
}
