// OWNER: HOM-17
//
// Holders of library entries (ARCH v1.2 §5.3 `refs`, V2-08): an editor project or a `.dnphoto`
// recipe that uses a Danaview folder file. The delete warning ("Used in 2 projects") counts them;
// after a purge the rows go and the editor's v1.1 relink flow takes over.

/// The kind of a [RefHolder].
enum RefHolderKind {
  /// An editor project (`project:<projectId>`).
  project('project'),

  /// A still-photo recipe (`photo:<photoId>`).
  photo('photo');

  const RefHolderKind(this.prefix);

  /// The stored prefix (before the colon).
  final String prefix;
}

final RegExp _holderId = RegExp(r'^[A-Za-z0-9_.-]{1,128}$');

/// One holder string, `project:<id>` or `photo:<id>` (the `refs.holder` column).
extension type const RefHolder._(String value) {
  /// Parses a stored holder; throws [FormatException] when malformed.
  factory RefHolder.parse(String value) => tryParse(value) ?? (throw FormatException('malformed ref holder', value));

  /// [value] as a holder, or null when malformed.
  static RefHolder? tryParse(String value) {
    final colon = value.indexOf(':');
    if (colon < 0) return null;
    final prefix = value.substring(0, colon);
    if (!RefHolderKind.values.any((k) => k.prefix == prefix)) return null;
    return _holderId.hasMatch(value.substring(colon + 1)) ? RefHolder._(value) : null;
  }

  /// The holder for editor project [projectId].
  factory RefHolder.project(String projectId) => RefHolder.parse('project:$projectId');

  /// The holder for still-photo recipe [photoId].
  factory RefHolder.photo(String photoId) => RefHolder.parse('photo:$photoId');

  /// The holder kind.
  RefHolderKind get kind => RefHolderKind.values.firstWhere((k) => value.startsWith('${k.prefix}:'));

  /// The project or photo id.
  String get holderId => value.substring(value.indexOf(':') + 1);
}

/// What deleting some entries would break (V2-08's warning).
final class RefUsage {
  /// Counts of distinct holders.
  const RefUsage({required this.projects, required this.photos});

  /// No holder.
  static const RefUsage none = RefUsage(projects: 0, photos: 0);

  /// Distinct editor projects.
  final int projects;

  /// Distinct photo recipes.
  final int photos;

  /// True when nothing holds the entries.
  bool get isEmpty => projects == 0 && photos == 0;
}
