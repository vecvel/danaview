// OWNER: CORE-25
//
// Storage usage of the editor (Settings › Storage contributors, ARCH §17.10).

import 'package:meta/meta.dart';

/// Bytes used by the editor, split by what the user can do about them.
@immutable
final class ProjectStorageReport {
  /// Creates a report.
  const ProjectStorageReport({
    this.projectCount = 0,
    this.projectBundlesBytes = 0,
    this.managedMediaBytes = 0,
    this.derivedBytes = 0,
    this.cacheBytes = 0,
  });

  /// Number of projects.
  final int projectCount;

  /// Project bundles (documents, journals, recordings, stills, LUTs, posters).
  final int projectBundlesBytes;

  /// Managed copies under `media/` (shared by projects).
  final int managedMediaBytes;

  /// Reversed renditions under `derived/`.
  final int derivedBytes;

  /// Regenerable caches under `<cache>/danaview/editor` ("Clear editor cache").
  final int cacheBytes;

  /// Bytes that only deleting projects frees.
  int get projectsTotalBytes => projectBundlesBytes + managedMediaBytes + derivedBytes;

  @override
  bool operator ==(Object other) =>
      other is ProjectStorageReport &&
      other.projectCount == projectCount &&
      other.projectBundlesBytes == projectBundlesBytes &&
      other.managedMediaBytes == managedMediaBytes &&
      other.derivedBytes == derivedBytes &&
      other.cacheBytes == cacheBytes;

  @override
  int get hashCode => Object.hash(projectCount, projectBundlesBytes, managedMediaBytes, derivedBytes, cacheBytes);
}
