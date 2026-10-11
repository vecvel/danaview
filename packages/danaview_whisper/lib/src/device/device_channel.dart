// OWNER: AI-06
//
// Dart side of the plugin's method + event channel `danaview_whisper/device` (BUILD_PLAN AI-06,
// ai.md §4.8). Every call degrades instead of throwing: no plugin (desktop, tests), a
// `PlatformException`, or a malformed reply returns the conservative default documented on the
// method, so the governor and the downloader keep working with less information.
//
// The strings below are mirrored by `DanaviewWhisperPlugin.swift` and `DanaviewWhisperPlugin.kt`; a test
// (test/device/channel_contract_test.dart) keeps the three in sync.

import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';

import 'device_events.dart';
import 'device_profile.dart';

/// Method channel name shared with the native plugins.
const String whisperDeviceMethodChannel = 'danaview_whisper/device';

/// Event channel name shared with the native plugins.
const String whisperDeviceEventChannel = 'danaview_whisper/device/events';

/// Method names handled by the native plugins.
abstract final class WhisperDeviceMethods {
  /// `deviceProfile` -> map.
  static const String deviceProfile = 'deviceProfile';

  /// `availableMemory` -> int bytes.
  static const String availableMemory = 'availableMemory';

  /// `freeDiskBytes(path)` -> int bytes.
  static const String freeDiskBytes = 'freeDiskBytes';

  /// `isNetworkMetered` -> bool.
  static const String isNetworkMetered = 'isNetworkMetered';

  /// `excludeFromBackup(path)` -> bool (verified by read-back on iOS).
  static const String excludeFromBackup = 'excludeFromBackup';

  /// `beginBackgroundTask(name)` -> int id (0 = none).
  static const String beginBackgroundTask = 'beginBackgroundTask';

  /// `endBackgroundTask(id)`.
  static const String endBackgroundTask = 'endBackgroundTask';
}

/// Device profile, resource queries and events for the speech pipeline.
class WhisperDeviceChannel {
  /// Creates the channel. The plugin only exists on iOS and Android, so on other platforms every
  /// query returns its default without touching a channel and [events] is empty. Tests inject
  /// [method] / [events] (which enables the channel on any host) or force [enabled].
  WhisperDeviceChannel({MethodChannel? method, EventChannel? events, bool? enabled})
      : _method = method ?? const MethodChannel(whisperDeviceMethodChannel),
        _events = events ?? const EventChannel(whisperDeviceEventChannel),
        _enabled = enabled ?? (method != null || events != null || _pluginPlatform);

  final MethodChannel _method;
  final EventChannel _events;
  final bool _enabled;

  static bool get _pluginPlatform =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);
  Stream<WhisperDeviceEvent>? _stream;

  /// The device snapshot; [WhisperDeviceProfile.unknown] when the plugin is unavailable or the
  /// reply is malformed.
  Future<WhisperDeviceProfile> deviceProfile() async {
    final raw = await _invoke<Object?>(WhisperDeviceMethods.deviceProfile);
    return WhisperDeviceProfile.fromMap(raw);
  }

  /// Memory the app may still allocate (iOS `os_proc_available_memory`, Android
  /// `availMem - threshold`), or null when unknown. Null and zero both mean "unknown, assume OK".
  Future<int?> availableMemory() async {
    final raw = await _invoke<Object?>(WhisperDeviceMethods.availableMemory);
    return _positiveInt(raw);
  }

  /// Free bytes on the volume holding [path], or null when unknown.
  Future<int?> freeDiskBytes(String path) async {
    final raw = await _invoke<Object?>(WhisperDeviceMethods.freeDiskBytes, path);
    return _positiveInt(raw);
  }

  /// Whether the active network is metered, expensive or constrained; false when unknown.
  Future<bool> isNetworkMetered() async => (await _invoke<Object?>(WhisperDeviceMethods.isNetworkMetered)) == true;

  /// Excludes [path] from backups. iOS sets `isExcludedFromBackup` and reads it back; Android
  /// relies on the manifest rules and reports true. False when the path could not be excluded.
  Future<bool> excludeFromBackup(String path) async =>
      (await _invoke<Object?>(WhisperDeviceMethods.excludeFromBackup, path)) == true;

  /// Starts an iOS background task so a download can continue briefly; null on Android or when
  /// the OS refuses. Pair with [endBackgroundTask] and listen for [BackgroundTaskExpiring].
  Future<int?> beginBackgroundTask(String name) async =>
      _positiveInt(await _invoke<Object?>(WhisperDeviceMethods.beginBackgroundTask, name));

  /// Ends the task returned by [beginBackgroundTask].
  Future<void> endBackgroundTask(int id) async {
    await _invoke<Object?>(WhisperDeviceMethods.endBackgroundTask, id);
  }

  /// Thermal, memory-warning, low-power, lifecycle and background-task events. Broadcast;
  /// malformed events and stream errors are dropped, never surfaced. Empty without the plugin.
  Stream<WhisperDeviceEvent> get events => _stream ??= _enabled ? _buildStream() : const Stream<WhisperDeviceEvent>.empty();

  Stream<WhisperDeviceEvent> _buildStream() {
    late final StreamController<WhisperDeviceEvent> controller;
    StreamSubscription<Object?>? sub;
    controller = StreamController<WhisperDeviceEvent>.broadcast(
      onListen: () {
        sub = _events.receiveBroadcastStream().listen(
          (raw) {
            final event = WhisperDeviceEvent.tryParse(raw);
            if (event != null) controller.add(event);
          },
          onError: (Object _) {},
          cancelOnError: false,
        );
      },
      onCancel: () async {
        await sub?.cancel();
        sub = null;
      },
    );
    return controller.stream;
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    if (!_enabled) return null;
    try {
      return await _method.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static int? _positiveInt(Object? v) {
    final n = v is int ? v : (v is double && v.isFinite ? v.toInt() : null);
    return n != null && n > 0 ? n : null;
  }
}
