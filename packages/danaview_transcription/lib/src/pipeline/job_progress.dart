// OWNER: AI-13
//
// Progress and ETA of one job (ai.md §8.5).
//
// Weights: extraction 0.10, model load 0.05, language detection 0.05, transcription 0.75,
// segmentation and finishing 0.05. Inside extraction and transcription each unit weighs by its
// duration; cached units count as done. ETA: before 10% of the transcription phase the prior
// real-time factor of the tier, after that the measured compute/processed ratio, exponentially
// smoothed (alpha 0.3), times the audio left. No ETA while paused.

import 'package:danaview_editor_core/model.dart';

import '../catalog/speech_model_catalog.dart';

/// Prior compute time per second of audio (ai.md §14.1 midpoints, mid-range Android, the
/// slowest common class; AI-19/QA-06 replace them with measurements).
double priorRealTimeFactor(SpeechModelTier tier) => switch (tier) {
      SpeechModelTier.fast => 4.5 / 60,
      SpeechModelTier.balanced => 11 / 60,
      SpeechModelTier.accurate => 42 / 60,
    };

/// Mutable progress state of a job.
final class JobProgressModel {
  /// Creates the model for units of [unitDurations] (µs).
  JobProgressModel({required List<TimeUs> unitDurations, required this.priorRtf})
      : _durations = List.of(unitDurations),
        _extracted = List.filled(unitDurations.length, 0),
        _transcribed = List.filled(unitDurations.length, 0);

  /// Phase weights (ai.md §8.5).
  static const double wExtract = 0.10, wLoad = 0.05, wDetect = 0.05, wTranscribe = 0.75, wFinish = 0.05;

  /// Smoothing factor of the measured real-time factor.
  static const double alpha = 0.3;

  /// Prior real-time factor (compute per audio).
  final double priorRtf;

  final List<TimeUs> _durations;
  final List<double> _extracted;
  final List<double> _transcribed;
  double _load = 0;
  double _detect = 0;
  double _finish = 0;
  double? _rtf;

  TimeUs get _total => _durations.fold(0, (n, d) => n + d);

  /// Unit [i] needs no work (cached or skipped).
  void markUnitDone(int i) {
    _extracted[i] = 1;
    _transcribed[i] = 1;
  }

  /// Extraction of unit [i] is [f] done.
  void extraction(int i, double f) => _extracted[i] = f.clamp(0, 1).toDouble();

  /// Transcription of unit [i] is [f] done.
  void transcription(int i, double f) => _transcribed[i] = f.clamp(0, 1).toDouble();

  /// Model load done (or not needed).
  void loaded() => _load = 1;

  /// Language detection done (or not needed).
  void detected() => _detect = 1;

  /// Mapping and segmentation [f] done.
  void finishing(double f) => _finish = f.clamp(0, 1).toDouble();

  /// Feeds a measured sample: [compute] spent on [processed] audio of the current unit.
  void measure({required Duration compute, required Duration processed}) {
    if (processed.inMicroseconds <= 0 || compute.inMicroseconds <= 0) return;
    final sample = compute.inMicroseconds / processed.inMicroseconds;
    _rtf = _rtf == null ? sample : alpha * sample + (1 - alpha) * _rtf!;
  }

  double _weighted(List<double> parts) {
    final total = _total;
    if (total <= 0) return parts.isEmpty ? 1 : parts.fold<double>(0, (a, b) => a + b) / parts.length;
    var done = 0.0;
    for (var i = 0; i < parts.length; i++) {
      done += parts[i] * _durations[i];
    }
    return done / total;
  }

  /// Transcription phase share done.
  double get transcriptionFraction => _weighted(_transcribed);

  /// Audio processed by transcription (µs, cached units included).
  TimeUs get processed => (_weighted(_transcribed) * _total).round();

  /// Audio in total (µs).
  TimeUs get total => _total;

  /// Overall fraction 0..1.
  double get fraction {
    final f = wExtract * _weighted(_extracted) +
        wLoad * _load +
        wDetect * _detect +
        wTranscribe * _weighted(_transcribed) +
        wFinish * _finish;
    return f.clamp(0, 1).toDouble();
  }

  /// Estimated time left, or null when [paused].
  Duration? eta({bool paused = false}) {
    if (paused) return null;
    final left = _total - processed;
    if (left <= 0) return Duration.zero;
    final rtf = transcriptionFraction < 0.10 || _rtf == null ? priorRtf : _rtf!;
    return Duration(microseconds: (left * rtf).round());
  }
}
