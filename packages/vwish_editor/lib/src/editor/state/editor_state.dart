// OWNER: UX-08
//
// EditorState and its value types (ARCH §17.3, ux.md §16.2), plus the EditorFailure taxonomy of
// ARCH §19 and the boundary mappings from engine, store and transcription errors.
//
// * Nothing in EditorState changes per playback frame: the playhead, transport, zoom/scroll,
//   drag ghosts and panel-local UI live outside it (ux.md §16.2).
// * `project` is the committed project, or the transaction's working copy while a gesture is
//   open (`inTransaction`); transaction emissions are coalesced to one per frame (UX-08 controller).
// * `HistoryStatus` is core's (re-exported) so the UI and the session agree on labels.
// * EditorFailure subtypes are named exactly as ARCH §19. `MediaUnavailable` shares its name with
//   the core rejection: a file that needs both imports `package:vwish_editor_core/ops.dart` with a
//   prefix or `hide MediaUnavailable`.

import 'package:flutter/foundation.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart' show GapRef, HistoryStatus;
import 'package:vwish_editor_core/store.dart' show StoreFailure, StoreFailureKind;
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart'
    show EngineErrorCode, EngineFailure, MediaAccessFailure, PreviewQuality;
import 'package:vwish_transcription/vwish_transcription.dart' show ModelDownloadFailure, ModelDownloadFailureKind, TranscriptionFailure;

import '../contracts/contracts.dart';
import '../timeline/timeline_metrics.dart' show LaneHeightPreset;

export 'package:vwish_editor_core/ops.dart' show HistoryStatus;

/// Lifecycle phase of an editor session (ux.md §16.2).
enum EditorPhase {
  /// Opening (repository, preview session, exact seek).
  opening,

  /// Ready to edit.
  ready,

  /// Opening failed (see [EditorState.failure]).
  failed,

  /// Closing (flushing the save, releasing the preview).
  closing,

  /// Closed: the session and the preview are released.
  closed,
}

// -------------------------------------------------------------------------------------------------
// Failures (ARCH §19)
// -------------------------------------------------------------------------------------------------

/// Why something in the editor failed (ARCH §19). Copy lives in `editor_messages.dart`.
@immutable
sealed class EditorFailure {
  /// Creates a failure.
  const EditorFailure();

  /// A stable code for "Copy details" (no paths, no user text).
  String get code;

  @override
  bool operator ==(Object other) => other.runtimeType == runtimeType && other is EditorFailure && other.code == code;

  @override
  int get hashCode => Object.hash(runtimeType, code);

  @override
  String toString() => '$runtimeType($code)';
}

/// The project id is unknown (deleted, never existed).
final class ProjectNotFound extends EditorFailure {
  /// Creates the failure.
  const ProjectNotFound();

  @override
  String get code => 'projectNotFound';
}

/// The project was saved by a newer app and can't be opened (D-12).
final class ProjectNeedsNewerApp extends EditorFailure {
  /// Creates the failure.
  const ProjectNeedsNewerApp();

  @override
  String get code => 'projectNeedsNewerApp';
}

/// No valid copy of the project could be read.
final class ProjectCorrupt extends EditorFailure {
  /// Creates the failure.
  const ProjectCorrupt();

  @override
  String get code => 'projectCorrupt';
}

/// A save failed; edits stay in memory and the journal keeps them recoverable.
final class SaveFailed extends EditorFailure {
  /// Creates the failure.
  const SaveFailed(this.kind);

  /// Store failure kind.
  final StoreFailureKind kind;

  @override
  String get code => 'saveFailed.${kind.name}';
}

/// A media file is offline (moved, deleted, access lost).
final class MediaUnavailable extends EditorFailure {
  /// Creates the failure.
  const MediaUnavailable();

  @override
  String get code => 'mediaUnavailable';
}

/// A media file can't be edited on this device.
final class MediaUnsupported extends EditorFailure {
  /// Creates the failure for [reason] (an engine or probe code, e.g. `containerUnsupportedIos`).
  const MediaUnsupported(this.reason);

