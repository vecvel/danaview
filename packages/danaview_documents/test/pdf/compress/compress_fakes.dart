// OWNER: HOM-31
//
// A fake PdfCompressEngine for the compress sheet tests: estimates as configured, runs that can be
// held open (to show progress and cancel), a real output file of the configured size per preset
// (so deleting the temporary file is observable), failures on demand, and recorded calls.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:danaview_pdf/danaview_pdf.dart';

/// A scriptable compress engine.
class FakeCompressEngine implements PdfCompressEngine {
  /// An engine whose runs write [sizes] bytes per preset.
  FakeCompressEngine({
    this.sizes = const {PdfCompressPreset.high: 8000, PdfCompressPreset.medium: 3000, PdfCompressPreset.small: 1000},
    this.estimateResult,
  });

  /// Output size per preset.
  final Map<PdfCompressPreset, int> sizes;

  /// What estimate answers (null: no estimate on this device).
  PdfCompressEstimate? estimateResult;

  /// Thrown by estimate when set.
  Object? estimateError;

  /// Thrown by compress when set.
  Object? fail;

  /// While set and not completed, compress waits (after reporting 0.4).
  Completer<void>? gate;

  /// compress requests: (jobId, preset, outPath, password).
  final List<(String, PdfCompressPreset, String, String?)> runs = [];

  /// Cancelled job ids.
  final List<String> cancelled = [];

  @override
  Future<PdfCompressEstimate?> estimate(String path, {String? password}) async {
    if (estimateError case final e?) throw e;
    return estimateResult;
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
    runs.add((jobId, preset, outPath, password));
    onProgress?.call(0.4);
    final g = gate;
    if (g != null) await g.future;
    if (cancelled.contains(jobId)) throw const PdfException(PdfErrorCode.cancelled, 'cancelled');
    if (fail case final f?) throw f;
    final size = sizes[preset]!;
    File(outPath).writeAsBytesSync(Uint8List(size));
    onProgress?.call(1);
    return PdfCompressOutput(path: outPath, sizeBytes: size, pageCount: 2);
  }

  @override
  Future<void> cancel(String jobId) async {
    cancelled.add(jobId);
    final g = gate;
    if (g != null && !g.isCompleted) g.complete();
  }
}
