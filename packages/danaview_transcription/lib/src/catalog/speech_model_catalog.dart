// OWNER: AI-08
//
// Pinned speech models (ARCH §16.2, ai.md §5.1). All multilingual; the user picks the language.
// Stored in <support>/danaview/speech/models/ (backup-excluded).

import 'package:meta/meta.dart';
import 'package:danaview_whisper/danaview_whisper.dart' show WhisperDtwPreset;

/// Quality tiers shown in the UI.
enum SpeechModelTier {
  /// Fast (tiny q5_1).
  fast,

  /// Balanced, the default (base q5_1).
  balanced,

  /// Accurate (small q5_1); hidden on devices with < 4 GB RAM.
  accurate,
}

const int _gib = 1024 * 1024 * 1024;
const int _mib = 1024 * 1024;

/// One downloadable model file.
@immutable
final class SpeechModelSpec {
  /// Creates a spec.
  const SpeechModelSpec({
    required this.id,
    required this.tier,
    required this.fileName,
    required this.url,
    required this.bytes,
    required this.sha256,
    required this.minDeviceRamBytes,
    required this.peakMemoryBudgetBytes,
    this.dtwPreset = WhisperDtwPreset.none,
  });

  /// Catalog id (`whisper-base-q5_1`).
  final String id;

  /// Tier (null for the VAD auxiliary model, which uses [SpeechModelTier.fast] as a placeholder).
  final SpeechModelTier tier;

  /// File name.
  final String fileName;

  /// Pinned download URL (never followed automatically; the downloader checks the redirect).
  final String url;

  /// Exact size in bytes.
  final int bytes;

  /// SHA-256 (lowercase hex).
  final String sha256;

  /// Marketed device RAM that offers this tier (2, 3 and 4 GiB, ARCH §16.2). Devices report
  /// less than they are sold with (a 4 GB phone reports 3.5-3.9 GiB), so the check is
  /// [isAvailableOn], never a plain comparison with this value.
  final int minDeviceRamBytes;

  /// Peak memory budget while transcribing (preflight requires 1.3× this available).
  final int peakMemoryBudgetBytes;

  /// DTW preset.
  final WhisperDtwPreset dtwPreset;

  /// Download host shown in the consent view (`huggingface.co`).
  String get host => Uri.parse(url).host;

  /// Whether a device reporting [physicalRamBytes] offers this tier: at least
  /// [SpeechModelCatalog.ramSlack] of the marketed RAM, so 4 GB devices (3.5-3.9 GiB reported)
  /// qualify for Accurate and 3 GB devices (2.7-3.0 GiB) do not.
  bool isAvailableOn(int physicalRamBytes) => physicalRamBytes >= minDeviceRamBytes * SpeechModelCatalog.ramSlack;

  @override
  bool operator ==(Object other) => other is SpeechModelSpec && other.id == id && other.sha256 == sha256 && other.bytes == bytes;

  @override
  int get hashCode => Object.hash(id, sha256, bytes);

  @override
  String toString() => 'SpeechModelSpec($id)';
}

/// The pinned catalog.
abstract final class SpeechModelCatalog {
  /// Bump when entries change.
  static const int revision = 1;

  /// Fraction of the marketed RAM a device must report to offer a tier (reported RAM is always
  /// below the marketed size: 2 GB phones report ~1.8-1.9 GiB, 3 GB ~2.7-3.0, 4 GB ~3.5-3.9).
  static const double ramSlack = 0.8;

  /// Download host named in the privacy policy (INT-04 test).
  static const String host = 'huggingface.co';

  /// CDN host the download redirects to, also named in the privacy policy.
  static const String cdnHost = 'hf.co';

  /// Pinned revision of `huggingface.co/ggerganov/whisper.cpp`.
  static const String modelRevision = '5359861c739e955e79d9a303bcbc70fb988958b1';