  /// Reason code.
  final String reason;

  @override
  String get code => 'mediaUnsupported.$reason';
}

/// Media couldn't be added to the project.
final class ImportFailed extends EditorFailure {
  /// Creates the failure for [reason] (an `ImportRejected.reason`, e.g. `unsupported`, `diskFull`).
  const ImportFailed(this.reason);

  /// Reason code.
  final String reason;

  @override
  String get code => 'importFailed.$reason';
}

/// The live preview stopped.
final class PreviewFailed extends EditorFailure {
  /// Creates the failure; [recoverable] means "Restart preview" may help.
  const PreviewFailed({this.recoverable = true, this.engineCode});

  /// Whether restarting the preview may help.
  final bool recoverable;

  /// The engine code behind it, if any.
  final EngineErrorCode? engineCode;

  @override
  String get code => 'previewFailed.${engineCode?.name ?? 'unknown'}${recoverable ? '' : '.fatal'}';
}

/// Why an export failed (ARCH §19).
enum ExportFailureKind {
  /// The encoder isn't available right now ("Export with H.264").
  encoderUnavailable,

  /// The size is above the encoder's limit ("Lower resolution").
  encoderSizeLimit,

  /// Not enough space.
  diskFull,

  /// The export was interrupted (app killed, background time over).
  interrupted,

  /// The destination refused the file (Photos access, folder permission).
  destinationDenied,

  /// Anything else.
  unknown,
}

/// An export failed.
final class ExportFailed extends EditorFailure {
  /// Creates the failure.
  const ExportFailed(this.kind);

  /// Kind.
  final ExportFailureKind kind;

  @override
  String get code => 'exportFailed.${kind.name}';
}

/// A permission the editor asks for (ARCH §19).
enum EditorPermission {
  /// Microphone (voiceover).
  microphone,

  /// Add to Photos (export).
  photosAdd,

  /// Notifications (Android export progress).
  notifications,
}

/// A permission is off.
final class PermissionDenied extends EditorFailure {
  /// Creates the failure.
  const PermissionDenied(this.permission);

  /// The permission.
  final EditorPermission permission;

  @override
  String get code => 'permissionDenied.${permission.name}';
}

/// File formats the editor parses (ARCH §19).
enum EditorParseFormat {
  /// SubRip subtitles.
  srt,

  /// WebVTT subtitles.
  vtt,

  /// `.cube` LUT.
  cube,
}

/// A subtitle or LUT file couldn't be read.
final class ParseFailed extends EditorFailure {
  /// Creates the failure; [line] is 1-based when known.
  const ParseFailed(this.format, {this.line});

  /// Format.
  final EditorParseFormat format;

  /// Line, or null.
  final int? line;

  @override
  String get code => 'parseFailed.${format.name}${line == null ? '' : ':$line'}';
}

/// The speech model download failed.
final class ModelDownloadFailed extends EditorFailure {
  /// Creates the failure.
  const ModelDownloadFailed(this.kind);

  /// Kind.
  final ModelDownloadFailureKind kind;

  @override
  String get code => 'modelDownloadFailed.${kind.name}';
}

/// Auto captions failed for another reason.
final class TranscriptionFailed extends EditorFailure {
  /// Creates the failure from a `TranscriptionFailure.code`.
  const TranscriptionFailed(this.reason, {this.retryable = false});

  /// Transcription failure code.
  final String reason;

  /// Whether "Try again" may help.
  final bool retryable;

  @override
  String get code => 'transcriptionFailed.$reason';
}

/// Anything else (controllers wrap unexpected errors as this; no editor action crashes the app).
final class UnknownFailure extends EditorFailure {
  /// Creates the failure with a diagnostic [reason] (a type name or code, never a path).
  const UnknownFailure([this.reason = 'unknown']);

  /// Diagnostic reason.
  final String reason;

  @override
  String get code => 'unknown.$reason';
}

