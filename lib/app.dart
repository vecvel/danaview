import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_platform/danaview_platform.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'router/app_router.dart';

class DanaviewApp extends ConsumerStatefulWidget {
  const DanaviewApp({super.key});

  @override
  ConsumerState<DanaviewApp> createState() => _DanaviewAppState();
}

class _DanaviewAppState extends ConsumerState<DanaviewApp> {
  late final GoRouter _router = createAppRouter();
  StreamSubscription<String>? _mediaSub;
  String? _lastOpenedMedia;
  DateTime? _lastOpenedAt;

  @override
  void initState() {
    super.initState();
    _mediaSub = IncomingMediaBridge.onMediaOpened.listen(_handleIncomingMedia);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkInitialMedia());
  }

  @override
  void dispose() {
    _mediaSub?.cancel();
    _router.dispose();
    super.dispose();
  }

  Future<void> _checkInitialMedia() async {
    final media = await IncomingMediaBridge.getInitialMedia();
    if (media != null && mounted) {
      await _handleIncomingMedia(media);
    }
  }

  Future<void> _handleIncomingMedia(String raw) async {
    final now = DateTime.now();
    if (_lastOpenedMedia == raw &&
        _lastOpenedAt != null &&
        now.difference(_lastOpenedAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastOpenedMedia = raw;
    _lastOpenedAt = now;

    try {
      final mediaRef = await _resolveMedia(raw);
      if (mediaRef == null || !mounted) return;

      final queue = ref.read(queueControllerProvider.notifier);
      await queue.playFrom([mediaRef]);

      if (!mounted) return;
      final uri = _router.routerDelegate.currentConfiguration.uri.toString();
      if (uri != '/player') {
        _router.push('/player');
      }
    } catch (e) {
      debugPrint('[DanaviewApp] Failed to play incoming media: $e');
    }
  }

  Future<MediaRef?> _resolveMedia(String raw) async {
    var pathOrUrl = raw.trim();
    if (pathOrUrl.isEmpty) return null;

    // Custom scheme: danaview://
    if (pathOrUrl.startsWith('danaview://')) {
      final uri = Uri.tryParse(pathOrUrl);
      if (uri != null) {
        final queryUrl = uri.queryParameters['url'];
        if (queryUrl != null && queryUrl.isNotEmpty) {
          pathOrUrl = queryUrl;
        } else {
          final stripped = pathOrUrl.substring('danaview://'.length);
          if (stripped.startsWith('http://') ||
              stripped.startsWith('https://') ||
              stripped.startsWith('/')) {
            pathOrUrl = stripped;
          }
        }
      }
    }

    // file:// URI
    if (pathOrUrl.startsWith('file://')) {
      final fileUri = Uri.tryParse(pathOrUrl);
      if (fileUri != null) {
        pathOrUrl = fileUri.toFilePath();
      }
    }

    // Remote network URLs
    final parsedRemote = MediaUrl.tryParse(pathOrUrl);
    if (parsedRemote != null && parsedRemote.isRemote) {
      return parsedRemote;
    }

    // Local file path
    String localPath = pathOrUrl;
    if (PlatformBridge.isMobile) {
      try {
        final imported = await LibraryStorage().importPickedFiles([localPath]);
        if (imported.isNotEmpty) {
          localPath = imported.first;
        }
      } catch (e) {
        debugPrint('[DanaviewApp] LibraryStorage import error: $e');
      }
    }

    return LibraryRepository.mediaRefForFile(localPath);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Danaview',
      debugShowCheckedModeBanner: false,
      theme: DanaviewTheme.darkTheme,
      routerConfig: _router,
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: 0.85,
        maxScaleFactor: 1.35,
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
