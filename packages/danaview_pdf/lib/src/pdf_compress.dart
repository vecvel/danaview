// OWNER: HOM-31
//
// PDF compress (HOM plan §8.5, D-98j; BUILD_PLAN HOM-31, HOM-31A) over the Pigeon surface:
// `PdfToolsHostApi.compress` / `cancel` with its progress events, and the additive
// `PdfCompressHostApi.estimate`. Apple: PDFKit write options plus an image XObject re-encoder
// (darwin/Classes/Compress). Android (HOM-31A): PdfBox-Android per the HOM-27 report.
//
// The contract both platforms keep (BUILD_STATE, HOM-31):
//
// * the source is opened read-only and never written; only [PdfCompressEngine.compress]'s
//   `outPath` is written, once, and it must not exist yet (`invalidArgument`);
// * a cancelled job fails with `cancelled` and leaves no file at `outPath`;
// * text, fonts and vectors are kept (text stays selectable and searchable); only images are
//   re-encoded: High JPEG at high quality and full resolution, Medium about 144 dpi at medium
//   quality, Small lower again; outputs shrink High > Medium > Small on image-heavy files;
// * an encrypted source (opened with its password) is written back encrypted with it;
// * the result may be no smaller than the source (a text-only file): the caller decides, the
//   engine never refuses for that;
// * `estimate` may be missing (Pigeon `channel-error`): [PdfCompressEngine.estimate] then answers
//   null and the sheet shows sizes once a preset has run.
//
// Nothing here logs a path, a name or a password (rule 30).

import 'dart:async';

import 'pdf_document.dart';
import 'pigeon/pdf_api.g.dart';
import 'pigeon/pdf_channels.dart';

/// The compression presets, from the gentlest to the strongest.
enum PdfCompressPreset {
  /// Best quality: images re-encoded at full resolution.
  high,

  /// Good for screens and email: images at about 144 dpi.
  medium,

  /// Smallest file: images at lower resolution and quality.
  small,
}

/// What each preset would give for one file.
final class PdfCompressEstimate {
  /// An estimate.
  const PdfCompressEstimate({required this.sourceBytes, required this.bytes, this.sampled = false});

  /// The file's size now.
  final int sourceBytes;

  /// Expected bytes per preset.
  final Map<PdfCompressPreset, int> bytes;

  /// True when extrapolated from a sample of pages (long files); false when exact.
  final bool sampled;

  @override
  String toString() => 'PdfCompressEstimate($sourceBytes, $bytes, sampled: $sampled)';
}

/// What a compress run wrote.
final class PdfCompressOutput {
  /// An output.
  const PdfCompressOutput({required this.path, required this.sizeBytes, required this.pageCount});

  /// The new file.
  final String path;

  /// Its size.
  final int sizeBytes;

  /// Its pages.
  final int pageCount;
}

/// Compresses PDFs into new files. Implementations: [PlatformPdfCompressEngine]; tests fake it.
abstract interface class PdfCompressEngine {
  /// Each preset's size for [path], or null when this device can't estimate.
  Future<PdfCompressEstimate?> estimate(String path, {String? password});

  /// Writes [path] compressed with [preset] to the new file [outPath]. [onProgress] gets 0…1.
  /// Throws [PdfException] (`cancelled` after [cancel], `passwordRequired`, `damaged`, …).
  Future<PdfCompressOutput> compress({
    required String jobId,
    required String path,
    required PdfCompressPreset preset,
    required String outPath,
    String? password,
    void Function(double fraction)? onProgress,
  });

  /// Cancels job [jobId] if it runs.
  Future<void> cancel(String jobId);
}

/// [PdfCompressEngine] over the plugin.
final class PlatformPdfCompressEngine implements PdfCompressEngine {
  /// An engine over the default plugin instance, or the given APIs and [events] (tests).
  PlatformPdfCompressEngine({PdfToolsHostApi? toolsApi, PdfCompressHostApi? compressApi, PdfEventHub? events})
      : _tools = toolsApi ?? PdfToolsHostApi(),
        _compress = compressApi ?? PdfCompressHostApi(),
        _events = events ?? PdfEventHub.forInstance();

  final PdfToolsHostApi _tools;
  final PdfCompressHostApi _compress;
  final PdfEventHub _events;

  @override
  Future<PdfCompressEstimate?> estimate(String path, {String? password}) async {
    try {
      final e = await guardPdf(() => _compress.estimate(PdfToolInputMsg(path: path, password: password, isImage: false)));
      return PdfCompressEstimate(
        sourceBytes: e.sourceBytes,
        bytes: {
          PdfCompressPreset.high: e.highBytes,
          PdfCompressPreset.medium: e.mediumBytes,
          PdfCompressPreset.small: e.smallBytes,
        },
        sampled: e.sampled,
      );
    } on PdfException catch (e) {
      if (e.code == PdfErrorCode.notSupportedOnDevice) return null;
      rethrow;
    }
  }

  @override
  Future<PdfCompressOutput> compress({
    required String jobId,
    required String path,
    required PdfCompressPreset preset,
    required String outPath,
    String? password,
    void Function(double fraction)? onProgress,
  }) async {
    StreamSubscription<PdfEventMsg>? progress;
    if (onProgress != null) {
      progress = _events.events.listen((e) {
        final p = e.toolProgress;
        if (e.kind == PdfEventKindMsg.toolProgress && p != null && p.jobId == jobId) onProgress(p.fraction.clamp(0.0, 1.0));
      });
    }
    try {
      final r = await guardPdf(
        () => _tools.compress(PdfCompressRequestMsg(
          jobId: jobId,
          input: PdfToolInputMsg(path: path, password: password, isImage: false),
          preset: PdfCompressPresetMsg.values[preset.index],
          outPath: outPath,
        )),
      );
      if (r.outPaths.isEmpty || r.sizesBytes.isEmpty) throw const PdfException(PdfErrorCode.internal, 'empty result');
      return PdfCompressOutput(path: r.outPaths.first, sizeBytes: r.sizesBytes.first, pageCount: r.pageCounts.isEmpty ? 0 : r.pageCounts.first);
    } finally {
      await progress?.cancel();
    }
  }

  @override
  Future<void> cancel(String jobId) => guardPdf(() => _tools.cancel(jobId));
}
