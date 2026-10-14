// OWNER: AI-13
//
// Progress weights and ETA (ai.md §8.5): extraction 0.10, load 0.05, detection 0.05,
// transcription 0.75, finishing 0.05, weighted by unit duration; prior real-time factor before
// 10% of transcription, then the smoothed measured ratio; no ETA while paused; <= 4 Hz samples.

import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:flutter_test/flutter_test.dart';

import '../timeline/timeline_fixtures.dart';
import 'support/pipeline_fakes.dart';

void main() {
  test('weights by phase and by unit duration', () {
    final m = JobProgressModel(unitDurations: [sec(30), sec(10)], priorRtf: 0.2);
    expect(m.fraction, 0);
    m.extraction(0, 1);
    expect(m.fraction, closeTo(0.10 * 0.75, 1e-9));
    m
      ..extraction(1, 1)
      ..loaded()
      ..detected();
    expect(m.fraction, closeTo(0.20, 1e-9));
    m.transcription(1, 1);
    expect(m.fraction, closeTo(0.20 + 0.75 * 0.25, 1e-9));
    expect(m.processed, sec(10));
    m
      ..transcription(0, 1)
      ..finishing(1);
    expect(m.fraction, closeTo(1, 1e-9));
    expect(m.total, sec(40));
  });

  test('cached units count as done', () {
    final m = JobProgressModel(unitDurations: [sec(10), sec(10)], priorRtf: 0.2)..markUnitDone(0);
    expect(m.transcriptionFraction, 0.5);
    expect(m.fraction, closeTo(0.10 * 0.5 + 0.75 * 0.5, 1e-9));
  });

  test('ETA: prior factor first, then the smoothed measured ratio; none while paused', () {
    final m = JobProgressModel(unitDurations: [sec(100)], priorRtf: 0.2);
    expect(m.eta(), const Duration(seconds: 20));
    m.measure(compute: const Duration(seconds: 1), processed: const Duration(seconds: 2));
    m.transcription(0, 0.05);
    expect(m.eta(), Duration(microseconds: (sec(95) * 0.2).round()), reason: 'below 10%: prior');
    m.transcription(0, 0.5);
    expect(m.eta(), const Duration(seconds: 25), reason: 'measured 0.5 x 50 s');
    m.measure(compute: const Duration(seconds: 1), processed: const Duration(seconds: 10));
    expect(m.eta(), Duration(microseconds: (sec(50) * (0.3 * 0.1 + 0.7 * 0.5)).round()));
    expect(m.eta(paused: true), isNull);
    m.transcription(0, 1);
    expect(m.eta(), Duration.zero);
  });

  test('prior real-time factors grow with the tier', () {
    expect(priorRealTimeFactor(SpeechModelTier.fast), lessThan(priorRealTimeFactor(SpeechModelTier.balanced)));
    expect(priorRealTimeFactor(SpeechModelTier.balanced), lessThan(priorRealTimeFactor(SpeechModelTier.accurate)));
  });

  test('status updates are throttled to the progress interval (fixed clock: phase changes only)', () async {
    final h = await Harness.create();
    addTearDown(h.dispose);
    h.runtime.transcribeScript = (j) {
      for (var i = 1; i <= 50; i++) {
        j.status(fraction: i / 50, processed: Duration(milliseconds: i * 200), compute: Duration(milliseconds: i * 40));
      }
      j.succeed(segments: fixtureSegments);
    };
    final (job, samples) = h.start();
    await job.result;
    final transcribing = samples.where((s) => s.phase == TranscriptionPhase.transcribing).length;
    expect(transcribing, lessThan(5));
    expect(samples.where((s) => s.phase == TranscriptionPhase.transcribing).first.eta, isNotNull);
  });
}