/// Where an engine failure happened (changes how it maps, ARCH §19).
enum EngineFailureContext {
  /// Live preview and plan sync.
  preview,

  /// Export.
  export,

  /// Voiceover recording.
  recording,

  /// Import, probe and background media jobs.
  media,
}

/// Boundary mappings to [EditorFailure] (ARCH §19).
abstract final class EditorFailures {
  /// Maps an engine failure; null for `cancelled` (not a failure). `planOutOfSync` is normally
  /// handled by PlanSync and `surfaceLost` is auto-recovered; both map to a recoverable preview
  /// failure when they reach the UI anyway.
  static EditorFailure? fromEngine(EngineFailure failure, {EngineFailureContext context = EngineFailureContext.preview}) {
    final export = context == EngineFailureContext.export;
    switch (failure.code) {
      case EngineErrorCode.cancelled:
        return null;
      case EngineErrorCode.mediaOffline:
        return const MediaUnavailable();
      case EngineErrorCode.permissionDenied:
        return switch (context) {
          EngineFailureContext.recording => const PermissionDenied(EditorPermission.microphone),
          EngineFailureContext.export => const ExportFailed(ExportFailureKind.destinationDenied),
          _ => const MediaUnavailable(),
        };
      case EngineErrorCode.unsupportedMedia || EngineErrorCode.notSupportedOnDevice:
        return MediaUnsupported(failure.code.name);
      case EngineErrorCode.decoderInitFailed ||
            EngineErrorCode.decodeFailed ||
            EngineErrorCode.gpuUnavailable ||
            EngineErrorCode.io ||
            EngineErrorCode.busy:
        return export ? const ExportFailed(ExportFailureKind.unknown) : PreviewFailed(engineCode: failure.code);
      case EngineErrorCode.encoderUnavailable:
        return const ExportFailed(ExportFailureKind.encoderUnavailable);
      case EngineErrorCode.encoderSizeLimit:
        return const ExportFailed(ExportFailureKind.encoderSizeLimit);
      case EngineErrorCode.encodingFailed:
        return const ExportFailed(ExportFailureKind.unknown);
      case EngineErrorCode.diskFull:
        return export ? const ExportFailed(ExportFailureKind.diskFull) : const SaveFailed(StoreFailureKind.diskFull);
      case EngineErrorCode.interrupted:
        return export ? const ExportFailed(ExportFailureKind.interrupted) : PreviewFailed(engineCode: failure.code);
      case EngineErrorCode.planOutOfSync || EngineErrorCode.surfaceLost:
        return PreviewFailed(engineCode: failure.code);
      case EngineErrorCode.planInvalid || EngineErrorCode.internal:
        debugPrint('vwish_editor: engine ${failure.code.name} (${context.name})');
        return UnknownFailure(failure.code.name);
    }
  }

  /// Maps a store failure. While [opening], `notFound`/`newerSchema`/`corrupt` are about the
  /// project itself; otherwise every kind is a [SaveFailed].
  static EditorFailure fromStore(StoreFailure failure, {bool opening = false}) {
    if (opening) {
      switch (failure.kind) {
        case StoreFailureKind.notFound:
          return const ProjectNotFound();
        case StoreFailureKind.newerSchema:
          return const ProjectNeedsNewerApp();
        case StoreFailureKind.corrupt:
          return const ProjectCorrupt();
        case StoreFailureKind.busy:
          return const UnknownFailure('projectBusy');
        case StoreFailureKind.diskFull || StoreFailureKind.permissionDenied || StoreFailureKind.io:
          return UnknownFailure('open.${failure.kind.name}');
      }
    }
    return SaveFailed(failure.kind);
  }

