import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges incoming file open requests and URL intents from native platforms (Android, iOS, macOS, Windows, Linux).
class IncomingMediaBridge {
  IncomingMediaBridge._();

  static const MethodChannel _channel = MethodChannel('danaview/media_intent');
  static final StreamController<String> _mediaController = StreamController<String>.broadcast();
  static bool _initialized = false;
  static List<String> _launchArgs = const [];

  @visibleForTesting
  static String? mockInitialMedia;

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
    _mediaController.add(media);
  }

  static void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onOpenMedia') {
        final arg = call.arguments;
        if (arg is String && arg.trim().isNotEmpty) {
          _mediaController.add(arg.trim());
        }
      }
    });
  }

  /// Returns the initial media URL or file path that the app was launched with, if any.
  static Future<String?> getInitialMedia() async {
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
