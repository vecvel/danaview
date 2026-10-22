// OWNER: CORE-24
//
// Storage roots (ARCH §8.1). Built by `EditorBootstrap` (INT-02) from danaview_data `AppStorage`:
// support = getApplicationSupportDirectory(), cache = getTemporaryDirectory(), documents = the
// user's "On This Device" library. Editor files never go into `documents` (D-44).

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../model/pool/media_locator.dart';

/// The three app roots plus every editor directory derived from them.
@immutable
final class StoreRoots {
  /// Creates roots from absolute directory paths.
  const StoreRoots({required this.support, required this.cache, required this.documents});

  /// Application Support directory (absolute).
  final String support;

  /// Caches directory (absolute, purgeable).
  final String cache;

  /// Documents directory (absolute). Treated as originals: read-only to the editor except through
  /// `DocumentsExportWriter` into `Documents/Exports/`.
  final String documents;

  /// `<support>/danaview/editor` (projects, managed media, derived renditions, trash).
  String get editorSupport => p.join(support, 'danaview', 'editor');

  /// `<cache>/danaview/editor` (thumbs, waves, proxies, sprites, looks, work, engine).
  String get editorCache => p.join(cache, 'danaview', 'editor');

  /// `<support>/danaview/speech` (models, transcripts, jobs, work; all backup-excluded).
  String get speechSupport => p.join(support, 'danaview', 'speech');

  /// `<support>/danaview/editor/projects`.
  String get projectsDir => p.join(editorSupport, 'projects');

  /// Bundle directory of one project.
  String projectDir(String projectId) => p.join(projectsDir, projectId);

  /// `<support>/danaview/editor/media` (content-addressed managed copies; backup-excluded).
  String get mediaDir => p.join(editorSupport, 'media');

  /// `<support>/danaview/editor/derived` (reversed renditions; backup-excluded).
  String get derivedDir => p.join(editorSupport, 'derived');

  /// `<support>/danaview/editor/trash` (staged deletes).
  String get trashDir => p.join(editorSupport, 'trash');

  /// `<support>/danaview/editor/exports`: running and kept export outputs (`export-<token>.mp4`)
  /// and their caption side files (QA-05 D8). Not under the cache root, because the system purges
  /// that under low storage while a job still writes there. Backup-excluded (Android rules cover
  /// `files/danaview/editor`; iOS through `MediaAccessPort.excludeFromBackup`).
  String get exportsDir => p.join(editorSupport, 'exports');

  /// `<cache>/danaview/editor/work` (picks, drops and the engines' own temporary job files; the
  /// engines require `materializePick` targets inside it). Purgeable: recreate it before use.
  String get workDir => p.join(editorCache, 'work');

  /// `<cache>/danaview/editor/work/picks`: native clones of picker results (ARCH §9.1).
  String get picksDir => p.join(workDir, 'picks');

  /// `<cache>/danaview/editor/work/drops`: copies of externally dropped files (D-18).
  String get dropsDir => p.join(workDir, 'drops');

  /// `Documents/Exports` (the only directory `DocumentsExportWriter` writes to).
  String get documentsExportsDir => p.join(documents, 'Exports');

  /// Absolute path of an [AppRelativeLocator] under these roots.
  String resolve(AppRelativeLocator locator) => p.join(rootOf(locator.root), locator.relPath);

  /// The absolute root directory for [root].
  String rootOf(AppRoot root) => switch (root) {
        AppRoot.documents => documents,
        AppRoot.support => support,
        AppRoot.cache => cache,
      };

  /// Relativizes [absolutePath] against the app roots, or null when it lies outside all of them.
  /// Persisted strings never hold absolute app-container paths (ARCH §8.2).
  AppRelativeLocator? relativize(String absolutePath) {
    final normalized = p.normalize(absolutePath);
    for (final root in AppRoot.values) {
      final base = p.normalize(rootOf(root));
      if (p.isWithin(base, normalized)) {
        return AppRelativeLocator(root, p.posix.joinAll(p.split(p.relative(normalized, from: base))));
      }
    }
    return null;
  }

  /// Whether [path] lies inside the editor or speech roots (where the editor may write or delete).
  bool isInsideEditorRoots(String path) {
    final n = p.normalize(path);
    return p.isWithin(editorSupport, n) || p.isWithin(editorCache, n) || p.isWithin(speechSupport, n);
  }
}
