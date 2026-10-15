// OWNER: API-01
//
// Engine configuration (ARCH §12.1). Roots come from `StoreRoots` (core) via EditorBootstrap.
// INT-07 added the localized export notification texts handed to native with the roots.

import 'package:meta/meta.dart';

import 'export.dart';

/// Directories the engine may write to (Dart-supplied, ARCH §20.1).
@immutable
final class EditorEngineConfig {
  /// Creates a config.
  const EditorEngineConfig({
    required this.cacheRoot,
    required this.supportRoot,
    this.exportNotificationTexts = const ExportNotificationTexts(),
  });

  /// `<cache>/danaview/editor` (thumbs, waves, proxies, sprites, looks, work, engine).
  final String cacheRoot;

  /// `<support>/danaview/editor` (derived renditions, project assets written by jobs).
  final String supportRoot;

  /// Localized texts of the Android export notifications (INT-07; English by default).
  final ExportNotificationTexts exportNotificationTexts;

  @override
  bool operator ==(Object other) =>
      other is EditorEngineConfig &&
      other.cacheRoot == cacheRoot &&
      other.supportRoot == supportRoot &&
      other.exportNotificationTexts == exportNotificationTexts;

  @override
  int get hashCode => Object.hash(cacheRoot, supportRoot, exportNotificationTexts);
}
