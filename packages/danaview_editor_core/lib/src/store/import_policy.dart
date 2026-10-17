// OWNER: CORE-27
//
// The import policy of ARCH §9.1 (D-13): for each picked item, where its bytes live afterwards
// and who owns them. Pure decision logic; `FileMediaPoolService` (media_pool_service.dart)
// carries the decision out against the `MediaAccessPort`, the `ManagedStore` and the deletion
// guard. Originals are never touched: a route either references the user's file (bookmark,
// persisted URI grant, `Documents`-relative path, desktop path) or copies it into the editor
// roots; only app-owned temporary files (`work/picks/`, `work/drops/`) may be moved, and only when
// `OwnedFileDeleter.canConsume` agrees at run time.
//
// | Source                                   | Route                 | Ownership    |
// |------------------------------------------|-----------------------|--------------|
// | iOS Photos (native clone in work/picks/) | managedCopy (move)    | managedCopy  |
// | iOS Files / player in-place URL          | bookmark              | external     |
// | Android Photo Picker / SAF (content://)  | persistedGrant¹       | external     |
// | file under Documents (player, library)   | documentsReference    | external     |
// | Android incoming cache copy (player)     | managedCopy (copy)²   | managedCopy  |
// | external drop (work/drops/ or URI)       | managedCopy           | managedCopy  |
// | `.cube` LUT                              | projectLut (+ .vlut)  | projectOwned |
// | voice recording / freeze still           | projectRecording/Still| projectOwned |
// | desktop path                             | fileReference         | external     |
//
// ¹ falls back to a managed copy when fewer than [ImportPolicy.minGrantBudget] grants remain or
//   the URI is not persistable. ² after a free-space preflight of size + [ImportPolicy.freeSpaceMarginBytes].

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../model/pool/media_asset.dart';
import '../model/pool/picked_media.dart';
import 'store_roots.dart';

/// The platform whose import rules apply.
enum ImportPlatform {
  /// iOS / iPadOS.
  ios,

  /// Android.
  android,

  /// Desktop (later): plain path references.
  desktop,
}

/// Where a picked item's bytes end up (ARCH §9.1).
enum ImportRoute {
  /// Content-addressed copy under `media/` (moved when it is an app-owned temporary file).
  managedCopy,

  /// iOS security-scoped bookmark made by the port (`MediaAccessPort.persist`).
  bookmark,

  /// Android persisted read grant (`MediaAccessPort.persist`), managed copy as fallback.
  persistedGrant,

  /// `AppRelativeLocator(documents, rel)`: a file of the app's own library.
  documentsReference,

  /// `FileLocator(path)` (desktop only).
  fileReference,

  /// `.cube` copied into the project bundle plus its `.vlut` (CORE-21).
  projectLut,

  /// Voice recording kept in the project bundle (`assets/recordings/`).
  projectRecording,

  /// Freeze-frame still kept in the project bundle (`assets/stills/`).
  projectStill,
}

/// One routing decision.
@immutable
final class ImportDecision {
  /// Creates a decision.
  const ImportDecision(this.route, {this.sourcePath, this.contentUri, this.temporary = false});

  /// The route.
  final ImportRoute route;

  /// Absolute path of the picked file when it is a plain file, else null.
  final String? sourcePath;

  /// The `content://` URI when the pick is one, else null.
  final String? contentUri;

  /// Whether the source is an app-owned temporary copy that may be moved (still subject to
  /// `OwnedFileDeleter.canConsume` at run time).
  final bool temporary;

  /// Ownership of the resulting asset (before a grant fallback turns a grant into a copy).
  MediaOwnership get ownership => switch (route) {
        ImportRoute.managedCopy => MediaOwnership.managedCopy,
        ImportRoute.bookmark ||
        ImportRoute.persistedGrant ||
        ImportRoute.documentsReference ||
        ImportRoute.fileReference =>
          MediaOwnership.external,
        ImportRoute.projectLut || ImportRoute.projectRecording || ImportRoute.projectStill => MediaOwnership.projectOwned,
      };

  @override
  bool operator ==(Object other) =>
      other is ImportDecision &&
      other.route == route &&
      other.sourcePath == sourcePath &&
      other.contentUri == contentUri &&
      other.temporary == temporary;

  @override
  int get hashCode => Object.hash(route, sourcePath, contentUri, temporary);

  @override
  String toString() => 'ImportDecision(${route.name}${temporary ? ', temporary' : ''})';
}

