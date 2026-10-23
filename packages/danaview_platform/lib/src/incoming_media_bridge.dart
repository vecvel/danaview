// EXTENDED: HOM-21 (Open with Danaview, ARCH v1.2 §5.6: an optional [IncomingMediaBridge.interceptor]
// the Files & Media Home wiring installs, so incoming photos and documents are imported and opened
// in their viewer while videos, streams and danaview:// links keep the 1.0/1.1 play path
// unchanged. Without an interceptor (the default, and always with DANAVIEW_FILES_HOME off) the
// bridge behaves exactly as before.)

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Claims an incoming file or link before the player sees it: completes with true when it handled
/// [media] (it is then not emitted on [IncomingMediaBridge.onMediaOpened] nor returned by
/// [IncomingMediaBridge.getInitialMedia]), false to let the player have it.
typedef IncomingMediaInterceptor = Future<bool> Function(String media);

/// Bridges incoming file open requests and URL intents from native platforms (Android, iOS, macOS, Windows, Linux).
class IncomingMediaBridge {
  IncomingMediaBridge._();

  static const MethodChannel _channel = MethodChannel('danaview/media_intent');
  static final StreamController<String> _mediaController = StreamController<String>.broadcast();
  static bool _initialized = false;
  static List<String> _launchArgs = const [];

  @visibleForTesting
  static String? mockInitialMedia;

  /// Sees every incoming value first (HOM-21); null (the default) passes everything to the player.
  /// Set by the app root before the first frame. A throwing interceptor passes the value on.
  static IncomingMediaInterceptor? interceptor;

  /// True when [interceptor] handled [media].
  static Future<bool> _claimed(String media) async {
    final claim = interceptor;
    if (claim == null) return false;
    try {
      return await claim(media);
    } catch (_) {
      return false;
    }
  }

  static Future<void> _dispatch(String media) async {
    if (await _claimed(media)) return;
    _mediaController.add(media);
  }

  /// Sets command line arguments received by the app entry point.
  static void setLaunchArgs(List<String> args) {
    _launchArgs = List.unmodifiable(args);
  }

  /// Broadcast stream that emits whenever an incoming file or stream URL is opened
  /// while the app is running.
  static Stream<String> get onMediaOpened {
    _ensureInitialized();
    return _mediaController.stream;
  }

  /// Simulates an incoming media event (for automated widget/unit tests).
  @visibleForTesting
  static void emitMockMedia(String media) {
    if (interceptor == null) {
      _mediaController.add(media);
    } else {
      unawaited(_dispatch(media));
    }
  }

  static void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onOpenMedia') {
        final arg = call.arguments;
        if (arg is String && arg.trim().isNotEmpty) {
          if (interceptor == null) {
            _mediaController.add(arg.trim());
          } else {
            unawaited(_dispatch(arg.trim()));
          }
        }
      }
    });
  }

  /// Returns the initial media URL or file path that the app was launched with, if any.
  static Future<String?> getInitialMedia() async {
    final initial = await _initialMedia();
    if (initial == null || !await _claimed(initial)) return initial;
    return null;
  }

  static Future<String?> _initialMedia() async {
    _ensureInitialized();

    if (mockInitialMedia != null) {
      final initial = mockInitialMedia;
      mockInitialMedia = null;
      return initial;
    }

    try {
      final initial = await _channel.invokeMethod<String>('getInitialMedia');
      if (initial != null && initial.trim().isNotEmpty) {
        return initial.trim();
      }
    } catch (e) {
      debugPrint('[IncomingMediaBridge] getInitialMedia error: $e');
    }

    // On desktop, check command-line launch arguments
    if (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      for (final arg in _launchArgs) {
        final trimmed = arg.trim();
        if (trimmed.isEmpty || trimmed.startsWith('-')) continue;
        if (File(trimmed).existsSync() ||
            trimmed.startsWith('file://') ||
            trimmed.startsWith('http://') ||
            trimmed.startsWith('https://') ||
            trimmed.startsWith('danaview://')) {
          return trimmed;
        }
      }
    }
    return null;
  }
}
