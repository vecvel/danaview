// OWNER: API-01
//
// Engine configuration (ARCH §12.1). Roots come from `StoreRoots` (core) via EditorBootstrap.

import 'package:meta/meta.dart';

/// Directories the engine may write to (Dart-supplied, ARCH §20.1).
@immutable
final class EditorEngineConfig {
  /// Creates a config.
  const EditorEngineConfig({required this.cacheRoot, required this.supportRoot});

  /// `<cache>/danaview/editor` (thumbs, waves, proxies, sprites, looks, work, engine).
  final String cacheRoot;

  /// `<support>/danaview/editor` (derived renditions, project assets written by jobs).
  final String supportRoot;

  @override
  bool operator ==(Object other) => other is EditorEngineConfig && other.cacheRoot == cacheRoot && other.supportRoot == supportRoot;

  @override
  int get hashCode => Object.hash(cacheRoot, supportRoot);
}
