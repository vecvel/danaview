// OWNER: UX-39
//
// The state of the export flow (ux.md §11.4, ARCH §14.1): one sealed hierarchy the export sheet
// switches over. Names carry the `ExportUi` prefix because the engine API owns `ExportRunning`,
// `ExportInterrupted` and friends (job records, ARCH §12.4) and `ExportFailed` is the failure type.
//
// Flow: Idle -> (pre-checks) -> NeedsRelink | Waiting | Setup -> [Notice] -> Preparing -> [Warnings]
// -> Running -> Completed | Failed | Cancelling -> Cancelled; reattach adds Interrupted and
// FinishedAway.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:danaview_editor_core/model.dart' show AspectRatio, TrackId;
import 'package:danaview_editor_core/plan.dart'
    show ExportCapabilities, ExportContainer, ExportPresetId, ExportQuality, ExportSettings, ResolvedExport, SideFileFormat, VideoCodec;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show BackgroundExportKind, ExportPhase, ExportResult, ExportWarning;

import '../../state/editor_state.dart' show EditorFailure;

/// Where the finished video goes first ("Save to", ux.md §11.2).
enum ExportDestination {
  /// Photos (iOS) or the Gallery (Android).
  photos,

  /// The Files / document picker.
  files,

  /// The system share sheet.
  share,
}

/// What the user chose: [settings] plus the destination and "Keep a copy in Danaview".
@immutable
final class ExportDraft {
  /// Creates a draft.
  const ExportDraft({required this.settings, this.destination = ExportDestination.photos, this.keepCopy = false});

  /// Core export settings (preset, custom values, burn-in, side files).
  final ExportSettings settings;

  /// First destination.
  final ExportDestination destination;

  /// Also write a copy to `Documents/Exports` (D-44).
  final bool keepCopy;

  /// A copy with the given fields replaced.
  ExportDraft copyWith({ExportSettings? settings, ExportDestination? destination, bool? keepCopy}) => ExportDraft(
        settings: settings ?? this.settings,
        destination: destination ?? this.destination,
        keepCopy: keepCopy ?? this.keepCopy,
      );

  /// JSON for the per-project memory ("last-used settings are remembered per project").
  String toJsonString() => jsonEncode({
        'preset': settings.preset.name,
        'shortSide': settings.shortSide,
        'fps': settings.fps,
        'container': settings.container.name,
        'codec': settings.codec.name,
        'quality': settings.quality.name,
        'videoMbps': settings.videoBitrateMbps,
        'audioKbps': settings.audioBitrateKbps,
        'burnIn': {for (final e in settings.burnInSubtitles.entries) e.key.value: e.value},
        'sideFiles': [for (final f in settings.sideFiles) f.name],
        'destination': destination.name,
        'keepCopy': keepCopy,
      });

  /// Reads [toJsonString]'s output; null when it is malformed (the caller falls back to defaults).
  static ExportDraft? tryParse(String? source) {
    if (source == null) return null;
    try {
      final j = jsonDecode(source);
      if (j is! Map<String, Object?>) return null;
      T pick<T>(List<T> values, Object? name, T fallback) {
        for (final v in values) {
          if ((v as Enum).name == name) return v;
        }
        return fallback;
      }

      final burn = j['burnIn'];
      final sides = j['sideFiles'];
      return ExportDraft(
        settings: ExportSettings(
          preset: pick(ExportPresetId.values, j['preset'], ExportPresetId.youtube),
          shortSide: _safeShortSide(j['shortSide']),
          fps: _safeFps(j['fps']),
          container: pick(ExportContainer.values, j['container'], ExportContainer.mp4),
          codec: pick(VideoCodec.values, j['codec'], VideoCodec.h264),
          quality: pick(ExportQuality.values, j['quality'], ExportQuality.balanced),
          videoBitrateMbps: (j['videoMbps'] as num?)?.toDouble(),
          audioBitrateKbps: (j['audioKbps'] as num?)?.toInt(),
          burnInSubtitles: {
            if (burn is Map<String, Object?>)
              for (final e in burn.entries)
                if (e.value is bool) TrackId(e.key): e.value! as bool,
          },
          sideFiles: {
            if (sides is List)
              for (final s in sides)
                for (final f in SideFileFormat.values)
                  if (f.name == s) f,
          },
        ),
        destination: pick(ExportDestination.values, j['destination'], ExportDestination.photos),
        keepCopy: j['keepCopy'] == true,
      );
    } on Object {
      return null;
    }
  }

  static int _safeShortSide(Object? v) => v is int && const [720, 1080, 1440, 2160].contains(v) ? v : 1080;

