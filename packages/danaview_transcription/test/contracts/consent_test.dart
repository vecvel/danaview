// OWNER: AI-08

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

void main() {
  test('disclosure names host, CDN, file, hash and total bytes incl. VAD', () {
    final d = ConsentDisclosure.of(SpeechModelCatalog.balanced, includesVad: true);
    expect(d.modelId, 'whisper-base-q5_1');
    expect(d.fileName, 'ggml-base-q5_1.bin');
    expect(d.host, 'huggingface.co');
    expect(d.cdnHost, 'hf.co');
    expect(d.sha256, SpeechModelCatalog.balanced.sha256);
    expect(d.totalBytes, 59707625 + 885098);
    expect(d.includesVad, isTrue);
  });

  test('without VAD the total is the model alone', () {
    final d = ConsentDisclosure.of(SpeechModelCatalog.fast, includesVad: false);
    expect(d.totalBytes, SpeechModelCatalog.fast.bytes);
    expect(d.includesVad, isFalse);
  });

  test('disclosures compare by every displayed field', () {
    final a = ConsentDisclosure.of(SpeechModelCatalog.balanced, includesVad: true);
    expect(a, ConsentDisclosure.of(SpeechModelCatalog.balanced, includesVad: true));
    expect(a.hashCode, ConsentDisclosure.of(SpeechModelCatalog.balanced, includesVad: true).hashCode);
    expect(a, isNot(ConsentDisclosure.of(SpeechModelCatalog.balanced, includesVad: false)));
    expect(a, isNot(ConsentDisclosure.of(SpeechModelCatalog.fast, includesVad: true)));
    expect(a, isNot(ConsentDisclosure.of(SpeechModelCatalog.accurate, includesVad: true)));
  });

  test('every tier produces a distinct disclosure naming the same hosts', () {
    final all = [for (final m in SpeechModelCatalog.models) ConsentDisclosure.of(m, includesVad: true)];
    expect(all.toSet(), hasLength(3));
    expect(all.map((d) => d.host).toSet(), {SpeechModelCatalog.host});
    expect(all.map((d) => d.cdnHost).toSet(), {SpeechModelCatalog.cdnHost});
  });

  test('matchesCatalog: true for catalog disclosures, false for any deviation or unknown id', () {
    for (final m in SpeechModelCatalog.models) {
      expect(ConsentDisclosure.of(m, includesVad: true).matchesCatalog, isTrue);
      expect(ConsentDisclosure.of(m, includesVad: false).matchesCatalog, isTrue);
    }
    ConsentDisclosure tweak({String? sha, int? bytes, String? host, String? id}) => ConsentDisclosure.forTesting(
          modelId: id ?? 'whisper-base-q5_1',
          fileName: 'ggml-base-q5_1.bin',
          host: host ?? 'huggingface.co',
          cdnHost: 'hf.co',
          sha256: sha ?? SpeechModelCatalog.balanced.sha256,
          totalBytes: bytes ?? SpeechModelCatalog.balanced.bytes + SpeechModelCatalog.vad.bytes,
          includesVad: true,
        );
    expect(tweak().matchesCatalog, isTrue);
    expect(tweak(sha: '0' * 64).matchesCatalog, isFalse);
    expect(tweak(bytes: 1).matchesCatalog, isFalse);
    expect(tweak(host: 'example.com').matchesCatalog, isFalse);
    expect(tweak(id: 'whisper-large').matchesCatalog, isFalse);
  });

  test('UserConsent keeps what the user saw and when they agreed (test-only construction)', () {
    final d = ConsentDisclosure.of(SpeechModelCatalog.accurate, includesVad: true);
    // Production call sites are restricted to model_consent_view.dart (UX-01 architecture test).
    final c = UserConsent.accepted(d, acceptedAt: DateTime.utc(2026, 10, 8, 12));
    expect(c.disclosure, d);
    expect(c.acceptedAt, DateTime.utc(2026, 10, 8, 12));
  });
}
