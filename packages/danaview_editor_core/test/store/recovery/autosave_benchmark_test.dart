// OWNER: CORE-26
//
// Benchmark (ARCH §18.2, CORE-26 AC): the main-isolate part of an autosave at 1,000 items is the
// incremental encode of the edited project (`FragmentCache`; hashing and writing run in the
// writer isolate). It must stay ≤ 2 ms. Measured after a one-item edit with a warm cache, best of
// 15 runs (other processes on the machine must not decide the result); the median is printed.
// Without DV_PERF_STRICT=1 the limit is 4× looser.

import 'dart:io' show Platform;

import 'package:test/test.dart';
import 'package:danaview_editor_core/codec.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../repository/support/repo_support.dart';

/// DV_PERF_STRICT=1 (a quiet dev Mac) asserts the absolute budget; otherwise (a loaded CI runner)
/// [_looseFactor] times it.
final bool _perfStrict = Platform.environment['DV_PERF_STRICT'] == '1';
const int _looseFactor = 4;
num _limit(num budget) => _perfStrict ? budget : budget * _looseFactor;
String get _perfMode => _perfStrict ? 'DV_PERF_STRICT=1' : 'loose ×$_looseFactor, no DV_PERF_STRICT';

void main() {
  test('main-isolate block per autosave ≤ 2 ms at 1,000 items', () {
    final session = EditSession(bigProject(1000), ids: SeededIdGenerator(3), clock: () => when);
    final codec = ProjectJsonCodec();
    codec.encodeBytes(session.project); // the open-time encode warms the cache
    final runs = <int>[];
    for (var i = 0; i < 16; i++) {
      final out = session.apply(MoveItems({const ItemId('it_c999')}, rate.timeOfFrame(1)));
      expect(out.changed, isTrue);
      final sw = Stopwatch()..start();
      final bytes = codec.encodeBytes(session.project);
      sw.stop();
      expect(bytes, isNotEmpty);
      if (i > 0) runs.add(sw.elapsedMicroseconds);
    }
    runs.sort();
    final best = runs.first / 1000;
    final median = runs[runs.length ~/ 2] / 1000;
    // ignore: avoid_print
    print('autosave encode at 1,000 items: best ${best.toStringAsFixed(2)} ms, median ${median.toStringAsFixed(2)} ms');
    expect(best, lessThanOrEqualTo(_limit(2)), reason: 'best $best ms ($_perfMode)');
    expect(codec.encode(session.project), ProjectJsonCodec().encode(session.project), reason: 'incremental == full');
  });
}
