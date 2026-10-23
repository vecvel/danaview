// OWNER: HOM-17
//
// The library root layout (ARCH v1.2 §5.2, V2-06): `library.db`, `files/<entryId>/<displayName>`,
// `imports/<jobId>.part`. The root is `Library/Application Support/DanaviewLibrary/` on iOS and
// macOS (never `Documents/`, which the Files app shows), `filesDir/library/` on Android and
// `<appSupport>/DanaviewLibrary/` on Windows and Linux; the app root resolves the platform
// directory and passes it in.

import 'package:path/path.dart' as p;

import '../model/ids.dart';

/// The platforms whose root directory name differs.
enum LibraryRootStyle {
  /// iOS, macOS, Windows, Linux: `<appSupport>/DanaviewLibrary`.
  appSupport,

  /// Android: `filesDir/library` (`getApplicationSupportDirectory()` is `filesDir` there).
  android,
}

/// The library root under [supportDir] for [style] (ARCH §5.2), joined with the host's separator
/// (a backslash on Windows); [context] picks another path style instead (tests).
String libraryRootIn(String supportDir, LibraryRootStyle style, {p.Context? context}) =>
    (context ?? p.context).join(supportDir, style == LibraryRootStyle.android ? 'library' : 'DanaviewLibrary');

/// Paths under one library root.
final class LibraryPaths {
  /// The layout under [root].
  LibraryPaths(String root) : root = p.normalize(p.absolute(root));

  /// Prefix of an entry directory staged for purge (`files/.purge-<entryId>`).
  static const String purgePrefix = '.purge-';

  /// The root directory.
  final String root;

  /// `library.db`.
  String get databasePath => p.join(root, 'library.db');

  /// `files/`.
  String get filesDir => p.join(root, 'files');

  /// `imports/`.
  String get importsDir => p.join(root, 'imports');

  /// `files/<id>/`.
  String entryDir(EntryId id) => p.join(filesDir, id.value);

  /// `files/<id>/<displayName>`.
  String entryFile(EntryId id, String displayName) => p.join(entryDir(id), displayName);

  /// `files/.purge-<id>/`.
  String purgeDir(EntryId id) => p.join(filesDir, '$purgePrefix${id.value}');

  /// The part file of import job [jobId], relative to the root (as `import_jobs.part_path` stores it).
  String relativePartPath(String jobId) => 'imports/$jobId.part';

  /// The absolute path of a root-relative [relative] path.
  String resolve(String relative) => p.join(root, p.joinAll(relative.split('/')));
}
