// OWNER: AI-13
//
// Every failure kind of ARCH §16.5 / ai.md §15 surfaces typed on `TranscriptionJob.result` (never
// synchronously), with the documented recovery: corrupt model marked, GPU inference retried once
// on the CPU, unsupported codecs skipped with a summary note, records kept only when retryable.

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_whisper/danaview_whisper.dart';
import 'package:flutter_test/flutter_test.dart';

import '../timeline/timeline_fixtures.dart';
import 'support/pipeline_fakes.dart';

void main() {
  late Harness h;
  setUp(() async => h = await Harness.create());
  tearDown(() async => h.dispose());

  Future<T> failure<T extends Object>(TranscriptionJob job) async {
    try {
      await job.result;
    } on Object catch (e) {
      expect(e, isA<T>());
      return e as T;
    }
    fail('expected $T');
  }

  group('device and model', () {
    test('unsupported runtime -> unsupportedDevice(reason)', () async {
      final other = await Harness.create(runtime: FakeWhisperRuntime(support: const WhisperUnsupported(WhisperUnsupportedReason.abi)));
      addTearDown(other.dispose);
      final f = await failure<UnsupportedDeviceFailure>(other.start().$1);
      expect(f.reason, 'abi');
    });

    test('unknown model id -> modelMissing', () async {
      await failure<ModelMissingFailure>(h.start(h.request(modelId: 'nope')).$1);
    });

    test('corrupt model status -> modelCorrupt', () async {
      h.store.ready.remove(SpeechModelCatalog.balanced.id);
      h.store.corrupt.add(SpeechModelCatalog.balanced.id);
      await failure<ModelCorruptFailure>(h.start().$1);
    });

    test('load failure -> modelCorrupt and the file is marked damaged', () async {
      h.runtime.loadFailure = WhisperErrorKind.modelLoadFailed;
      await failure<ModelCorruptFailure>(h.start().$1);
      expect(h.store.markedCorrupt, [SpeechModelCatalog.balanced.id]);
    });

    test('out of memory while loading -> insufficientMemory suggesting a smaller tier', () async {
      h.runtime.loadFailure = WhisperErrorKind.outOfMemory;
      final f = await failure<InsufficientMemoryFailure>(h.start().$1);
      expect(f.suggestedTier, SpeechModelTier.fast);
    });

    test('library unavailable while loading -> unsupportedDevice', () async {
      h.runtime.loadFailure = WhisperErrorKind.libraryUnavailable;
      final f = await failure<UnsupportedDeviceFailure>(h.start().$1);
      expect(f.reason, 'libraryUnavailable');
    });

    test('VAD model missing -> modelMissing', () async {
      h.runtime.transcribeScript = (j) => j.fail(WhisperErrorKind.vadModelMissing);
      await failure<ModelMissingFailure>(h.start().$1);
    });
  });

  group('inference', () {
    test('an inference error on the GPU is retried once on the CPU', () async {
      h.runtime.modelUsesGpu = true;
      var n = 0;
      h.runtime.transcribeScript = (j) => ++n == 1 ? j.fail(WhisperErrorKind.inference) : j.succeed(segments: fixtureSegments);
      final r = await h.start().$1.result;
      expect(h.runtime.loadGpu, [true, false]);
      expect(r.drafts, isNotEmpty);
      expect(h.runtime.models.first.released, isTrue);
    });

    test('an inference error on the CPU -> inference (retryable, record kept)', () async {
      h.runtime.transcribeScript = (j) => j.fail(WhisperErrorKind.inference);
      final f = await failure<InferenceFailure>(h.start().$1);
      expect(f.retryable, isTrue);
      expect(await h.service.resumableFor(h.project.id), isNotNull);
    });

    test('out of memory while transcribing -> insufficientMemory', () async {
      h.runtime.transcribeScript = (j) => j.fail(WhisperErrorKind.outOfMemory);
      await failure<InsufficientMemoryFailure>(h.start().$1);
    });

    test('invalid audio -> audioDecode', () async {
      h.runtime.transcribeScript = (j) => j.fail(WhisperErrorKind.invalidAudio);
      await failure<AudioDecodeFailure>(h.start().$1);
    });

    test('no speech anywhere -> noSpeech, and the record is dropped (not retryable)', () async {
      h.runtime.transcribeScript = (j) => j.fail(WhisperErrorKind.noSpeech);
      await failure<NoSpeechFailure>(h.start().$1);
      expect(await h.service.resumableFor(h.project.id), isNull);
    });

    test('a native cancel without a user cancel -> cancelled', () async {
      h.runtime.transcribeScript = (j) => j.fail(WhisperErrorKind.cancelled);
      await failure<TranscriptionCancelled>(h.start().$1);
    });
  });

  group('audio', () {
    test('nothing audible in scope -> noAudio (muted clips reported)', () async {
      h.project = project([
        mainTrack([clip('c1', 0, 10000, 'm1', muted: true)]),
      ], [
        asset('m1'),
      ]);
      await failure<NoAudioFailure>(h.start().$1);
    });

    test('a clip scope that matches nothing -> noAudio', () async {
      await failure<NoAudioFailure>(h.start(h.request(scope: const ClipScope(ItemId('missing')))).$1);
    });

    test('offline media -> mediaOffline(media)', () async {
      h.offline = {'m1'};
      final f = await failure<MediaOfflineFailure>(h.start().$1);
      expect(f.media, const MediaId('m1'));
    });

    for (final (kind, matcher) in [
      (SpeechAudioFailureKind.mediaOffline, isA<MediaOfflineFailure>()),
      (SpeechAudioFailureKind.permissionDenied, isA<MediaOfflineFailure>()),
      (SpeechAudioFailureKind.decodeFailed, isA<AudioDecodeFailure>()),
      (SpeechAudioFailureKind.diskFull, isA<DiskFullFailure>()),
      (SpeechAudioFailureKind.noAudioTrack, isA<NoAudioFailure>()),
      (SpeechAudioFailureKind.unsupportedCodec, isA<UnsupportedAudioFailure>()),
      (SpeechAudioFailureKind.cancelled, isA<TranscriptionCancelled>()),
    ]) {
      test('extractor ${kind.name} on the only unit', () async {
        h.extractor.failures['file:///media/m1.mp4'] = kind;
        await expectLater(h.start().$1.result, throwsA(matcher));
      });
    }

    test('an unsupported codec on one unit skips its clips and continues', () async {
      h.project = twoClipProject();
      h.extractor.failures['file:///media/m2.mp4'] = SpeechAudioFailureKind.unsupportedCodec;
      final r = await h.start().$1.result;
      expect(r.summary.skipped.map((s) => (s.item.value, s.reason)), [('c2', 'unsupportedCodec')]);
      expect(r.provenance.transcriptKeys, [h.key()]);
    });

    test('reversed clips are skipped and reported', () async {
      h.project = project([
        mainTrack([clip('c1', 0, 10000, 'm1'), clip('c2', 10000, 20000, 'm2', reversed: true)]),
      ], [
        asset('m1'),
        asset('m2'),
      ]);
      final r = await h.start().$1.result;
      expect(r.summary.skipped.map((s) => (s.item.value, s.reason)), [('c2', 'reversed')]);
    });
  });

  test('start never throws synchronously for a bad request', () async {
    final job = h.start(h.request(modelId: 'nope')).$1;
    expect(job.id, isNotEmpty);
    await expectLater(job.result, throwsA(isA<TranscriptionFailure>()));
  });
}
