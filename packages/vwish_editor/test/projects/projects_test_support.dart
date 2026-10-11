// OWNER: UX-05
//
// Fixtures for the Projects tests: projects with chosen names, times and canvases, and a fake
// repository whose summaries can carry posters, sizes, missing media, recovery and health.

import 'dart:async';

import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/store.dart';

import '../support/support.dart';

/// "Now" for the Projects tests (the fake repository's clock is 12:00 the same day).
final DateTime projectsNow = DateTime.utc(2026, 10, 8, 14);

/// A project named [name], last changed at [updatedAt].
EditProject projectNamed(
  String name, {
  DateTime? updatedAt,
  String? id,
  AspectRatio aspect = AspectRatio.landscape16x9,
}) {
  final at = updatedAt ?? DateTime.utc(2026, 10, 8, 12);
  return EditProject(
    id: ProjectId(id ?? 'pr_${name.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '_')}'),
    meta: ProjectMeta(name: name, createdAt: at, updatedAt: at),
    timeline: Timeline(settings: ProjectSettings(canvas: CanvasSpec(aspect: aspect))),
  );
}

/// What a summary should show beyond the project itself.
final class SummaryExtras {
  /// Creates the extras.
  const SummaryExtras({
    this.missing = 0,
    this.recovery = false,
    this.health = ProjectHealth.ok,
    this.bytes = 0,
    this.thumbnailPath,
    this.duration,
  });

  /// Missing media count.
  final int missing;

  /// Recoverable journal.
  final bool recovery;

  /// Health.
  final ProjectHealth health;

  /// Bytes owned.
  final int bytes;

  /// Poster path.
  final String? thumbnailPath;

  /// Duration override.
  final TimeUs? duration;
}

/// A fake repository with per-project summary extras and a scriptable listing failure.
class ProjectsRepository extends FakeProjectRepository {
  /// Extras by project id.
  final Map<ProjectId, SummaryExtras> extras = {};

  /// When set, `watchSummaries` fails with it (once).
  Object? failListing;

  /// When set, `watchSummaries` waits for it before the first list.
  Completer<void>? listingGate;

  /// Seeds [project] with [extra].
  ProjectId add(EditProject project, [SummaryExtras extra = const SummaryExtras()]) {
    extras[project.id] = extra;
    return seed(project);
  }

  @override
  ProjectSummary summaryOf(EditProject project) {
    final base = super.summaryOf(project);
    final x = extras[project.id];
    if (x == null) return base;
    return ProjectSummary(
      id: base.id,
      name: base.name,
      updatedAt: base.updatedAt,
      duration: x.duration ?? base.duration,
      aspect: base.aspect,
      thumbnailPath: x.thumbnailPath,
      missingMediaCount: x.missing,
      hasRecovery: x.recovery || base.hasRecovery,
      bytesOwned: x.bytes,
      health: x.health,
    );
  }

  @override
  Stream<List<ProjectSummary>> watchSummaries() async* {
    final failure = failListing;
    if (failure != null) {
      failListing = null;
      calls.add('watchSummaries');
      throw failure;
    }
    final gate = listingGate;
    if (gate != null) await gate.future;
    yield* super.watchSummaries();
  }
}
