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
/// churn, maps, sorting), the open row by [codec] (JSON parse, string and byte building), the
/// plan encode row by [planEncode] and the autosave row by [autosave]. Kinds slow down by
/// different amounts between hosts (ubuntu-latest vs the arm64 dev Mac: ≈ 1.2× for compute and
/// codec, ≈ 1.5× for the project and plan encoders), so one factor would either loosen some rows
/// or fail others.
///
/// [planEncode] and [autosave] are probes: the row's own encoder on a small input
/// ([encodeProbes] in core_benchmarks.dart), so the factor tracks exactly the row's kind of work.
/// Because a probe runs package code, a proportional encoder slowdown would move the probe with
/// the row; run.dart therefore also fails when a probe's factor drifts more than
/// `probeDriftLimit` from the [codec] factor (see run.dart).
enum CalibrationKind {
  compute,
  codec,
  planEncode,
  autosave;

  /// Whether this kind is a probe of package code (see above).
  bool get isProbe => this == planEncode || this == autosave;
}

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

/// Calibration p50s (µs) of this host by kind; [probes] supplies the probe kinds' workloads.
Map<CalibrationKind, int> calibrationUs({bool quick = false, Map<CalibrationKind, Object? Function(int)> probes = const {}}) {
  int p50(Object? Function(int) work) {
    final samples = measure(warmup: 5, samples: quick ? 10 : 40, body: (i) => blackhole = work(i));
    return MetricResult('host_calibration', samples, budgetUs: 0, label: 'host calibration', budgetGated: false).p50;
  }

  return {
    CalibrationKind.compute: p50(_compute),
    CalibrationKind.codec: p50(_codec),
    for (final e in probes.entries) e.key: p50(e.value),
  };
}