  /// Maps any error at a controller boundary (ARCH §19 rule 1).
  static EditorFailure fromError(Object error, {EngineFailureContext context = EngineFailureContext.preview, bool opening = false}) {
    return switch (error) {
      EditorFailure() => error,
      EngineFailure() => fromEngine(error, context: context) ?? const UnknownFailure('cancelled'),
      StoreFailure() => fromStore(error, opening: opening),
      MediaAccessFailure() => const MediaUnavailable(),
      ModelDownloadFailure(:final kind) => ModelDownloadFailed(kind),
      TranscriptionFailure() => TranscriptionFailed(error.code, retryable: error.retryable),
      _ => UnknownFailure(error.runtimeType.toString()),
    };
  }
}

// -------------------------------------------------------------------------------------------------
// Save status (ux.md §14.3)
// -------------------------------------------------------------------------------------------------

/// What the title subtitle shows (ux.md §6.4, §14.3).
enum SavePhase {
  /// Nothing changed since the project opened.
  clean,

  /// Unsaved edits (autosave pending).
  edited,

  /// A save is running.
  saving,

  /// Everything is on disk.
  saved,

  /// The last save failed ("Couldn't save · Retry").
  failed,

  /// Opened read-only (saved by a newer app, D-12): nothing is saved.
  readOnly,
}

/// Save status of the open project (ux.md §14.3).
@immutable
final class SaveStatus {
  /// Creates a status.
  const SaveStatus(this.phase, {this.at, this.failure});

  /// Nothing to save.
  static const SaveStatus clean = SaveStatus(SavePhase.clean);

  /// Unsaved edits.
  static const SaveStatus edited = SaveStatus(SavePhase.edited);

  /// Saving.
  static const SaveStatus saving = SaveStatus(SavePhase.saving);

  /// Read-only project.
  static const SaveStatus readOnly = SaveStatus(SavePhase.readOnly);

  /// Saved at [at].
  factory SaveStatus.saved(DateTime? at) => SaveStatus(SavePhase.saved, at: at);

  /// Failed with [failure].
  factory SaveStatus.failed(SaveFailed failure) => SaveStatus(SavePhase.failed, failure: failure);

  /// Phase.
  final SavePhase phase;

  /// When the last save finished (phase `saved`).
  final DateTime? at;

  /// Why the last save failed (phase `failed`).
  final SaveFailed? failure;

  @override
  bool operator ==(Object other) => other is SaveStatus && other.phase == phase && other.at == at && other.failure == failure;

  @override
  int get hashCode => Object.hash(phase, at, failure);

  @override
  String toString() => 'SaveStatus(${phase.name}${failure == null ? '' : ', $failure'})';
}

// -------------------------------------------------------------------------------------------------
// Selection, modes, preview, media, tasks
// -------------------------------------------------------------------------------------------------

/// How `select` combines with the current selection (ux.md §16.3).
enum SelectMode {
  /// Replace the selection.
  replace,

  /// Add or remove the item (Shift/⌘ click, multi-select mode).
  toggle,

  /// Add the item, keeping the rest.
  extend,
}

/// The selection (ux.md §16.2). Not in history.
@immutable
final class EditorSelection {
  /// Creates a selection.
  EditorSelection({Set<ItemId> items = const {}, this.primary, this.lane, this.marker, this.keyframe, this.transition, this.gap})
      : items = Set.unmodifiable(items);

  const EditorSelection._empty()
      : items = const {},
        primary = null,
        lane = null,
        marker = null,
        keyframe = null,
        transition = null,
        gap = null;

  /// Nothing selected.
  static const EditorSelection empty = EditorSelection._empty();

  /// Selected items.
  final Set<ItemId> items;

  /// The item the inspector and context tools target.
  final ItemId? primary;

  /// The selected lane (header tap, paste target).
  final TrackId? lane;

  /// A selected marker.
  final MarkerId? marker;

  /// A selected keyframe diamond.
  final KeyframeRef? keyframe;

  /// A selected cut.
  final TransitionRef? transition;

  /// A selected gap.
  final GapRef? gap;

  /// Whether nothing is selected.
  bool get isEmpty => items.isEmpty && lane == null && marker == null && keyframe == null && transition == null && gap == null;