  /// Pinned revision of `huggingface.co/ggml-org/whisper-vad`.
  static const String vadRevision = '9ffd54a1e1ee413ddf265af9913beaf518d1639b';

  static const String _base = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/$modelRevision/';

  /// Fast tier.
  static const SpeechModelSpec fast = SpeechModelSpec(
    id: 'whisper-tiny-q5_1',
    tier: SpeechModelTier.fast,
    fileName: 'ggml-tiny-q5_1.bin',
    url: '${_base}ggml-tiny-q5_1.bin',
    bytes: 32152673,
    sha256: '818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7',
    minDeviceRamBytes: 2 * _gib,
    peakMemoryBudgetBytes: 200 * _mib,
    dtwPreset: WhisperDtwPreset.tiny,
  );

  /// Balanced tier (default).
  static const SpeechModelSpec balanced = SpeechModelSpec(
    id: 'whisper-base-q5_1',
    tier: SpeechModelTier.balanced,
    fileName: 'ggml-base-q5_1.bin',
    url: '${_base}ggml-base-q5_1.bin',
    bytes: 59707625,
    sha256: '422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898',
    minDeviceRamBytes: 3 * _gib,
    peakMemoryBudgetBytes: 300 * _mib,
    dtwPreset: WhisperDtwPreset.base,
  );

  /// Accurate tier (hidden below 4 GB RAM).
  static const SpeechModelSpec accurate = SpeechModelSpec(
    id: 'whisper-small-q5_1',
    tier: SpeechModelTier.accurate,
    fileName: 'ggml-small-q5_1.bin',
    url: '${_base}ggml-small-q5_1.bin',
    bytes: 190085487,
    sha256: 'ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb',
    minDeviceRamBytes: 4 * _gib,
    peakMemoryBudgetBytes: 650 * _mib,
    dtwPreset: WhisperDtwPreset.small,
  );

  /// Silero VAD, downloaded with any tier.
  static const SpeechModelSpec vad = SpeechModelSpec(
    id: 'silero-v6.2.0',
    tier: SpeechModelTier.fast,
    fileName: 'ggml-silero-v6.2.0.bin',
    url: 'https://huggingface.co/ggml-org/whisper-vad/resolve/$vadRevision/ggml-silero-v6.2.0.bin',
    bytes: 885098,
    sha256: '2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987',
    minDeviceRamBytes: 0,
    peakMemoryBudgetBytes: 5 * _mib,
  );

  /// The three tiers, fastest first.
  static const List<SpeechModelSpec> models = [fast, balanced, accurate];

  /// Installed files from older catalogs that are still valid.
  static const Set<String> acceptedLegacySha256 = {};

  /// The spec with [id], or null.
  static SpeechModelSpec? byId(String id) {
    for (final m in [...models, vad]) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Tiers offered on a device with [physicalRamBytes] (64-bit only; `isLowRamDevice` → Fast).
  static List<SpeechModelTier> availableTiers({required int physicalRamBytes, required bool is64Bit, bool isLowRamDevice = false}) {
    if (!is64Bit) return const [];
    if (isLowRamDevice) return const [SpeechModelTier.fast];
    return [for (final m in models) if (m.isAvailableOn(physicalRamBytes)) m.tier];
  }

  /// The spec of [tier] (the VAD model belongs to no tier).
  static SpeechModelSpec specOf(SpeechModelTier tier) => switch (tier) {
        SpeechModelTier.fast => fast,
        SpeechModelTier.balanced => balanced,
        SpeechModelTier.accurate => accurate,
      };

  /// Recommended tier: Balanced, or Fast below 3 GB (and on the minimal device tier, D-40).
  static SpeechModelTier recommendedTier({required int physicalRamBytes, bool minimalDevice = false}) =>
      (minimalDevice || !balanced.isAvailableOn(physicalRamBytes)) ? SpeechModelTier.fast : SpeechModelTier.balanced;
}
