// OWNER: CORE-03
//
// The project root (ARCH §6.1). The timeline is history-tracked (undo stores snapshots of it);
// the pool and the view state are not.

import 'package:meta/meta.dart';

import '../ids/ids.dart';
import '../time/time.dart';
import 'marker.dart';
import 'pool/media_pool.dart';
import 'project_index.dart';
import 'settings.dart';
import 'timeline.dart';
import 'track.dart';
import 'view_state.dart';

/// How a project was started. Persisted (no absolute paths, ARCH §8.2).
@immutable
sealed class ProjectOrigin {
  const ProjectOrigin();

  /// Created empty or from picked media in the Projects screen.
  static const ProjectOrigin projects = ProjectsOrigin();
}

/// Created from the Projects screen (empty or from picked media).
final class ProjectsOrigin extends ProjectOrigin {
  /// Creates the origin.
  const ProjectsOrigin();

  @override
  bool operator ==(Object other) => other is ProjectsOrigin;

  @override
  int get hashCode => (ProjectsOrigin).hashCode;
}

/// Created by the player's Edit action (ARCH §17.1). `findUntouchedProjectFor` reuses a project
/// with this origin whose fingerprint matches and whose `editCount` is still 0.
final class FromPlayerOrigin extends ProjectOrigin {
  /// Creates the origin for the media identified by [quickHash].
  const FromPlayerOrigin({required this.quickHash, required this.sizeBytes, this.displayName = ''});

  /// `quickHash` of the played file (never its path).
  final String quickHash;

  /// Size of the played file in bytes.
  final int sizeBytes;

  /// File name shown in diagnostics (never a path).
  final String displayName;

  /// A copy with the given fields replaced.
  FromPlayerOrigin copyWith({String? quickHash, int? sizeBytes, String? displayName}) => FromPlayerOrigin(
        quickHash: quickHash ?? this.quickHash,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        displayName: displayName ?? this.displayName,
      );

  @override
  bool operator ==(Object other) =>
      other is FromPlayerOrigin &&
      other.quickHash == quickHash &&
      other.sizeBytes == sizeBytes &&
      other.displayName == displayName;

  @override
  int get hashCode => Object.hash(quickHash, sizeBytes, displayName);
}

/// Project metadata (not history-tracked).
@immutable
final class ProjectMeta {
  /// Creates metadata.
  const ProjectMeta({
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.origin = ProjectOrigin.projects,
    this.editCount = 0,
  });

  /// User-visible name, 1–80 characters after trim.
  final String name;

  /// Creation time (UTC).
  final DateTime createdAt;

  /// Time of the last committed change (UTC).
  final DateTime updatedAt;

  /// How the project was started.
  final ProjectOrigin origin;

  /// Number of committed history entries ever made; never decremented ("touched stays touched").
  final int editCount;

  /// A copy with the given fields replaced.
  ProjectMeta copyWith({String? name, DateTime? updatedAt, ProjectOrigin? origin, int? editCount}) => ProjectMeta(
        name: name ?? this.name,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        origin: origin ?? this.origin,
        editCount: editCount ?? this.editCount,
      );

  @override
  bool operator ==(Object other) =>
      other is ProjectMeta &&
      other.name == name &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt &&
      other.origin == origin &&
      other.editCount == editCount;

  @override
  int get hashCode => Object.hash(name, createdAt, updatedAt, origin, editCount);
}

/// An editing project: immutable and structurally shared between history snapshots.
@immutable
final class EditProject {
  /// Creates a project.
  EditProject({
    required this.id,
    required this.meta,
    required this.timeline,
    this.pool = MediaPool.empty,
    this.view = ViewState.initial,
    this.docRevision = 0,
  });

  /// Stable id.
  final ProjectId id;

  /// Metadata (name, dates, origin, edit count).
  final ProjectMeta meta;

  /// History-tracked subtree: settings, tracks, markers.
  final Timeline timeline;

  /// Media pool (outside undo snapshots, ARCH §7.3).
  final MediaPool pool;

  /// Persisted view state (playhead, zoom, toggles); never in history.
  final ViewState view;

  /// Incremented on every persisted change (commit, pool change, view change).
  final int docRevision;

  /// User-visible project name (ux.md §2.1).
  String get name => meta.name;

  /// Project settings.
  ProjectSettings get settings => timeline.settings;

  /// Tracks in canonical order.
  List<Track> get tracks => timeline.tracks;

  /// Markers sorted by time.
  List<Marker> get markers => timeline.markers;

  /// The media pool (alias of [pool]).
  MediaPool get media => pool;

  /// End of the last item over all tracks.
  TimeUs get duration => timeline.duration;

  /// Session-monotonic timeline revision stamp.
  int get revision => timeline.revision;

  /// Id lookups, built once per instance on first use.
  late final ProjectIndex index = ProjectIndex.build(timeline);

  /// A copy with the given fields replaced.
  EditProject copyWith({
    ProjectMeta? meta,
    Timeline? timeline,
    MediaPool? pool,
    ViewState? view,
    int? docRevision,
  }) =>
      EditProject(
        id: id,
        meta: meta ?? this.meta,
        timeline: timeline ?? this.timeline,
        pool: pool ?? this.pool,
        view: view ?? this.view,
        docRevision: docRevision ?? this.docRevision,
      );

  @override
  bool operator ==(Object other) =>
      other is EditProject &&
      other.id == id &&
      other.meta == meta &&
      other.timeline == timeline &&
      other.pool == pool &&
      other.view == view &&
      other.docRevision == docRevision;

  @override
  int get hashCode => Object.hash(id, meta, timeline, pool, view, docRevision);
}