  static int? _safeFps(Object? v) => v is int && const [24, 25, 30, 48, 50, 60].contains(v) ? v : null;

  @override
  bool operator ==(Object other) =>
      other is ExportDraft && other.settings == settings && other.destination == destination && other.keepCopy == keepCopy;

  @override
  int get hashCode => Object.hash(settings, destination, keepCopy);
}

/// What the device allows, in the terms the sheet needs (built from `EditorCapabilities`).
@immutable
final class ExportLimits {
  /// Creates limits.
  const ExportLimits({
    required this.caps,
    this.hardwareH264 = true,
    this.hardwareHevc = false,
    this.backgroundKind = BackgroundExportKind.none,
    this.offer4kPreset = false,
  });

  /// Capability subset the core export reads.
  final ExportCapabilities caps;

  /// A hardware H.264 encoder exists.
  final bool hardwareH264;

  /// A hardware HEVC encoder exists.
  final bool hardwareHevc;

  /// What happens to an export in the background (D-22).
  final BackgroundExportKind backgroundKind;

  /// Whether the YouTube 4K preset is offered (device and source reach 2160p).
  final bool offer4kPreset;

  /// MOV is offered.
  bool get canMov => caps.movContainer;

  /// H.265 is offered.
  bool get canHevc => caps.hevcEncode;

  /// Whether the encoder for [codec] is a hardware one.
  bool hardwareFor(VideoCodec codec) => codec == VideoCodec.hevc ? hardwareHevc : hardwareH264;

  /// Whether an output of [shortSide] fits the device's export size limit (16:9 is the widest
  /// aspect the Custom sizes use, so the long side is checked against it).
  bool allowsShortSide(int shortSide) {
    final long = (shortSide * 16 / 9).round();
    return shortSide <= caps.maxExportShortSide && long <= caps.maxExportLongSide;
  }

  /// The Custom resolutions this device offers.
  List<int> get shortSides => [for (final s in const [720, 1080, 1440, 2160]) if (allowsShortSide(s)) s];

  /// The Custom frame rates this device offers at [shortSide] (Match project is always offered).
  List<int> fpsOptions(int shortSide) {
    final max = caps.maxFpsFor(shortSide);
    return [for (final f in const [24, 25, 30, 48, 50, 60]) if (f <= max) f];
  }
}

/// One subtitle track in the Captions section.
@immutable
final class ExportSubtitleTrack {
  /// Creates the entry.
  const ExportSubtitleTrack({required this.id, required this.name, required this.burnIn, required this.cueCount, this.language});

  /// Track id.
  final TrackId id;

  /// Display name ("Captions (Spanish)").
  final String name;

  /// BCP-47 tag or null.
  final String? language;

  /// Whether the track is burned into the video with the current settings.
  final bool burnIn;

  /// Number of cues.
  final int cueCount;
}

/// Why the Export button cannot start yet (shown inline in the setup).
enum ExportIssueKind {
  /// Not enough free space for the estimate (ux.md §11.1 check 4).
  lowStorage,
}

/// An inline problem of the setup.
@immutable
final class ExportIssue {
  /// Creates an issue.
  const ExportIssue(this.kind, {this.neededBytes = 0, this.freeBytes = 0});

  /// Kind.
  final ExportIssueKind kind;

  /// Bytes the export needs.
  final int neededBytes;

  /// Bytes free.
  final int freeBytes;
}

// -------------------------------------------------------------------------------------------------
// States
// -------------------------------------------------------------------------------------------------

/// The state of the export flow (ux.md §11.4).
@immutable
sealed class ExportUiState {
  const ExportUiState();
}

/// Before the pre-checks ran.
final class ExportUiIdle extends ExportUiState {
  /// Creates the state.
  const ExportUiIdle();
}

/// Missing media blocks the export (ux.md §11.1 check 1).
final class ExportUiNeedsRelink extends ExportUiState {
  /// Creates the state for [count] missing files.
  const ExportUiNeedsRelink(this.count);

  /// Number of missing media files.
  final int count;
}

/// Reverse and freeze jobs are still running (ux.md §11.1 check 2).
final class ExportUiWaiting extends ExportUiState {
  /// Creates the state.
  const ExportUiWaiting(this.count, {this.progress});

  /// Clips still being prepared.
  final int count;

  /// Average progress of the jobs, or null.
  final double? progress;
}

/// Presets and settings; the Export button starts.
final class ExportUiSetup extends ExportUiState {
  /// Creates the state.
  const ExportUiSetup({
    required this.draft,
    required this.resolved,
    required this.limits,
    required this.projectAspect,
    this.subtitleTracks = const [],
    this.issue,
    this.checkingStorage = false,
  });

