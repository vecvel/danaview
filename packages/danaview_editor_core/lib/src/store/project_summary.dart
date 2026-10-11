// OWNER: CORE-25
//
// What the Projects screen shows per project (ARCH §8.4). Read from `projects/*/meta.json`
// (rebuildable) without decoding the body.

import 'package:meta/meta.dart';

import '../ids/ids.dart';
import '../model/settings.dart';
import '../time/time.dart';

/// Health of a stored project.
enum ProjectHealth {
  /// Opens normally.
  ok,

  /// Saved by a newer app whose `minReader` is above this app (blocked, D-12).
  needsNewerApp,

  /// Saved by a newer app but readable: opens read-only (D-12).
  readOnlyNewer,

  /// No valid copy; "Restore last good version" is offered when a backup or journal exists.
  corrupt,
}

/// One row of the Projects list.
@immutable
final class ProjectSummary {
  /// Creates a summary.
  const ProjectSummary({
    required this.id,
    required this.name,
    required this.updatedAt,
    required this.duration,
    required this.aspect,
    this.thumbnailPath,
    this.missingMediaCount = 0,
    this.hasRecovery = false,
    this.bytesOwned = 0,
    this.health = ProjectHealth.ok,
  });

  /// Project id.
  final ProjectId id;

  /// Name.
  final String name;

  /// Last change (UTC).
  final DateTime updatedAt;

  /// Timeline duration.
  final TimeUs duration;

  /// Canvas aspect.
  final AspectRatio aspect;

  /// Absolute poster path resolved at runtime from the bundle-relative name in `meta.json`
  /// (never persisted as an absolute path, ARCH §8.2).
  final String? thumbnailPath;

  /// Assets currently missing or inaccessible.
  final int missingMediaCount;

  /// Whether a newer journal can be restored (crash recovery).
  final bool hasRecovery;

  /// Bytes owned by this project (bundle + managed copies only it references).
  final int bytesOwned;

  /// Health.
  final ProjectHealth health;

  @override
  bool operator ==(Object other) =>
      other is ProjectSummary &&
      other.id == id &&
      other.name == name &&
      other.updatedAt == updatedAt &&
      other.duration == duration &&
      other.aspect == aspect &&
      other.thumbnailPath == thumbnailPath &&
      other.missingMediaCount == missingMediaCount &&
      other.hasRecovery == hasRecovery &&
      other.bytesOwned == bytesOwned &&
      other.health == health;

  @override
  int get hashCode => Object.hash(
      id, name, updatedAt, duration, aspect, thumbnailPath, missingMediaCount, hasRecovery, bytesOwned, health);
}
