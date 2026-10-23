// OWNER: CORE-35
//
// Host-speed calibration of the core benchmarks. `baseline.json` is measured on one host; the gate
// runs on another (a CI VM that is 1.5-2.3x slower single-threaded). The calibration is a fixed
// pure-Dart workload of the same kind of work the core rows do (small-object allocation, map
// lookups, list sorting, string building, JSON + UTF-8 encoding) that uses no package code, so a
// core change never moves it. Its p50 in this run divided by its p50 in the baseline run is the
// host factor the gate applies to the baseline and to the ARCH §18.2 budgets (run.dart), one factor
// per [CalibrationKind].

import 'dart:convert';
import 'dart:typed_data';

import 'harness.dart';

final class _Cue {
  _Cue(this.id, this.startUs, this.endUs, this.text);
  final String id;
  final int startUs;
  final int endUs;
  final String text;
}

/// Which calibration a row is normalized by: the model/ops/compile rows by [compute] (object
/// churn, maps, sorting), the encode/decode rows by [codec] (JSON, double formatting, string and
/// byte building). The two kinds slow down by different amounts between hosts (x86_64 Linux vs
/// the arm64 dev Mac: ≈ 1.5× for compute, up to 2× for codec work), so one factor would either
/// loosen the compute rows or fail the codec rows.
enum CalibrationKind { compute, codec }

int _compute(int seed) {
  var x = seed * 2654435761 + 1;
  int next() => x = (x * 1103515245 + 12345) & 0x7fffffff;
  final cues = <_Cue>[
    for (var i = 0; i < 3000; i++) _Cue('cu_${(next() % 100000).toString().padLeft(6, '0')}$i', next() % 10800000, 0, 'w$i'),
  ];
  cues.sort((a, b) => a.startUs != b.startUs ? a.startUs.compareTo(b.startUs) : a.id.compareTo(b.id));
  final byId = <String, _Cue>{for (final c in cues) c.id: c};
  var hits = 0;
  for (var i = 0; i < 12000; i++) {
    if (byId.containsKey(cues[next() % cues.length].id)) hits++;
  }
  final moved = [for (final c in cues) _Cue(c.id, c.startUs + 33333, c.startUs + 66666, c.text)];
  return hits + moved.length;
}

int _codec(int seed) {
  var x = seed * 2654435761 + 1;
  int next() => x = (x * 1103515245 + 12345) & 0x7fffffff;
  final rows = [
    for (var i = 0; i < 1500; i++)
      {
        'id': 'it_${i.toString().padLeft(10, '0')}',
        't': [next() % 10800000, next() % 10800000],
        'g': [for (var k = 0; k < 4; k++) (next() % 100000) / 7.0],
        'x': 'clip $i',
      },
  ];
  final text = jsonEncode({'v': 1, 'items': rows});
  final bytes = utf8.encode(text);
  final back = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < 8; i++) {
    out.add(bytes);
  }
  return (back['items']! as List<Object?>).length + out.length;
}

/// Calibration p50s (µs) of this host by kind.
Map<CalibrationKind, int> calibrationUs({bool quick = false}) {
  int p50(int Function(int) work) {
    final samples = measure(warmup: 5, samples: quick ? 10 : 40, body: (i) => blackhole = work(i));
    return MetricResult('host_calibration', samples, budgetUs: 0, label: 'host calibration', budgetGated: false).p50;
  }

  return {CalibrationKind.compute: p50(_compute), CalibrationKind.codec: p50(_codec)};
}
