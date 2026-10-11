// OWNER: AI-08

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

void main() {
  final every = <TranscriptionFailure>[
    const UnsupportedDeviceFailure('abi'),
    const ModelMissingFailure(),
    for (final k in ModelDownloadFailureKind.values) ModelDownloadFailure(k),
    const ModelCorruptFailure(),
    const InsufficientMemoryFailure(suggestedTier: SpeechModelTier.fast),
    const InsufficientMemoryFailure(),
    const DiskFullFailure(),
    const MediaOfflineFailure(MediaId('md_clipA0000001')),
    const NoAudioFailure(),
    const UnsupportedAudioFailure('ac4'),
    const AudioDecodeFailure(),
    const NoSpeechFailure(),
    const InferenceFailure('encoder'),
    const TranscriptionCancelled(),
    const TranscriptionInterrupted(),
  ];

  test('ARCH §16.5 failure taxonomy is complete and every failure has a stable code', () {
    final codes = every.map((f) => f.code).toList();
    expect(codes.toSet().length, codes.length - 1, reason: 'only the two insufficientMemory samples share a code');
    expect(
      codes.map((c) => c.split('.').first).toSet(),
      {
        'unsupportedDevice', 'modelMissing', 'modelDownload', 'modelCorrupt', 'insufficientMemory', 'diskFull', 'mediaOffline', 'noAudio',
        'unsupportedAudio', 'audioDecode', 'noSpeech', 'inference', 'cancelled', 'interrupted',
      },
    );
  });

  test('download failure kinds cover ai.md §5.3 and each has its own code', () {
    expect(ModelDownloadFailureKind.values.map((k) => k.name).toSet(), {
      'offline', 'timeout', 'server', 'secureConnection', 'interrupted', 'diskFull', 'checksumMismatch', 'sizeMismatch', 'cancelled',
      'consentMismatch',
    });
    expect(const ModelDownloadFailure(ModelDownloadFailureKind.timeout).code, 'modelDownload.timeout');
  });

  test('retryable: network and transient failures yes; consent mismatch, cancel and user-facing dead ends no', () {
    bool retry(TranscriptionFailure f) => f.retryable;
    expect(retry(const ModelDownloadFailure(ModelDownloadFailureKind.offline)), isTrue);
    expect(retry(const ModelDownloadFailure(ModelDownloadFailureKind.checksumMismatch)), isTrue);
    expect(retry(const ModelDownloadFailure(ModelDownloadFailureKind.consentMismatch)), isFalse);
    expect(retry(const ModelDownloadFailure(ModelDownloadFailureKind.cancelled)), isFalse);
    expect(retry(const InsufficientMemoryFailure(suggestedTier: SpeechModelTier.fast)), isTrue);
    expect(retry(const InsufficientMemoryFailure()), isFalse);
    expect(retry(const AudioDecodeFailure()), isTrue);
    expect(retry(const InferenceFailure()), isTrue);
    expect(retry(const TranscriptionInterrupted()), isTrue);
    expect(retry(const NoSpeechFailure()), isFalse);
    expect(retry(const NoAudioFailure()), isFalse);
    expect(retry(const TranscriptionCancelled()), isFalse);
    expect(retry(const UnsupportedDeviceFailure('platform')), isFalse);
  });

  test('failures are exceptions and an exhaustive switch compiles (sealed hierarchy)', () {
    for (final f in every) {
      final Exception e = f;
      expect(e, isA<TranscriptionFailure>());
      final label = switch (f) {
        UnsupportedDeviceFailure() => 'unsupported',
        ModelMissingFailure() => 'missing',
        ModelDownloadFailure() => 'download',
        ModelCorruptFailure() => 'corrupt',
        InsufficientMemoryFailure() => 'memory',
        DiskFullFailure() => 'disk',
        MediaOfflineFailure() => 'offline',
        NoAudioFailure() => 'noaudio',
        UnsupportedAudioFailure() => 'unsupportedaudio',
        AudioDecodeFailure() => 'decode',
        NoSpeechFailure() => 'nospeech',
        InferenceFailure() => 'inference',
        TranscriptionCancelled() => 'cancelled',
        TranscriptionInterrupted() => 'interrupted',
      };
      expect(label, isNotEmpty);
    }
  });

  test('failure codes and detail carry no transcript text or paths by construction', () {
    for (final f in every) {
      expect(f.code, isNot(contains('/')));
      expect(f.code, matches(RegExp(r'^[A-Za-z]+(\.[A-Za-z]+)?$')));
    }
  });
}
