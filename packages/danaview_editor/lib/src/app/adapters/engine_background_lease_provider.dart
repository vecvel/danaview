// OWNER: INT-04
//
// `BackgroundLeaseProvider` (danaview_transcription port, D-28) over the engine's
// `BackgroundWorkGuard` (`engine.background`: the Android FGS-hosted lease, the iOS background
// task; ARCH §16.5). A guard that throws or refuses yields null (the job then runs without a
// lease, as the port allows); release is idempotent and never throws.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

/// Background leases for transcription through the engine (D-28).
final class EngineBackgroundLeaseProvider implements BackgroundLeaseProvider {
  /// Creates the adapter.
  EngineBackgroundLeaseProvider(this.engine);

  /// The engine.
  final EditorEngine engine;

  @override
  Future<SpeechBackgroundLease?> acquire({required String title, required Stream<double> progress}) async {
    try {
      final lease = await engine.background.acquire(title: title, progress: progress);
      return lease == null ? null : _EngineLease(lease);
    } on Object catch (e) {
      debugPrint('[AutoCaptions] Background lease unavailable: ${e.runtimeType}');
      return null;
    }
  }
}

final class _EngineLease implements SpeechBackgroundLease {
  _EngineLease(this._lease);

  final BackgroundLease _lease;
  Future<void>? _released;

  @override
  Stream<void> get expiring => _lease.expiring;

  @override
  Future<void> release() => _released ??= _release();

  Future<void> _release() async {
    try {
      await _lease.release();
    } on Object catch (e) {
      debugPrint('[AutoCaptions] Lease release failed: ${e.runtimeType}');
    }
  }
}
