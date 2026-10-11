// OWNER: ENG-03
//
// Pickers, file handoff, background leases and external drops over `PlatformHostApi`
// (ARCH §12.4, §15, D-18).
//
// Rules:
// - MobileMediaPicker: an empty list (or a `cancelled` reply) means the user cancelled.
// - MobileFileHandoff: a `cancelled` reply maps to FileHandoffOutcome.cancelled and
//   `permissionDenied` to FileHandoffOutcome.denied; every other failure is rethrown as the typed
//   EngineFailure.
// - MobileBackgroundWorkGuard: `acquire` returns null when native has no lease (null id or
//   `notSupportedOnDevice`). A lease forwards the caller's progress stream to `updateBackground`
//   with at most one call in flight (the latest value wins, values clamped to 0..1), forwards
//   `leaseExpiring` events of `channels.router.job(leaseId)` to [BackgroundLease.expiring], and
//   `release` is idempotent: it stops forwarding, closes `expiring`, drops late events and calls
//   `releaseBackground` once.
// - MobileExternalDropTarget: drops come from `channels.router.drops` in logical px; drops that
//   arrive after `setEnabled(false)` was called are dropped on the Dart side too.

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

import 'pigeon/conversions.dart';
import 'pigeon/engine_api.g.dart';
import 'pigeon/engine_channels.dart';

/// System pickers over `PlatformHostApi.pick` (ARCH §12.4, ENG-03).
final class MobileMediaPicker implements MediaPicker {
  /// Creates the picker.
  MobileMediaPicker(this._channels);

  final EngineChannels _channels;

  @override
  Future<List<PickedMedia>> pick(MediaPickRequest request) async {
    try {
      final picked = await _channels.invoke(() => _channels.platform.pick(mediaPickRequestToMsg(request)));
      return List<PickedMedia>.unmodifiable(picked.map(pickedMediaFromMsg));
    } on EngineCancelled {
      return const [];
    }
  }
}

/// Photos / Files / share handoff over `PlatformHostApi` (ARCH §12.4, ENG-03).
final class MobileFileHandoff implements FileHandoff {
  /// Creates the handoff.
  MobileFileHandoff(this._channels);

  final EngineChannels _channels;

  Future<FileHandoffResult> _run(Future<FileHandoffResultMsg> Function() call) async {
    try {
      return fileHandoffResultFromMsg(await _channels.invoke(call));
    } on EngineCancelled {
      return const FileHandoffResult(FileHandoffOutcome.cancelled);
    } on EngineError catch (e) {
      if (e.code == EngineErrorCode.permissionDenied) return const FileHandoffResult(FileHandoffOutcome.denied);
      rethrow;
    }
  }

  @override
  Future<FileHandoffResult> saveToPhotos(String path) => _run(() => _channels.platform.saveToPhotos(path));

  @override
  Future<FileHandoffResult> saveToFiles(String path, String suggestedName) =>
      _run(() => _channels.platform.saveToFiles(path, suggestedName));

  @override
  Future<FileHandoffResult> share(String path) => _run(() => _channels.platform.share(path));
}

/// Background leases over `PlatformHostApi.acquireBackground` (ARCH §12.4, ENG-03).
final class MobileBackgroundWorkGuard implements BackgroundWorkGuard {
  /// Creates the guard.
  MobileBackgroundWorkGuard(this._channels);

  final EngineChannels _channels;

  @override
  Future<BackgroundLease?> acquire({required String title, required Stream<double> progress}) async {
    final String? id;
    try {
      id = await _channels.invoke(() => _channels.platform.acquireBackground(title));
    } on EngineError catch (e) {
      if (e.code == EngineErrorCode.notSupportedOnDevice) return null;
      rethrow;
    }
    if (id == null) return null;
    return MobileBackgroundLease._(_channels, id, progress);
  }
}

/// A held background lease (ARCH §12.4, ENG-03). See the file header for the rules.
final class MobileBackgroundLease implements BackgroundLease {
  MobileBackgroundLease._(this._channels, this.id, Stream<double> progress) {
    _events = _channels.router.job(id).listen((e) {
      if (e.kind == EngineEventKindMsg.leaseExpiring && !_expiring.isClosed) _expiring.add(null);
    });
    _progress = progress.listen(_onProgress, onError: (Object _) {});
  }

  final EngineChannels _channels;

  @override
  final String id;

  late final StreamSubscription<EngineEventMsg> _events;
  late final StreamSubscription<double> _progress;
  final StreamController<void> _expiring = StreamController<void>.broadcast();
  Future<void>? _release;
  bool _updating = false;
  double? _pending;
  double? _lastSent;

  /// Whether [release] was called.
  bool get isReleased => _release != null;

  /// The last progress value sent to native.
  @visibleForTesting
  double? get lastSentProgress => _lastSent;

  void _onProgress(double value) {
    if (_release != null) return;
    _pending = value.isNaN ? 0 : value.clamp(0.0, 1.0);
    _flush();
  }

  void _flush() {
    if (_updating || _release != null) return;
    final value = _pending;
    _pending = null;
    if (value == null || value == _lastSent) return;
    _updating = true;
    _lastSent = value;
    unawaited(
        _channels.invoke(() => _channels.platform.updateBackground(id, value)).then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      _updating = false;
      _flush();
    }));
  }

  @override
  Stream<void> get expiring => _expiring.stream;

  @override
  Future<void> release() => _release ??= _doRelease();

  Future<void> _doRelease() async {
    _pending = null;
    _channels.router.release(id);
    await Future.wait([_progress.cancel(), _events.cancel()]);
    await _expiring.close();
    await _channels.invoke(() => _channels.platform.releaseBackground(id));
  }
}

/// External drag and drop over `PlatformHostApi.setDropTargetEnabled` (ARCH §12.4, D-18, ENG-03).
final class MobileExternalDropTarget implements ExternalDropTarget {
  /// Creates the drop target.
  MobileExternalDropTarget(this._channels);

  final EngineChannels _channels;
  bool _enabled = false;
  int _generation = 0;

  /// Whether drops are accepted (disabled at once on `setEnabled(false)`, enabled once native
  /// confirmed the last `setEnabled(true)`).
  bool get isEnabled => _enabled;

  @override
  Future<void> setEnabled(bool on) async {
    final generation = ++_generation;
    if (!on) _enabled = false;
    await _channels.invoke(() => _channels.platform.setDropTargetEnabled(on));
    if (generation == _generation) _enabled = on;
  }

  @override
  late final Stream<ExternalDrop> drops = _channels.router.drops.where((_) => _enabled).map(dropFromMsg);
}