  /// Only items [keep] says still exist; the primary falls back to another kept item.
  EditorSelection retainItems(bool Function(ItemId id) keep) {
    final kept = {
      for (final i in items)
        if (keep(i)) i
    };
    final k = keyframe;
    final t = transition;
    final keepTransition = t != null && keep(t.left) && keep(t.right);
    if (kept.length == items.length && (k == null || keep(k.item)) && (t == null || keepTransition)) return this;
    final p = primary;
    return EditorSelection(
      items: kept,
      primary: p != null && kept.contains(p) ? p : (kept.isEmpty ? null : kept.first),
      lane: lane,
      marker: marker,
      keyframe: k != null && keep(k.item) ? k : null,
      transition: keepTransition ? t : null,
      gap: gap,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is EditorSelection &&
      setEquals(other.items, items) &&
      other.primary == primary &&
      other.lane == lane &&
      other.marker == marker &&
      other.keyframe == keyframe &&
      other.transition == transition &&
      other.gap == gap;

  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(items), primary, lane, marker, keyframe, transition, gap);

  @override
  String toString() => isEmpty ? 'EditorSelection.empty' : 'EditorSelection($items, primary: $primary, lane: $lane)';
}

/// Ripple, snapping, multi-select, centre playhead, safe guides and lane height (ux.md §16.2).
/// Ripple and snapping persist in the project's `ViewState`; centre playhead starts from
/// `EditorPrefs.centerPlayheadOnTouch`.
@immutable
final class EditModes {
  /// Creates modes.
  const EditModes({
    this.ripple = true,
    this.snapping = true,
    this.multiSelect = false,
    this.centerPlayhead = true,
    this.safeGuides = false,
    this.laneHeight = LaneHeightPreset.normal,
  });

  /// Ripple editing.
  final bool ripple;

  /// Snapping.
  final bool snapping;

  /// Touch multi-select mode (taps toggle).
  final bool multiSelect;

  /// Centre-locked playhead (scrolling scrubs).
  final bool centerPlayhead;

  /// Safe-area guides over the preview.
  final bool safeGuides;

  /// Lane height preset.
  final LaneHeightPreset laneHeight;

  /// A copy with the given fields replaced.
  EditModes copyWith(
          {bool? ripple, bool? snapping, bool? multiSelect, bool? centerPlayhead, bool? safeGuides, LaneHeightPreset? laneHeight}) =>
      EditModes(
        ripple: ripple ?? this.ripple,
        snapping: snapping ?? this.snapping,
        multiSelect: multiSelect ?? this.multiSelect,
        centerPlayhead: centerPlayhead ?? this.centerPlayhead,
        safeGuides: safeGuides ?? this.safeGuides,
        laneHeight: laneHeight ?? this.laneHeight,
      );

  @override
  bool operator ==(Object other) =>
      other is EditModes &&
      other.ripple == ripple &&
      other.snapping == snapping &&
      other.multiSelect == multiSelect &&
      other.centerPlayhead == centerPlayhead &&
      other.safeGuides == safeGuides &&
      other.laneHeight == laneHeight;

  @override
  int get hashCode => Object.hash(ripple, snapping, multiSelect, centerPlayhead, safeGuides, laneHeight);

  @override
  String toString() => 'EditModes(ripple: $ripple, snapping: $snapping, multi: $multiSelect, centre: $centerPlayhead, '
      'guides: $safeGuides, ${laneHeight.name})';
}

/// Phase of the live preview (ux.md §16.2, ARCH §17.5).
enum PreviewPhase {
  /// Opening the session or waiting for the first frame.
  starting,

  /// Showing frames.
  ready,

  /// Running at a lowered quality (thermal, memory).
  degraded,

  /// Stopped ("Restart preview").
  failed,
}

/// Preview status (ux.md §16.2).
@immutable
final class PreviewStatus {
  /// Creates a status.
  const PreviewStatus(this.phase, {this.quality = PreviewQuality.auto, this.useProxies = true, this.failure});

