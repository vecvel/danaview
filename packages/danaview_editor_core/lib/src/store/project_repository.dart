// OWNER: CORE-25
//
// The project store contract (ARCH §8.4). `FileProjectRepository` (CORE-25) implements it on
// disk with a writer isolate; `InMemoryProjectRepository` (CORE-25, `lib/testing.dart`) backs
// widget tests. Autosave, journal and recovery are CORE-26.
//
// Rules every implementation keeps:
// - Original media is never modified, moved, renamed or deleted (G2); deletes go through
//   `OwnedFileDeleter` only.
// - No persisted string holds an absolute app-container path (ARCH §8.2).
// - `open` never throws for content problems: it returns health and warnings (ARCH §19).

import 'package:meta/meta.dart';

import '../ids/ids.dart';
import '../model/pool/picked_media.dart';
import '../model/project.dart';
import '../model/settings.dart';
import '../session/session.dart';
import '../time/time.dart';
import '../validate/validate.dart';
import 'project_summary.dart';
import 'storage_report.dart';
import 'store_fs.dart';

/// How to create a project.
@immutable
sealed class NewProjectSpec {
  const NewProjectSpec();
}

/// An empty project. Defaults: 16:9 1080p at 30 fps unless [canvas] is given.
final class EmptyProjectSpec extends NewProjectSpec {
  /// Creates the spec.
  const EmptyProjectSpec({required this.name, this.canvas});

  /// Name (1–80 characters after trim).
  final String name;

  /// Canvas, or null for the default.
  final CanvasSpec? canvas;
}

/// A project built from picked media (Projects screen) or from the player's Edit action.
///
/// Settings derive from the first video (ARCH §8.4): aspect snapped to a standard ratio within 1%,
/// frame rate snapped to the nearest supported integer rate (cap 60), base short side 720/1080/2160
/// by source size and capabilities; `view.playhead = quantize(initialPlayhead)`.
final class FromMediaProjectSpec extends NewProjectSpec {
  /// Creates the spec.
  FromMediaProjectSpec({
    required List<PickedMedia> picks,
    required this.name,
    this.initialPlayhead = 0,
    this.origin = ProjectOrigin.projects,
  }) : picks = List.unmodifiable(picks);

  /// Media to import, in timeline order.
  final List<PickedMedia> picks;

  /// Name (1–80 characters after trim).
  final String name;

  /// Playhead on open (the player's position for the Edit action).
  final TimeUs initialPlayhead;

  /// Origin (`FromPlayerOrigin` for the player's Edit action).
  final ProjectOrigin origin;
}

/// Why a save happens.
enum SaveReason {
  /// Debounced autosave into the journal (CORE-26).
  autosave,

  /// ⌘/Ctrl+S or Project › Save.
  manual,

  /// App hidden/paused.
  lifecycle,

  /// Editor closing (waits ≤ 3 s).
  close,
}

/// Result of a successful save.
@immutable
final class SaveReceipt {
  /// Creates a receipt.
  const SaveReceipt({required this.projectId, required this.docRevision, required this.saveId, required this.savedAt, required this.reason});

  /// Project.
  final ProjectId projectId;

  /// Revision written.
  final int docRevision;

  /// `sv_…` id written into the header.
  final String saveId;

  /// When (UTC).
  final DateTime savedAt;

  /// Why.
  final SaveReason reason;
}

/// A project whose newest valid journal is ahead of its main document (crash recovery, ARCH §8.3).
@immutable
final class RecoverableSession {
  /// Creates a recoverable session.
  const RecoverableSession({
    required this.projectId,
    required this.projectName,
    required this.journalRevision,
    required this.mainRevision,
    required this.journalSavedAt,
  });

  /// Project.
  final ProjectId projectId;

  /// Name (for the recovery banner).
  final String projectName;

  /// `docRevision` of the journal slot.
  final int journalRevision;

  /// `docRevision` of the main document.
  final int mainRevision;

  /// When the journal was written.
  final DateTime journalSavedAt;
}

/// An opened project.
@immutable
final class LoadedProject {
  /// Creates the result of [ProjectRepository.open].
  LoadedProject({
    required this.project,
    this.health = ProjectHealth.ok,
    List<ProjectOpenWarning> warnings = const [],
    this.migratedFrom,
    this.pendingRecovery,
  }) : warnings = List.unmodifiable(warnings);

  /// The decoded, validated and repaired project.
  final EditProject project;

  /// `ok`, or `readOnlyNewer` (open read-only, D-12).
  final ProjectHealth health;

  /// Repairs and unknown values met while opening.
  final List<ProjectOpenWarning> warnings;

  /// Schema the file was migrated from (one-time toast), or null.
  final int? migratedFrom;

  /// A journal newer than the main document, when present.
  final RecoverableSession? pendingRecovery;

  /// Whether saving is disabled (newer schema, D-12).
  bool get readOnly => health == ProjectHealth.readOnlyNewer;
}

/// The project store (ARCH §8.4).
abstract interface class ProjectRepository {
  /// Summaries of every project, updated on change. Scans `projects/*/meta.json`.
  Stream<List<ProjectSummary>> watchSummaries();

  /// Creates a project and returns its id. `fromMedia` probes and imports media first (ARCH §9.1).
  Future<ProjectId> create(NewProjectSpec spec);

  /// Opens a project: read → migrate → decode → validate → repair → recovery check, in an isolate.
  /// Throws [StoreFailure] `busy` when already open, `notFound`, or `newerSchema` when blocked.
  Future<LoadedProject> open(ProjectId id);

  /// Writes main + meta + refs (and the poster on lifecycle/close). Failures surface as
  /// [StoreFailure]; edits stay in memory and the next trigger retries.
  Future<SaveReceipt> save(EditSession session, {required SaveReason reason});

  /// Requests a debounced journal autosave (2 s idle, forced at 10 s; skipped in transactions).
  void requestAutosave(EditSession session);

  /// Completes pending writes for [id].
  Future<void> flush(ProjectId id);

  /// Flushes and releases [id].
  Future<void> close(ProjectId id);

  /// Renames (1–80 characters after trim).
  Future<void> rename(ProjectId id, String name);

  /// Duplicates (`"<name> copy"`, `"<name> copy 2"`); managed media is shared, never copied.
  Future<ProjectId> duplicate(ProjectId id, {String? name});

  /// Atomic move to `trash/`, guarded delete, then garbage collection. Never touches originals.
  Future<void> delete(ProjectId id);

  /// Projects with a recoverable journal (ARCH §8.3).
  Future<List<RecoverableSession>> recoverable();

  /// Promotes the journal atomically and opens the project.
  Future<LoadedProject> restore(RecoverableSession session);

  /// Deletes the journal.
  Future<void> discard(RecoverableSession session);

  /// A project created by the player's Edit action for this file whose `editCount` is still 0.
  Future<ProjectId?> findUntouchedProjectFor(String pathOrUri);

  /// Storage usage for Settings › Storage.
  Future<ProjectStorageReport> storageReport();
}
