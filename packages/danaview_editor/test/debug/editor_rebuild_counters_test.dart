// OWNER: UX-01
//
// EditorRebuildCounters and EditorPerfHooks (QA-04 hooks): off by default, counting and sampling
// only when enabled, bounded buffers.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/debug/debug.dart';

void main() {
  tearDown(() {
    EditorRebuildCounters.enabled = false;
    EditorRebuildCounters.reset();
    EditorPerfHooks.enabled = false;
    EditorPerfHooks.listener = null;
    EditorPerfHooks.clear();
  });

  group('EditorRebuildCounters', () {
    test('counts only when enabled', () {
      EditorRebuildCounters.count('A');
      expect(EditorRebuildCounters.of('A'), 0);
      EditorRebuildCounters.enabled = true;
      EditorRebuildCounters.count('A');
      EditorRebuildCounters.count('A');
      EditorRebuildCounters.count('B');
      expect(EditorRebuildCounters.snapshot(), {'A': 2, 'B': 1});
      final before = EditorRebuildCounters.snapshot();
      EditorRebuildCounters.count('B');
      expect(EditorRebuildCounters.since(before), {'B': 1});
    });

    testWidgets('record() measures rebuilds of a probe during a scenario', (tester) async {
      final tick = ValueNotifier<int>(0);
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: ValueListenableBuilder<int>(
          valueListenable: tick,
          builder: (context, v, _) => EditorRebuildProbe(name: 'Timecode', child: SizedBox(width: v.toDouble())),
        ),
      ));
      final counts = await EditorRebuildCounters.record(() async {
        for (var i = 1; i <= 5; i++) {
          tick.value = i;
          await tester.pump();
        }
      });
      expect(counts, {'Timecode': 5});
      expect(EditorRebuildCounters.enabled, isFalse);
    });
  });

  group('EditorPerfHooks', () {
    test('records samples only when enabled', () async {
      expect(EditorPerfHooks.timeSync('x', () => 1), 1);
      expect(EditorPerfHooks.samples, isEmpty);
      final seen = <EditorPerfSample>[];
      EditorPerfHooks.enabled = true;
      EditorPerfHooks.listener = seen.add;
      EditorPerfHooks.timeSync(EditorPerfMarks.timelinePaint, () {}, args: {'items': 12});
      await EditorPerfHooks.timeAsync(EditorPerfMarks.autosaveBlock, () async {});
      final span = EditorPerfHooks.begin(EditorPerfMarks.editorOpenToFirstFrame);
      span
        ..end()
        ..end();
      EditorPerfHooks.record(const EditorPerfSample(EditorPerfMarks.commitToPreview, Duration(milliseconds: 9)));
      expect(EditorPerfHooks.samples.map((s) => s.name), [
        EditorPerfMarks.timelinePaint,
        EditorPerfMarks.autosaveBlock,
        EditorPerfMarks.editorOpenToFirstFrame,
        EditorPerfMarks.commitToPreview,
      ]);
      expect(seen, hasLength(4));
      expect(EditorPerfHooks.samplesOf(EditorPerfMarks.timelinePaint).single.args, {'items': 12});
    });

    test('the buffer is bounded', () {
      EditorPerfHooks.enabled = true;
      for (var i = 0; i < EditorPerfHooks.capacity + 10; i++) {
        EditorPerfHooks.record(EditorPerfSample('s$i', Duration.zero));
      }
      expect(EditorPerfHooks.samples, hasLength(EditorPerfHooks.capacity));
      expect(EditorPerfHooks.samples.first.name, 's10');
    });

    test('mark names are unique and namespaced', () {
      expect(EditorPerfMarks.all.toSet(), hasLength(EditorPerfMarks.all.length));
      expect(EditorPerfMarks.all.every((m) => m.startsWith('editor.')), isTrue);
    });
  });
}