  /// The status while opening.
  static const PreviewStatus starting = PreviewStatus(PreviewPhase.starting);

  /// Phase.
  final PreviewPhase phase;

  /// Current quality (the degraded quality in phase `degraded`).
  final PreviewQuality quality;

  /// Whether ready proxies are used.
  final bool useProxies;

  /// Why it stopped (phase `failed`).
  final PreviewFailed? failure;

  /// A copy with the given fields replaced; [failure] is kept only in phase `failed`.
  PreviewStatus copyWith({PreviewPhase? phase, PreviewQuality? quality, bool? useProxies, PreviewFailed? failure}) {
    final p = phase ?? this.phase;
    return PreviewStatus(
      p,
      quality: quality ?? this.quality,
      useProxies: useProxies ?? this.useProxies,
      failure: p == PreviewPhase.failed ? (failure ?? this.failure) : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PreviewStatus &&
      other.phase == phase &&
      other.quality == quality &&
      other.useProxies == useProxies &&
      other.failure == failure;

  @override
  int get hashCode => Object.hash(phase, quality, useProxies, failure);

  @override
  String toString() => 'PreviewStatus(${phase.name}, ${quality.name}, proxies: $useProxies)';
}

/// Missing media and relink state (ux.md §16.2; maintained by UX-40's media health controller).
@immutable
final class MediaHealth {
  /// Creates the health.
  MediaHealth({Set<MediaId> missing = const {}, this.relinkRequired = false}) : missing = Set.unmodifiable(missing);

  const MediaHealth._ok()
      : missing = const {},
        relinkRequired = false;

  /// Everything available.
  static const MediaHealth ok = MediaHealth._ok();

  /// Assets that are offline.
  final Set<MediaId> missing;

  /// Whether export is blocked until media is relinked.
  final bool relinkRequired;

  /// Whether everything is available.
  bool get isOk => missing.isEmpty && !relinkRequired;

  @override
  bool operator ==(Object other) => other is MediaHealth && other.relinkRequired == relinkRequired && setEquals(other.missing, missing);

  @override
  int get hashCode => Object.hash(relinkRequired, Object.hashAllUnordered(missing));

  @override
  String toString() => 'MediaHealth(missing: ${missing.length}, relink: $relinkRequired)';
}

/// Kinds of background tasks (ux.md §10.15).
enum EditorTaskKind {
  /// Optimized copy for smoother editing.
  proxy,

  /// Reversed rendition.
  reverse,

  /// Freeze frame still.
  freeze,

  /// Audio waveform.
  waveform,

  /// Auto captions.
  captions,

  /// Speech model download.
  download,
}

/// A background task shown in the tasks sheet (ux.md §16.2; maintained by UX-35).
@immutable
final class EditorTaskInfo {
  /// Creates a task.
  const EditorTaskInfo({required this.id, required this.kind, required this.label, this.progress, this.failed = false});

  /// Stable id (job id).
  final String id;

  /// Kind.
  final EditorTaskKind kind;

  /// Plain label ("Optimizing beach.mp4" is not allowed: no file names; "Optimizing a clip").
  final String label;

  /// 0..1, or null when indeterminate.
  final double? progress;

  /// Whether it failed.
  final bool failed;

  @override
  bool operator ==(Object other) =>
      other is EditorTaskInfo &&
      other.id == id &&
      other.kind == kind &&
      other.label == label &&
      other.progress == progress &&
      other.failed == failed;

  @override
  int get hashCode => Object.hash(id, kind, label, progress, failed);

  @override
  String toString() => 'EditorTaskInfo($id, ${kind.name}, $progress)';
}

// -------------------------------------------------------------------------------------------------
// EditorState
// -------------------------------------------------------------------------------------------------

const Object _keep = Object();

/// State of one open editor (ARCH §17.3, ux.md §16.2). Nothing in it changes per playback frame.
@immutable
class EditorState {
  /// Creates a state.
  EditorState({
    required this.phase,
    this.failure,
    this.project,
    this.inTransaction = false,
    this.history = HistoryStatus.empty,
    this.save = SaveStatus.clean,
    this.selection = EditorSelection.empty,
    this.tool,
    this.inspector,
    this.modes = const EditModes(),
    this.preview = PreviewStatus.starting,
    this.media = MediaHealth.ok,
    List<EditorTaskInfo> tasks = const [],
  }) : tasks = List.unmodifiable(tasks);

  /// The opening state.
  const EditorState.opening()
      : phase = EditorPhase.opening,
        failure = null,
        project = null,
        inTransaction = false,
        history = HistoryStatus.empty,
        save = SaveStatus.clean,
        selection = EditorSelection.empty,
        tool = null,
        inspector = null,
        modes = const EditModes(),
        preview = PreviewStatus.starting,
        media = MediaHealth.ok,
        tasks = const [];

  /// Lifecycle phase.
  final EditorPhase phase;

  /// Why opening failed (phase `failed`).
  final EditorFailure? failure;

  /// The committed project, or the working copy while a transaction is open.
  final EditProject? project;

  /// Whether a gesture transaction is open.
  final bool inTransaction;

  /// Undo/redo availability and labels.
  final HistoryStatus history;

  /// Save status.
  final SaveStatus save;

  /// Selection.
  final EditorSelection selection;

  /// Active top-level tool.
  final ToolId? tool;

  /// Open inspector panel.
  final InspectorRoute? inspector;

  /// Edit modes.
  final EditModes modes;

  /// Preview status.
  final PreviewStatus preview;

  /// Media health.
  final MediaHealth media;

  /// Background tasks.
  final List<EditorTaskInfo> tasks;

  /// Whether the editor is ready to edit.
  bool get isReady => phase == EditorPhase.ready;

  /// A copy with the given fields replaced (pass null to clear [failure], [project], [tool] or
  /// [inspector]).
  EditorState copyWith({
    EditorPhase? phase,
    Object? failure = _keep,
    Object? project = _keep,
    bool? inTransaction,
    HistoryStatus? history,
    SaveStatus? save,
    EditorSelection? selection,
    Object? tool = _keep,
    Object? inspector = _keep,
    EditModes? modes,
    PreviewStatus? preview,
    MediaHealth? media,
    List<EditorTaskInfo>? tasks,
  }) =>
      EditorState(
        phase: phase ?? this.phase,
        failure: identical(failure, _keep) ? this.failure : failure as EditorFailure?,
        project: identical(project, _keep) ? this.project : project as EditProject?,
        inTransaction: inTransaction ?? this.inTransaction,
        history: history ?? this.history,
        save: save ?? this.save,
        selection: selection ?? this.selection,
        tool: identical(tool, _keep) ? this.tool : tool as ToolId?,
        inspector: identical(inspector, _keep) ? this.inspector : inspector as InspectorRoute?,
        modes: modes ?? this.modes,
        preview: preview ?? this.preview,
        media: media ?? this.media,
        tasks: tasks ?? this.tasks,
      );

  @override
  bool operator ==(Object other) =>
      other is EditorState &&
      other.phase == phase &&
      other.failure == failure &&
      identical(other.project, project) &&
      other.inTransaction == inTransaction &&
      other.history == history &&
      other.save == save &&
      other.selection == selection &&
      other.tool == tool &&
      other.inspector == inspector &&
      other.modes == modes &&
      other.preview == preview &&
      other.media == media &&
      listEquals(other.tasks, tasks);

  @override
  int get hashCode => Object.hash(phase, failure, identityHashCode(project), inTransaction, history, save, selection, tool, inspector,
      modes, preview, media, Object.hashAll(tasks));

  @override
  String toString() => 'EditorState(${phase.name}${failure == null ? '' : ', $failure'}, rev: ${project?.timeline.revision}, '
      'tx: $inTransaction, $history, $save, $selection, tool: ${tool?.name}, inspector: $inspector)';
}
