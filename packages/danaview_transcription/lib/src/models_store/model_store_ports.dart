// OWNER: AI-09
//
// Ports of the model store (ai.md §5.3, §5.4). Free space, backup exclusion and the iOS
// background task come from the `danaview_whisper/device` channel (AI-06) through
// [WhisperDeviceModelStorePlatform]; the wakelock is a port because this package is pure Dart
// (ARCH §4.2 rule 6): INT-04 adapts `wakelock_plus` (danaview_platform) to [DownloadWakelock].

library;

import 'package:danaview_whisper/danaview_whisper.dart';

/// Device services the downloader needs.
abstract interface class ModelStorePlatform {
  /// Free bytes on the volume holding [path]; null when unknown (the preflight then passes).
  Future<int?> freeDiskBytes(String path);

  /// Excludes [path] from backups (iOS resource key; Android relies on the manifest rules).
  /// False when it could not be excluded; never throws.
  Future<bool> excludeFromBackup(String path);

  /// Starts an iOS background task (null on Android or when refused).
  Future<int?> beginBackgroundTask(String name);

  /// Ends a task from [beginBackgroundTask].
  Future<void> endBackgroundTask(int id);

  /// App lifecycle and background-task events ([AppStateChanged], [BackgroundTaskExpiring]).
  Stream<WhisperDeviceEvent> get events;
}

/// [ModelStorePlatform] over the `danaview_whisper/device` channel (AI-06). Every query degrades to
/// its documented default when the plugin is missing (desktop, tests).
final class WhisperDeviceModelStorePlatform implements ModelStorePlatform {
  /// Creates the adapter over [channel] (a fresh [WhisperDeviceChannel] by default).
  WhisperDeviceModelStorePlatform([WhisperDeviceChannel? channel]) : _channel = channel ?? WhisperDeviceChannel();

  final WhisperDeviceChannel _channel;

  @override
  Future<int?> freeDiskBytes(String path) => _channel.freeDiskBytes(path);

  @override
  Future<bool> excludeFromBackup(String path) => _channel.excludeFromBackup(path);

  @override
  Future<int?> beginBackgroundTask(String name) => _channel.beginBackgroundTask(name);

  @override
  Future<void> endBackgroundTask(int id) => _channel.endBackgroundTask(id);

  @override
  Stream<WhisperDeviceEvent> get events => _channel.events;
}

/// Keeps the screen awake while a model downloads (ux.md §4.7).
abstract interface class DownloadWakelock {
  /// Acquires the wakelock.
  Future<void> acquire();

  /// Releases it. Always called, also after failures.
  Future<void> release();
}

/// A wakelock that does nothing (tests, desktop).
final class NoDownloadWakelock implements DownloadWakelock {
  /// Creates the no-op wakelock.
  const NoDownloadWakelock();

  @override
  Future<void> acquire() async {}

  @override
  Future<void> release() async {}
}
