// OWNER: CORE-35
//
// Host-speed calibration of the core benchmarks. `baseline.json` is measured on one host; the gate
// runs on another (a CI VM that is 1.5-2.3x slower single-threaded). The calibration is a fixed
// pure-Dart workload of the same kind of work the core rows do (small-object allocation, map
// lookups, list sorting, string building, JSON + UTF-8 encoding) that uses no package code, so a
// core change never moves it. Its p50 in this run divided by its p50 in the baseline run is the
// host factor the gate applies to the baseline and to the ARCH §18.2 budgets (run.dart).

import 'dart:convert';

import 'harness.dart';

final class _Cue {
  _Cue(this.id, this.startUs, this.endUs, this.text);
  final String id;
  final int startUs;
  final int endUs;
  final String text;
}

/// One calibration pass (≈ 2-4 ms on the dev Mac).
int _workload(int seed) {
  var x = seed * 2654435761 + 1;
  int next() => x = (x * 1103515245 + 12345) & 0x7fffffff;
  final cues = <_Cue>[
    for (var i = 0; i < 3000; i++) _Cue('cu_${(next() % 100000).toString().padLeft(6, '0')}$i', next() % 10800000, 0, 'w$i'),
  ];
  cues.sort((a, b) => a.startUs != b.startUs ? a.startUs.compareTo(b.startUs) : a.id.compareTo(b.id));
  final byId = <String, _Cue>{for (final c in cues) c.id: c};
  var hits = 0;
  for (var i = 0; i < 6000; i++) {
    if (byId.containsKey(cues[next() % cues.length].id)) hits++;
  }
  final rows = [
    for (final c in cues.take(1500)) {'id': c.id, 't': [c.startUs, c.endUs + c.startUs], 'x': c.text, 'g': c.startUs / 3.0},
  ];
  final bytes = utf8.encode(jsonEncode({'v': 1, 'cues': rows}));
  return hits + bytes.length;
}

/// Calibration p50 (µs) of this host.
int calibrationUs({bool quick = false}) {
  final samples = measure(warmup: 5, samples: quick ? 10 : 40, body: (i) => blackhole = _workload(i));
  return MetricResult('host_calibration', samples, budgetUs: 0, label: 'host calibration', budgetGated: false).p50;
}