  /// What the user chose.
  final ExportDraft draft;

  /// Encode settings, notices and the estimate for [draft].
  final ResolvedExport resolved;

  /// Device limits.
  final ExportLimits limits;

  /// The project's aspect ratio.
  final AspectRatio projectAspect;

  /// Subtitle tracks of the project.
  final List<ExportSubtitleTrack> subtitleTracks;

  /// An inline problem, or null.
  final ExportIssue? issue;

  /// The storage check of the Export button is running.
  final bool checkingStorage;

  /// A copy with the given fields replaced; pass `clearIssue` to drop [issue].
  ExportUiSetup copyWith({
    ExportDraft? draft,
    ResolvedExport? resolved,
    List<ExportSubtitleTrack>? subtitleTracks,
    ExportIssue? issue,
    bool clearIssue = false,
    bool? checkingStorage,
  }) =>
      ExportUiSetup(
        draft: draft ?? this.draft,
        resolved: resolved ?? this.resolved,
        limits: limits,
        projectAspect: projectAspect,
        subtitleTracks: subtitleTracks ?? this.subtitleTracks,
        issue: clearIssue ? null : (issue ?? this.issue),
        checkingStorage: checkingStorage ?? this.checkingStorage,
      );
}

/// The first-export notice about the background (ux.md §11.5).
final class ExportUiNotice extends ExportUiState {
  /// Creates the state; [setup] is where Back returns to.
  const ExportUiNotice({required this.setup, required this.kind, required this.explainNotifications});

  /// The setup to return to.
  final ExportUiSetup setup;

  /// What the device does when the app is backgrounded.
  final BackgroundExportKind kind;

  /// Android: explain the notification and ask for the permission when continuing.
  final bool explainNotifications;
}

/// Preflight warnings the user confirms before the export starts.
final class ExportUiWarnings extends ExportUiState {
  /// Creates the state.
  ExportUiWarnings({required this.setup, required List<ExportWarning> warnings}) : warnings = List.unmodifiable(warnings);

  /// The setup to return to.
  final ExportUiSetup setup;

  /// Warnings to show.
  final List<ExportWarning> warnings;
}

/// Preparing: the sprite pre-pass, compile and preflight ("Preparing…").
final class ExportUiPreparing extends ExportUiState {
  /// Creates the state.
  const ExportUiPreparing({this.fraction, this.cancelling = false});

  /// Pre-pass progress, or null while indeterminate.
  final double? fraction;

  /// Cancel was pressed.
  final bool cancelling;
}

/// Encoding.
final class ExportUiRunning extends ExportUiState {
  /// Creates the state.
  ExportUiRunning({
    required this.phase,
    required this.fraction,
    this.framesDone = 0,
    this.framesTotal = 0,
    this.backgrounded = false,
    this.pausedInBackground = false,
    this.eta,
    List<ExportWarning> warnings = const [],
    this.backgroundKind = BackgroundExportKind.none,
    this.notificationsUnanswered = false,
  }) : warnings = List.unmodifiable(warnings);

  /// Engine phase.
  final ExportPhase phase;

  /// 0..1 overall.
  final double fraction;

  /// Frames encoded.
  final int framesDone;

  /// Frames to encode.
  final int framesTotal;

  /// The app is in the background.
  final bool backgrounded;

  /// iOS: stopped at background, resumes on return (D-22).
  final bool pausedInBackground;

  /// Time left, after enough samples.
  final Duration? eta;

  /// Warnings reported by the engine.
  final List<ExportWarning> warnings;

  /// What the device does in the background (copy).
  final BackgroundExportKind backgroundKind;

  /// Android: the notification permission dialog went unanswered at start (UX-39), so this export
  /// runs without notifications; the progress view says so once, for this run.
  final bool notificationsUnanswered;
}

/// Cancel was confirmed; the job is stopping and deleting its partial file.
final class ExportUiCancelling extends ExportUiState {
  /// Creates the state.
  const ExportUiCancelling();
}

/// The export was cancelled (the sheet closes and shows a toast).
final class ExportUiCancelled extends ExportUiState {
  /// Creates the state.
  const ExportUiCancelled();
}

/// An export was interrupted (D-22).
final class ExportUiInterrupted extends ExportUiState {
  /// Creates the state; [jobId] and [doneFraction] are set when the job can resume.
  const ExportUiInterrupted({this.jobId, this.doneFraction = 0});

  /// The resumable job, or null.
  final String? jobId;

