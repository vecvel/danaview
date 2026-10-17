// OWNER: AI-08

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

const _gib = 1024 * 1024 * 1024;

void main() {
  group('pinned catalog (ARCH §16.2)', () {
    test('sizes and hashes are the pinned values', () {
      const expected = {
        'whisper-tiny-q5_1': ('ggml-tiny-q5_1.bin', 32152673, '818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7'),
        'whisper-base-q5_1': ('ggml-base-q5_1.bin', 59707625, '422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898'),
        'whisper-small-q5_1': ('ggml-small-q5_1.bin', 190085487, 'ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb'),
        'silero-v6.2.0': ('ggml-silero-v6.2.0.bin', 885098, '2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987'),
      };
      for (final m in [...SpeechModelCatalog.models, SpeechModelCatalog.vad]) {
        final e = expected[m.id]!;
        expect((m.fileName, m.bytes, m.sha256), e, reason: m.id);
      }
      expect(expected.keys.toSet(), {...SpeechModelCatalog.models.map((m) => m.id), SpeechModelCatalog.vad.id});
    });

    test('hashes are lowercase 64-hex and unique; ids and file names are unique', () {
      final all = [...SpeechModelCatalog.models, SpeechModelCatalog.vad];
      for (final m in all) {
        expect(m.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: m.id);
      }
      expect(all.map((m) => m.sha256).toSet(), hasLength(4));
      expect(all.map((m) => m.id).toSet(), hasLength(4));
      expect(all.map((m) => m.fileName).toSet(), hasLength(4));
    });

    test('host constants and pinned revisions', () {
      expect(SpeechModelCatalog.host, 'huggingface.co');
      expect(SpeechModelCatalog.cdnHost, 'hf.co');
      expect(SpeechModelCatalog.modelRevision, '5359861c739e955e79d9a303bcbc70fb988958b1');
      expect(SpeechModelCatalog.vadRevision, '9ffd54a1e1ee413ddf265af9913beaf518d1639b');
      expect(SpeechModelCatalog.modelRevision, matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(SpeechModelCatalog.vadRevision, matches(RegExp(r'^[0-9a-f]{40}$')));
    });

    test('URLs are https, on the catalog host, pinned to a revision and end with the file name', () {
      for (final m in SpeechModelCatalog.models) {
        final u = Uri.parse(m.url);
        expect(u.scheme, 'https');
        expect(m.host, SpeechModelCatalog.host);
        expect(u.path, '/ggerganov/whisper.cpp/resolve/${SpeechModelCatalog.modelRevision}/${m.fileName}');
        expect(u.hasQuery, isFalse);
      }
      final v = Uri.parse(SpeechModelCatalog.vad.url);
      expect(v.host, 'huggingface.co');
      expect(v.path, '/ggml-org/whisper-vad/resolve/${SpeechModelCatalog.vadRevision}/ggml-silero-v6.2.0.bin');
    });

    test('RAM floors and peak budgets (Fast 2 GB/200 MB, Balanced 3 GB/300 MB, Accurate 4 GB/650 MB)', () {
      expect(SpeechModelCatalog.fast.minDeviceRamBytes, 2 * _gib);
      expect(SpeechModelCatalog.balanced.minDeviceRamBytes, 3 * _gib);
      expect(SpeechModelCatalog.accurate.minDeviceRamBytes, 4 * _gib);
      expect(SpeechModelCatalog.fast.peakMemoryBudgetBytes, 200 * 1024 * 1024);
      expect(SpeechModelCatalog.balanced.peakMemoryBudgetBytes, 300 * 1024 * 1024);
      expect(SpeechModelCatalog.accurate.peakMemoryBudgetBytes, 650 * 1024 * 1024);
      expect(SpeechModelCatalog.models.map((m) => m.tier), SpeechModelTier.values);
    });

    test('lookup by id and tier', () {
      expect(SpeechModelCatalog.byId('whisper-base-q5_1'), same(SpeechModelCatalog.balanced));
      expect(SpeechModelCatalog.byId('silero-v6.2.0'), same(SpeechModelCatalog.vad));
      expect(SpeechModelCatalog.byId('whisper-large'), isNull);
      for (final t in SpeechModelTier.values) {
        expect(SpeechModelCatalog.specOf(t).tier, t);
      }
    });

    test('DTW presets are the whisper_alignment_heads_preset values', () {
      expect(SpeechModelCatalog.fast.dtwPreset.nativeValue, 4);
      expect(SpeechModelCatalog.balanced.dtwPreset.nativeValue, 6);
      expect(SpeechModelCatalog.accurate.dtwPreset.nativeValue, 8);
    });

    test('ARCHITECTURE.md §16.2 table still matches the catalog (guards doc/code drift)', () {
      final doc = File('../../docs/v1.1/editor/ARCHITECTURE.md');
      if (!doc.existsSync()) return;
      final text = doc.readAsStringSync();
      for (final m in [...SpeechModelCatalog.models, SpeechModelCatalog.vad]) {
        final row = text.split('\n').firstWhere((l) => l.contains(m.fileName) && l.startsWith('|'), orElse: () => '');
        expect(row, isNotEmpty, reason: '${m.fileName} row missing in ARCHITECTURE.md');
        expect(row.replaceAll(',', ''), contains('${m.bytes}'), reason: m.fileName);
        expect(row, contains(m.sha256), reason: m.fileName);
      }
      expect(text, contains(SpeechModelCatalog.modelRevision));
      expect(text, contains(SpeechModelCatalog.vadRevision));
    });
  });

  group('tier gating by reported RAM', () {
    // Devices report less than their marketed RAM.
    const iphone8 = 2095000000; // 2 GB
    const iphoneX = 2990000000; // 3 GB
    const iphone12 = 3860000000; // 4 GB
    const iphone14Pro = 5800000000; // 6 GB
    const android3gb = 2800000000;
    const android4gb = 3700000000;
    const android8gb = 7800000000;

    List<SpeechModelTier> tiers(int ram, {bool is64 = true, bool low = false}) =>
        SpeechModelCatalog.availableTiers(physicalRamBytes: ram, is64Bit: is64, isLowRamDevice: low);

    test('Accurate is hidden below 4 GB (marketed), offered at 4 GB and above', () {
      expect(tiers(iphone8), [SpeechModelTier.fast]);
      expect(tiers(iphoneX), [SpeechModelTier.fast, SpeechModelTier.balanced]);
      expect(tiers(android3gb), [SpeechModelTier.fast, SpeechModelTier.balanced]);
      expect(tiers(iphone12), SpeechModelTier.values);
      expect(tiers(android4gb), SpeechModelTier.values);
      expect(tiers(iphone14Pro), SpeechModelTier.values);
      expect(tiers(android8gb), SpeechModelTier.values);
    });

    test('exact boundaries of the 0.8 slack', () {
      expect(tiers((3 * _gib * 0.8).ceil() - 1), [SpeechModelTier.fast]);
      expect(tiers((3 * _gib * 0.8).ceil()), [SpeechModelTier.fast, SpeechModelTier.balanced]);
      expect(tiers((4 * _gib * 0.8).ceil() - 1), [SpeechModelTier.fast, SpeechModelTier.balanced]);
      expect(tiers((4 * _gib * 0.8).ceil()), SpeechModelTier.values);
      expect(tiers((2 * _gib * 0.8).ceil() - 1), isEmpty);
      expect(tiers((2 * _gib * 0.8).ceil()), [SpeechModelTier.fast]);
    });

    test('a 3 GB device never reaches Accurate and a 2 GB device never reaches Balanced', () {
      expect(SpeechModelCatalog.accurate.isAvailableOn(3 * _gib), isFalse);
      expect(SpeechModelCatalog.balanced.isAvailableOn(2 * _gib), isFalse);
    });

    test('low-RAM Android and 32-bit processes', () {
      expect(tiers(android8gb, low: true), [SpeechModelTier.fast]);
      expect(tiers(android8gb, is64: false), isEmpty);
      expect(tiers(0), isEmpty);
    });

    test('recommended tier: Balanced, Fast on small or minimal devices', () {
      expect(SpeechModelCatalog.recommendedTier(physicalRamBytes: iphone8), SpeechModelTier.fast);
      expect(SpeechModelCatalog.recommendedTier(physicalRamBytes: iphoneX), SpeechModelTier.balanced);
      expect(SpeechModelCatalog.recommendedTier(physicalRamBytes: android8gb), SpeechModelTier.balanced);
      expect(SpeechModelCatalog.recommendedTier(physicalRamBytes: android8gb, minimalDevice: true), SpeechModelTier.fast);
    });
  });

  test('QA-06 tuning placeholder holds the ai.md defaults', () {
    expect(SpeechTuning.chunkTargetMs, 180000);
    expect(SpeechTuning.chunkSearchMs, 15000);
    expect(SpeechTuning.noSpeechThreshold, 0.6);
    expect(SpeechTuning.entropyThreshold, 2.4);
    expect(SpeechTuning.logprobThreshold, -1.0);
    expect(SpeechTuning.carryPromptWords, 24);
    expect(SpeechTuning.autoDetectMinProbability, 0.6);
    expect(SpeechTuning.standardMaxCharsPerLine, 42);
    expect(SpeechTuning.standardMaxCps, 17);
  });
}
