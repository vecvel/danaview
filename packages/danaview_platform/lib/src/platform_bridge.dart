import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

class PlatformBridge {
  static bool get isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);
  static bool get isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Initialize window manager on desktop platforms
  static Future<void> initializeWindow() async {
    if (isDesktop) {
      try {
        await windowManager.ensureInitialized();
        const windowOptions = WindowOptions(
          size: Size(1120, 700),
          minimumSize: Size(480, 320),
          center: true,
          backgroundColor: Colors.transparent,
          skipTaskbar: false,
          titleBarStyle: TitleBarStyle.hidden,
          title: 'Danaview',
        );
        await windowManager.waitUntilReadyToShow(windowOptions, () async {
          await windowManager.show();
          await windowManager.focus();
        });
      } catch (e) {
        debugPrint('[PlatformBridge] Window manager setup: $e');
      }
    }
  }

  /// Toggle Fullscreen
  static Future<void> setFullscreen(bool fullscreen) async {
    if (isDesktop) {
      try {
        await windowManager.setFullScreen(fullscreen);
      } catch (_) {}
    }
  }

  /// Reports fullscreen changes, including ones made through the OS (e.g. the macOS green
  /// button). Returns a function that stops listening.
  static VoidCallback listenFullscreen(ValueChanged<bool> onChanged) {
    if (!isDesktop) return () {};
    final listener = _FullscreenListener(onChanged);
    try {
      windowManager.addListener(listener);
    } catch (_) {
      return () {};
    }
    return () => windowManager.removeListener(listener);
  }

  static const EventChannel _deviceOrientationChannel = EventChannel('danaview/device_orientation');

  /// How the phone is physically held, as the interface orientation that would show it upright.
  /// iOS only (the Runner's AppDelegate provides it); stays silent while the rotation lock is on.
  static Stream<DeviceOrientation> get deviceOrientations => _deviceOrientationChannel
      .receiveBroadcastStream()
      .map((event) => switch (event) {
            'portraitUp' => DeviceOrientation.portraitUp,
            'portraitDown' => DeviceOrientation.portraitDown,
            'landscapeLeft' => DeviceOrientation.landscapeLeft,
            'landscapeRight' => DeviceOrientation.landscapeRight,
            _ => null,
          })
      .where((orientation) => orientation != null)
      .cast<DeviceOrientation>();

  /// Toggle Always on Top
  static Future<void> setAlwaysOnTop(bool alwaysOnTop) async {
    if (isDesktop) {
      try {
        await windowManager.setAlwaysOnTop(alwaysOnTop);
      } catch (_) {}
    }
  }

  /// Prevent OS from sleeping while video is playing
  static Future<void> setSleepInhibited(bool inhibit) async {
    try {
      if (inhibit) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {}
  }

  static const List<String> videoExtensions = <String>[
    'mkv', 'mp4', 'm4v', 'mov', 'avi', 'webm', 'ts', 'm2ts', 'mts',
    'flv', 'wmv', 'ogv', '3gp', 'mpg', 'mpeg',
  ];

  static const List<String> subtitleExtensions = <String>['srt', 'ass', 'ssa', 'vtt', 'sub'];

  // iOS filters by UTI only; mkv/webm resolve through UTImportedTypeDeclarations in Info.plist.
  static const List<String> _videoTypeIdentifiers = <String>[
    'public.movie',
    'public.video',
    'public.audiovisual-content',
    'public.mpeg-4',
    'com.apple.quicktime-movie',
    'com.apple.m4v-video',
    'public.avi',
    'public.mpeg',
    'public.mpeg-2-transport-stream',
    'public.3gpp',
    'org.matroska.mkv',
    'org.webmproject.webm',
  ];

  /// Folder picking is only available on desktop; mobile pickers can't grant folder access.
  static bool get supportsDirectoryPicking => isDesktop;

  /// Open single or multiple video files using native file picker.
  ///
  /// Returns an empty list when cancelled. On iOS/Android the paths are temporary copies
  /// inside the app container; persist them via `LibraryStorage.importPickedFiles`.
  static Future<List<String>> pickVideoFiles() async {
    const typeGroup = XTypeGroup(
      label: 'Videos',
      extensions: videoExtensions,
      mimeTypes: <String>['video/*'],
      uniformTypeIdentifiers: _videoTypeIdentifiers,
    );
    final files = await openFiles(acceptedTypeGroups: const <XTypeGroup>[typeGroup]);
    return files.map((f) => f.path).toList();
  }

  /// Pick single directory for folder playback / library scanning.
  /// Returns null when cancelled or when [supportsDirectoryPicking] is false.
  static Future<String?> pickDirectory() async {
    if (!supportsDirectoryPicking) return null;
    try {
      return await getDirectoryPath();
    } on UnimplementedError {
      return null;
    }
  }

  /// Pick subtitle file; null when cancelled or (on iOS) when a non-subtitle file is chosen.
  static Future<String?> pickSubtitleFile() async {
    final file = await openFile(acceptedTypeGroups: <XTypeGroup>[_subtitleTypeGroup()]);
    if (file == null) return null;
    if (!kIsWeb && Platform.isIOS) {
      final name = file.path.toLowerCase();
      if (!subtitleExtensions.any((ext) => name.endsWith('.$ext'))) return null;
    }
    return file.path;
  }

  // Most subtitle formats have no system UTI/MIME type: iOS gets public.data (filtered above),
  // Android gets any file because its picker may rename unknown extensions and mpv probes content.
  static XTypeGroup _subtitleTypeGroup() {
    if (!kIsWeb && Platform.isIOS) {
      return const XTypeGroup(label: 'Subtitles', uniformTypeIdentifiers: <String>['public.data']);
    }
    if (!kIsWeb && Platform.isAndroid) return const XTypeGroup(label: 'Subtitles');
    return const XTypeGroup(label: 'Subtitles', extensions: subtitleExtensions);
  }
}

class _FullscreenListener with WindowListener {
  _FullscreenListener(this.onChanged);

  final ValueChanged<bool> onChanged;

  @override
  void onWindowEnterFullScreen() => onChanged(true);

  @override
  void onWindowLeaveFullScreen() => onChanged(false);
}