  /// Fraction already encoded.
  final double doneFraction;

  /// Whether "Resume export" is offered.
  bool get canResume => jobId != null;
}

/// How the first handoff of a finished export went.
enum ExportHandoffStatus {
  /// Running.
  pending,

  /// Done.
  saved,

  /// The user closed the system sheet.
  notSaved,

  /// Photos / folder access refused.
  denied,

  /// Failed.
  failed,
}

/// A caption side file written next to the export.
@immutable
final class ExportSideFile {
  /// Creates the entry.
  const ExportSideFile({required this.name, required this.path, required this.format, this.saved = false});

  /// File name shown to the user (`My video.es.srt`).
  final String name;

  /// App-owned temporary path.
  final String path;

  /// Format.
  final SideFileFormat format;

  /// Handed to Files already.
  final bool saved;

  /// A copy marked saved.
  ExportSideFile asSaved() => ExportSideFile(name: name, path: path, format: format, saved: true);
}

/// A finished export and what happened to it.
final class ExportUiCompleted extends ExportUiState {
  /// Creates the state.
  ExportUiCompleted({
    required this.result,
    required this.fileName,
    required this.destination,
    required this.handoff,
    this.savedToLibrary = false,
    this.keptCopyName,
    this.keepCopyFailed = false,
    List<ExportSideFile> sideFiles = const [],
    this.handoffFailure,
    this.busy = false,
    this.playablePath,
  }) : sideFiles = List.unmodifiable(sideFiles);

  /// The engine's result (the temp file is deleted when the sheet closes).
  final ExportResult result;

  /// Friendly name used for Files and "Keep a copy".
  final String fileName;

  /// The first destination.
  final ExportDestination destination;

  /// How the first handoff went.
  final ExportHandoffStatus handoff;

  /// The video is in Photos / Gallery.
  final bool savedToLibrary;

  /// Name of the copy in Documents/Exports, or null.
  final String? keptCopyName;

  /// "Keep a copy" failed.
  final bool keepCopyFailed;

  /// Caption side files.
  final List<ExportSideFile> sideFiles;

  /// Why the handoff failed or was denied.
  final EditorFailure? handoffFailure;

  /// A handoff is running.
  final bool busy;

  /// The file "Play in Danaview" opens (the kept copy, else the export), or null.
  final String? playablePath;

  /// A copy with the given fields replaced.
  ExportUiCompleted copyWith({
    ExportHandoffStatus? handoff,
    bool? savedToLibrary,
    ExportDestination? destination,
    String? keptCopyName,
    bool? keepCopyFailed,
    List<ExportSideFile>? sideFiles,
    EditorFailure? handoffFailure,
    bool clearFailure = false,
    bool? busy,
    String? playablePath,
  }) =>
      ExportUiCompleted(
        result: result,
        fileName: fileName,
        destination: destination ?? this.destination,
        handoff: handoff ?? this.handoff,
        savedToLibrary: savedToLibrary ?? this.savedToLibrary,
        keptCopyName: keptCopyName ?? this.keptCopyName,
        keepCopyFailed: keepCopyFailed ?? this.keepCopyFailed,
        sideFiles: sideFiles ?? this.sideFiles,
        handoffFailure: clearFailure ? null : (handoffFailure ?? this.handoffFailure),
        busy: busy ?? this.busy,
        playablePath: playablePath ?? this.playablePath,
      );
}

/// The export failed.
final class ExportUiFailed extends ExportUiState {
  /// Creates the state.
  const ExportUiFailed(this.failure, {this.details = ''});

  /// Why.
  final EditorFailure failure;

  /// "Copy details" text: the failure code and the settings, never paths or media names.
  final String details;
}

/// An export finished while Danaview was away (D-39): a one-shot card.
final class ExportUiFinishedAway extends ExportUiState {
  /// Creates the state.
  const ExportUiFinishedAway({required this.jobId, this.result, this.savedToGallery = false, this.busy = false, this.failed = false});

  /// Job id (consumed when the card is dismissed).
  final String jobId;

  /// The kept file, or null when only the gallery copy exists.
  final ExportResult? result;

  /// The engine saved it to Photos / Gallery.
  final bool savedToGallery;

  /// A handoff is running.
  final bool busy;

  /// The last action failed.
  final bool failed;

  /// A copy with the given fields replaced.
  ExportUiFinishedAway copyWith({bool? busy, bool? failed}) =>
      ExportUiFinishedAway(jobId: jobId, result: result, savedToGallery: savedToGallery, busy: busy ?? this.busy, failed: failed ?? this.failed);
}