/// The D-13 import policy for one platform.
@immutable
final class ImportPolicy {
  /// Creates the policy for [platform] over [roots].
  const ImportPolicy({required this.platform, required this.roots});

  /// Fewer remaining persisted grants than this → managed copy instead (Android, D-13).
  static const int minGrantBudget = 32;

  /// Free space required on top of the file size before a copy (ARCH §9.1).
  static const int freeSpaceMarginBytes = 64 * 1024 * 1024;

  /// Platform rules in force.
  final ImportPlatform platform;

  /// App roots (to recognise `Documents` files and app-owned temporary copies).
  final StoreRoots roots;

  /// Whether a grant fallback applies with [remainingGrants] left.
  static bool grantBudgetExhausted(int remainingGrants) => remainingGrants < minGrantBudget;

  /// Whether [picked] is a colour lookup table (`.cube`).
  static bool isLut(PickedMedia picked) =>
      _extensionOf(picked.displayName) == '.cube' || _extensionOf(_lastSegment(picked.uri)) == '.cube';

  /// The absolute path behind [uri] (`file://` URI or absolute path), or null for other schemes.
  static String? pathOf(String uri) {
    if (uri.startsWith('/')) return p.normalize(uri);
    final parsed = Uri.tryParse(uri);
    if (parsed == null || parsed.scheme != 'file') return null;
    try {
      return p.normalize(parsed.toFilePath());
    } on UnsupportedError {
      return null;
    }
  }

  /// Decides how [picked] is stored.
  ImportDecision decide(PickedMedia picked) {
    final path = pathOf(picked.uri);
    final content = picked.uri.startsWith('content://') ? picked.uri : null;

    // Project-owned kinds first: they never reference the original.
    if (picked.origin == MediaOrigin.imported || isLut(picked)) {
      return ImportDecision(ImportRoute.projectLut, sourcePath: path, contentUri: content, temporary: _isTemp(picked, path));
    }
    if (picked.origin == MediaOrigin.recorded) {
      return ImportDecision(ImportRoute.projectRecording, sourcePath: path, contentUri: content, temporary: _isTemp(picked, path));
    }
    if (picked.origin == MediaOrigin.derived) {
      return ImportDecision(ImportRoute.projectStill, sourcePath: path, contentUri: content, temporary: _isTemp(picked, path));
    }

    if (content != null) {
      // A dropped URI carries only a temporary grant: copy it. Picker/SAF URIs get a persisted
      // grant (with the managed-copy fallback decided at run time from the grant budget).
      if (picked.origin == MediaOrigin.drop) return ImportDecision(ImportRoute.managedCopy, contentUri: content);
      return ImportDecision(ImportRoute.persistedGrant, contentUri: content);
    }
    if (path == null) {
      // Unknown scheme: only a copy made by the platform side could be used.
      return ImportDecision(ImportRoute.managedCopy, contentUri: picked.uri);
    }

    final temp = _isTemp(picked, path);
    if (temp || picked.origin == MediaOrigin.drop) {
      return ImportDecision(ImportRoute.managedCopy, sourcePath: path, temporary: temp);
    }
    if (_inside(roots.documents, path)) {
      return ImportDecision(ImportRoute.documentsReference, sourcePath: path);
    }
    return switch (platform) {
      // Photos picks are native clones (temporary); anything else from iOS is opened in place.
      ImportPlatform.ios => picked.origin == MediaOrigin.photos
          ? ImportDecision(ImportRoute.managedCopy, sourcePath: path)
          : ImportDecision(ImportRoute.bookmark, sourcePath: path),
      // Android plain paths are the player's incoming cache copies (purgeable): copy them.
      ImportPlatform.android => ImportDecision(ImportRoute.managedCopy, sourcePath: path),
      ImportPlatform.desktop => ImportDecision(ImportRoute.fileReference, sourcePath: path),
    };
  }

  /// App-owned temporary copies: flagged by the picker, or living under `work/picks|drops`.
  bool _isTemp(PickedMedia picked, String? path) {
    if (path == null) return false;
    if (_inside(roots.picksDir, path) || _inside(roots.dropsDir, path)) return true;
    return picked.isTemporaryCopy && _inside(roots.workDir, path);
  }

  static bool _inside(String dir, String path) => p.isWithin(p.normalize(dir), p.normalize(path));

  static String _extensionOf(String name) => p.extension(name).toLowerCase();

  static String _lastSegment(String uri) {
    final i = uri.lastIndexOf('/');
    return i < 0 ? uri : uri.substring(i + 1);
  }
}
