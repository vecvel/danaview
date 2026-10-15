// OWNER: INT-04
//
// The resource governor's `ExportActivity` port (ARCH §16.5: generation waits while an export runs
// and pauses at a chunk boundary when one starts) bound to the engine's export state. The engine
// API has no push signal for "an export is running", so this polls `exporter.activeJobs()` while
// someone listens to [changes] (the governor, from `TranscriptionServiceImpl.initialize`) and on
// [refresh]. Running and resumable jobs count as active (the same rule as INT-02's GC gate); a
// failing probe keeps the last known state.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

/// [ExportActivity] over the engine's [ExportService].
final class EngineExportActivity implements ExportActivity {
  /// Creates the port over [exporter], polled every [interval] while [changes] has a listener.
  EngineExportActivity(this.exporter, {this.interval = const Duration(seconds: 3), this.timeout = const Duration(seconds: 2)}) {
    _changes = StreamController<bool>.broadcast(onListen: _startPolling, onCancel: _stopPolling);
  }

  /// The engine's export service.
  final ExportService exporter;

  /// Poll interval.
  final Duration interval;

  /// How long one probe may take.
  final Duration timeout;

  late final StreamController<bool> _changes;
  Timer? _timer;
  bool _active = false;
  Future<bool>? _probe;

  @override
  bool get isActive => _active;

  @override
  Stream<bool> get changes => _changes.stream;

  /// Asks the engine now; emits on [changes] when the state changed. Never throws.
  Future<bool> refresh() => _probe ??= _refresh().whenComplete(() => _probe = null);

  Future<bool> _refresh() async {
    try {
      final jobs = await exporter.activeJobs().timeout(timeout);
      _set(jobs.any((job) => job is ExportRunning || job is ExportResumable));
    } on Object catch (e) {
      debugPrint('[AutoCaptions] Export state unavailable: ${e.runtimeType}');
    }
    return _active;
  }

  void _set(bool active) {
    if (active == _active) return;
    _active = active;
    if (!_changes.isClosed) _changes.add(active);
  }

  void _startPolling() {
    unawaited(refresh());
    _timer ??= Timer.periodic(interval, (_) => unawaited(refresh()));
  }

  void _stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  /// Stops polling and closes [changes].
  Future<void> dispose() async {
    _stopPolling();
    await _changes.close();
  }
}
