// OWNER: UX-32
//
// SRT/VTT import and export (ux.md §10.9, ARCH §10.1, §12.4, §9.6).
//
// * Import: the Files picker (subtitle kind, one file) -> the bytes of the pick (a `file://` URI or
//   path through `StoreFs`, at most [SubtitleIo.maxBytes]; an app-owned temporary copy is removed
//   afterwards through `OwnedFileDeleter`) -> `SubtitleCodec.parse` in `Isolate.run` (the file's
//   extension is the format hint) -> the result sheet: how many captions were found, the encoding
//   when it is not UTF-8 (a Windows-1252 / Latin-1 fallback is a warning), stripped formatting
//   tags and ignored placement settings, and the skipped parts with their line numbers ("Line 88:
//   the timing isn't valid") -> New track (default; named after the file, language from a
//   `<name>.<bcp47>.srt` file name) or Replace track (an unlocked subtitle track; the selected one
//   by default) -> one core `ImportSubtitles` (one history entry). A file with no readable caption
//   shows the first bad line and only Close.
// * Export: the sheet picks the track (every subtitle track with captions, generated captions
//   included; the selected one by default), SRT or VTT, and Save to Files or Share. The file
//   `<project>.<bcp47>.srt|vtt` (`SubtitleCodec.suggestedFileName`) is written to
//   `<cache>/danaview/editor/work/subtitles-<token>/`, handed to `FileHandoff.saveToFiles` or
//   `share`, and its folder is deleted through `OwnedFileDeleter` afterwards (also any folder an
//   earlier export left behind).
// * [SubtitleIoEnvironment] holds the collaborators (picker, handoff, file system, deleter, work
//   folder, parser); `subtitleIoEnvironmentProvider` builds it from the wired runtime and tests
//   override it. The actions themselves live in `actions/bindings/subtitle_io_bindings.dart`.

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:danaview_editor_core/formats.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show ImportSubtitles, SubtitleImportMode;
import 'package:danaview_editor_core/store.dart' show ImportPolicy, LocalStoreFs, OwnedFileDeleter, StoreEntityType, StoreFailure, StoreFs;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart'
    show FileHandoff, FileHandoffOutcome, MediaPickKind, MediaPickRequest, MediaPickSource, MediaPicker;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_bootstrap.dart' show editorRuntimeProvider;
import '../../app/editor_providers.dart' show EditorNotConfiguredError, editorEngineProvider;
import '../../app/strings/subtitle_io_strings.dart';
import '../../app/strings/subtitle_strings.dart' show SubtitleStrings;
import 'subtitles_panel.dart' show SubtitlesPanelModel;

// =================================================================================================
// Environment
// =================================================================================================

/// Parses subtitle bytes ([hint] from the file extension).
typedef SubtitleParser = Future<SubtitleParseResult> Function(Uint8List bytes, SubtitleFormat? hint);

/// Reads the bytes of a picked file; null when Dart cannot read it (for example a `content://`
/// URI). Throws [SubtitleFileTooLarge] above [SubtitleIo.maxBytes].
typedef SubtitlePickReader = Future<Uint8List?> Function(PickedMedia picked);

/// The default [SubtitleParser]: `SubtitleCodec.parse` in `Isolate.run` (ARCH §18.1), inline when
/// the isolate cannot start.
Future<SubtitleParseResult> isolateSubtitleParse(Uint8List bytes, SubtitleFormat? hint) async {
  try {
    return await Isolate.run(() => SubtitleCodec.parse(bytes, hint: hint), debugName: 'subtitle-parse');
  } on Object catch (e) {
    debugPrint('[SubtitleIo] Parse isolate failed (${e.runtimeType}); parsing inline');
    return SubtitleCodec.parse(bytes, hint: hint);
  }
}

/// A picked file is larger than [SubtitleIo.maxBytes].
final class SubtitleFileTooLarge implements Exception {
  /// Creates the error.
  const SubtitleFileTooLarge();
}

/// What the import and export flows need from the app.
final class SubtitleIoEnvironment {
  /// Creates an environment; [readPick] defaults to [readFromFs].
  SubtitleIoEnvironment({
    required this.picker,
    required this.files,
    required this.fs,
    required this.deleter,
    required this.workDir,
    this.parse = isolateSubtitleParse,
    SubtitlePickReader? readPick,
    String Function()? newToken,
  })  : _readPick = readPick,
        newToken = newToken ?? _defaultToken;

  /// The system pickers.
  final MediaPicker picker;

  /// Save to Files and Share.
  final FileHandoff files;

  /// File access (reads picks, writes the export file).
  final StoreFs fs;

  /// The only delete path (D-44).
  final OwnedFileDeleter deleter;

  /// `<cache>/danaview/editor/work`.
  final String workDir;

  /// The parser.
  final SubtitleParser parse;

  final SubtitlePickReader? _readPick;

  /// A unique token for the export folder.
  final String Function() newToken;

  /// Reads [picked].
  Future<Uint8List?> readPick(PickedMedia picked) => (_readPick ?? readFromFs)(picked);

  /// Reads a `file://` URI or absolute path through [fs]; null for other schemes or a missing file.
  Future<Uint8List?> readFromFs(PickedMedia picked) async {
    final path = ImportPolicy.pathOf(picked.uri);
    if (path == null) return null;
    final stat = await fs.stat(path);
    if (stat.type != StoreEntityType.file) return null;
    if (stat.size > SubtitleIo.maxBytes) throw const SubtitleFileTooLarge();
    return fs.readBytes(path);
  }

  static int _counter = 0;

  static String _defaultToken() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_counter++).toRadixString(36)}';
}

/// The environment of the app (engine picker and handoff, local files under the runtime's roots).
final subtitleIoEnvironmentProvider = Provider<SubtitleIoEnvironment>((ref) {
  final runtime = ref.watch(editorRuntimeProvider);
  if (runtime == null) throw EditorNotConfiguredError('subtitleIoEnvironmentProvider');
  final engine = ref.watch(editorEngineProvider);
  const fs = LocalStoreFs();
  return SubtitleIoEnvironment(
    picker: engine.picker,
    files: engine.files,
    fs: fs,
    deleter: OwnedFileDeleter(runtime.roots, fs: fs),
    workDir: runtime.roots.workDir,
  );
}, name: 'subtitleIoEnvironmentProvider');

// =================================================================================================
// Model
// =================================================================================================

/// The pure parts of the flows (unit-tested).
abstract final class SubtitleIo {
  /// The largest file the import reads (subtitle files are rarely above a few MB).
  static const int maxBytes = 20 * 1024 * 1024;

  /// The longest track name taken from a file name.
  static const int maxTrackName = 40;

  /// Issues listed in the import sheet; the rest are counted.
  static const int maxListedIssues = 5;

  /// Prefix of the export folders under `work/`.
  static const String exportFolderPrefix = 'subtitles-';

  static final RegExp _language = RegExp(r'^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$');

  /// The format named by the extension of [name], or null.
  static SubtitleFormat? formatOf(String name) {
    final ext = p.extension(name.split('?').first).toLowerCase();
    return switch (ext) {
      '.srt' => SubtitleFormat.srt,
      '.vtt' => SubtitleFormat.vtt,
      _ => null,
    };
  }

  /// The track name and language a file name suggests: `movie.en.srt` -> (`movie`, `en`),
  /// `Talk.srt` -> (`Talk`, null). Long names are cut to [maxTrackName] characters.
  static (String name, String? language) trackNameOf(String fileName) {
    var stem = p.basename(fileName.trim());
    final ext = stem.lastIndexOf('.');
    if (ext >= 0) stem = stem.substring(0, ext);
    String? language;
    final dot = stem.lastIndexOf('.');
    if (dot > 0) {
      final tag = stem.substring(dot + 1);
      if (_language.hasMatch(tag)) {
        language = tag;
        stem = stem.substring(0, dot);
      }
    }
    var name = stem.trim();
    final chars = name.characters;
    if (chars.length > maxTrackName) name = chars.take(maxTrackName).toString().trim();
    return (name, language);
  }

  /// The parsed cues as drafts for `ImportSubtitles`.
  static List<SubtitleCueDraft> draftsOf(SubtitleParseResult result) => [
        for (final c in result.cues)
          if (c.endUs >= c.startUs) SubtitleCueDraft(TimeRange(c.startUs, c.endUs), c.text),
      ];

  /// The cues of [track] for `SubtitleCodec.serialize`.
  static List<SubtitleCueData> cuesOf(Track track) => [
        for (final i in track.items)
          if (i is SubtitleCue) SubtitleCueData(i.start, i.end, i.text),
      ];

  /// The BCP-47 tag of [track] (its language, else the generator's, else `und`).
  static String languageOf(Track track) {
    final data = track.subtitle;
    final tag = data?.language ?? data?.provenance?.language;
    return tag == null || tag.trim().isEmpty ? 'und' : tag.trim();
  }

  /// `<project>.<bcp47>.srt|vtt` for [track] of [project].
  static String exportFileName(EditProject project, Track track, SubtitleFormat format) =>
      SubtitleCodec.suggestedFileName(project.name, languageOf(track), format);

  /// The subtitle tracks of [project] that have captions, topmost first.
  static List<Track> exportableTracks(EditProject project) =>
      [for (final t in SubtitlesPanelModel.subtitleTracks(project)) if (t.items.any((i) => i is SubtitleCue)) t];

  /// Whether [track]'s captions came from Auto captions.
  static bool isGenerated(Track track) =>
      track.subtitle?.provenance != null || track.items.any((i) => i is SubtitleCue && i.origin == CueOrigin.generated);

  /// The track a replace defaults to: [preferred] when it is an unlocked subtitle track, else the
  /// topmost unlocked one; null when there is none.
  static TrackId? replaceTargetIn(EditProject project, TrackId? preferred) {
    final tracks = SubtitlesPanelModel.subtitleTracks(project);
    for (final t in tracks) {
      if (t.id == preferred && !t.locked) return t.id;
    }
    for (final t in tracks) {
      if (!t.locked) return t.id;
    }
    return null;
  }

  /// The command for [choice] on [preview].
  static ImportSubtitles commandFor(SubtitleImportPreview preview, SubtitleImportChoice choice) => switch (choice.mode) {
        SubtitleImportMode.newTrack => ImportSubtitles(preview.drafts, name: preview.trackName, language: preview.language),
        SubtitleImportMode.replace => ImportSubtitles(preview.drafts, mode: SubtitleImportMode.replace, track: choice.track),
      };
}

// =================================================================================================
// Import
// =================================================================================================

/// A parsed file, ready for the result sheet.
@immutable
final class SubtitleImportPreview {
  /// Creates a preview of [result] read from [fileName]; the new track's name and language come
  /// from the file name (`movie.en.srt` -> `movie`, `en`).
  factory SubtitleImportPreview({required String fileName, required SubtitleParseResult result}) {
    final (name, language) = SubtitleIo.trackNameOf(fileName);
    return SubtitleImportPreview._(fileName, result, SubtitleIo.draftsOf(result), name, language);
  }

  const SubtitleImportPreview._(this.fileName, this.result, this.drafts, this.trackName, this.language);

  /// The picked file's name.
  final String fileName;

  /// What the codec read.
  final SubtitleParseResult result;

  /// The cues to import.
  final List<SubtitleCueDraft> drafts;

  /// Name of a new track ('' lets the lane take its default name).
  final String trackName;

  /// Language of a new track, from the file name.
  final String? language;

  /// Whether anything can be imported.
  bool get canImport => drafts.isNotEmpty;
}

/// Outcome of [SubtitleImporter.pickAndLoad].
sealed class SubtitleLoadResult {
  const SubtitleLoadResult();
}

/// The picker was dismissed.
final class SubtitleLoadCancelled extends SubtitleLoadResult {
  /// Creates the result.
  const SubtitleLoadCancelled();
}

/// The file could not be read; [message] is ready to show.
final class SubtitleLoadFailed extends SubtitleLoadResult {
  /// Creates the result.
  const SubtitleLoadFailed(this.message);

  /// Copy for the user.
  final String message;
}

/// The file was parsed (possibly with nothing to import).
final class SubtitleLoaded extends SubtitleLoadResult {
  /// Creates the result.
  const SubtitleLoaded(this.preview);

  /// The preview.
  final SubtitleImportPreview preview;
}

/// Picks and parses one SRT/VTT file.
final class SubtitleImporter {
  /// Creates the importer over [env].
  const SubtitleImporter(this.env);

  /// The collaborators.
  final SubtitleIoEnvironment env;

  /// Shows the Files picker for subtitle files and reads the choice.
  Future<SubtitleLoadResult> pickAndLoad() async {
    final List<PickedMedia> picks;
    try {
      picks = await env.picker.pick(const MediaPickRequest(source: MediaPickSource.files, kinds: {MediaPickKind.subtitle}, multiple: false));
    } on Object catch (e) {
      debugPrint('[SubtitleIo] Picker failed: ${e.runtimeType}');
      return const SubtitleLoadFailed(SubtitleIoStrings.pickerFailed);
    }
    if (picks.isEmpty) return const SubtitleLoadCancelled();
    return load(picks.first);
  }

  /// Reads and parses [picked].
  Future<SubtitleLoadResult> load(PickedMedia picked) async {
    final name = picked.displayName.trim().isEmpty ? p.basename(picked.uri) : picked.displayName.trim();
    try {
      final size = picked.sizeBytes;
      if (size != null && size > SubtitleIo.maxBytes) return SubtitleLoadFailed(SubtitleIoStrings.tooLarge(SubtitleIo.maxBytes ~/ (1024 * 1024)));
      final Uint8List? bytes;
      try {
        bytes = await env.readPick(picked);
      } on SubtitleFileTooLarge {
        return SubtitleLoadFailed(SubtitleIoStrings.tooLarge(SubtitleIo.maxBytes ~/ (1024 * 1024)));
      } on StoreFailure catch (e) {
        debugPrint('[SubtitleIo] Read failed: ${e.kind}');
        return const SubtitleLoadFailed(SubtitleIoStrings.cannotOpen);
      }
      if (bytes == null) return const SubtitleLoadFailed(SubtitleIoStrings.cannotOpen);
      final hint = SubtitleIo.formatOf(name) ?? SubtitleIo.formatOf(picked.uri);
      final result = await env.parse(bytes, hint);
      return SubtitleLoaded(SubtitleImportPreview(fileName: name, result: result));
    } on Object catch (e) {
      debugPrint('[SubtitleIo] Import read failed: ${e.runtimeType}');
      return const SubtitleLoadFailed(SubtitleIoStrings.readFailed);
    } finally {
      if (picked.isTemporaryCopy) await _deleteTemporary(picked);
    }
  }

  Future<void> _deleteTemporary(PickedMedia picked) async {
    final path = ImportPolicy.pathOf(picked.uri);
    if (path == null) return;
    try {
      await env.deleter.delete(path);
    } on Object catch (e) {
      debugPrint('[SubtitleIo] Could not delete a picked copy: ${e.runtimeType}');
    }
  }
}

/// Where the user chose to put the captions.
@immutable
final class SubtitleImportChoice {
  /// Creates a choice; [track] is required for [SubtitleImportMode.replace].
  const SubtitleImportChoice(this.mode, {this.track});

  /// New track or replace.
  final SubtitleImportMode mode;

  /// The track to replace.
  final TrackId? track;

  @override
  bool operator ==(Object other) => other is SubtitleImportChoice && other.mode == mode && other.track == track;

  @override
  int get hashCode => Object.hash(mode, track);

  @override
  String toString() => 'SubtitleImportChoice(${mode.name}, $track)';
}

/// Shows the import result sheet for [preview] over [project]; null when dismissed or when there
/// was nothing to import.
Future<SubtitleImportChoice?> showSubtitleImportSheet(
  BuildContext context, {
  required SubtitleImportPreview preview,
  required EditProject project,
  TrackId? replaceTarget,
}) =>
    showDanaviewSheet<SubtitleImportChoice>(
      context,
      title: SubtitleIoStrings.importTitle,
      builder: (context) => SubtitleImportSheet(
        preview: preview,
        project: project,
        replaceTarget: replaceTarget,
        onDone: (choice) => Navigator.of(context).pop(choice),
      ),
    );

/// The import result: what was read, what was skipped, and where the captions go.
class SubtitleImportSheet extends StatefulWidget {
  /// Creates the sheet content.
  const SubtitleImportSheet({super.key, required this.preview, required this.project, required this.onDone, this.replaceTarget});

  /// The parsed file.
  final SubtitleImportPreview preview;

  /// The project (its subtitle tracks).
  final EditProject project;

  /// The default track of Replace.
  final TrackId? replaceTarget;

  /// Called with the choice (null: cancelled).
  final ValueChanged<SubtitleImportChoice?> onDone;

  @override
  State<SubtitleImportSheet> createState() => _SubtitleImportSheetState();
}

class _SubtitleImportSheetState extends State<SubtitleImportSheet> {
  SubtitleImportMode _mode = SubtitleImportMode.newTrack;
  TrackId? _target;

  @override
  void initState() {
    super.initState();
    _target = SubtitleIo.replaceTargetIn(widget.project, widget.replaceTarget);
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final result = preview.result;
    final n = preview.drafts.length;
    final encoding = SubtitleIoStrings.encodingNote(result.detectedEncoding);
    final issues = result.issues;
    final tracks = SubtitlesPanelModel.subtitleTracks(widget.project);
    final canReplace = _target != null;
    return Column(
      key: const ValueKey<String>('subtitleIo.import'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          preview.canImport ? SubtitleIoStrings.found(n, preview.fileName) : SubtitleIoStrings.nothingFound(preview.fileName),
          key: const ValueKey<String>('subtitleIo.headline'),
          style: _style(DanaviewTextStyles.headline),
        ),
        const SizedBox(height: DanaviewSpacing.xxs),
        Text(
          result.format == SubtitleFormat.vtt ? SubtitleIoStrings.formatVtt : SubtitleIoStrings.formatSrt,
          style: _style(DanaviewTextStyles.caption, DanaviewColors.textSecondary),
        ),
        const SizedBox(height: DanaviewSpacing.sm),
        if (!preview.canImport) _Note(SubtitleIoStrings.nothingNextStep, icon: Icons.info_outline_rounded),
        if (encoding != null)
          _Note(
            encoding,
            key: const ValueKey<String>('subtitleIo.encoding'),
            icon: SubtitleIoStrings.isFallback(result.detectedEncoding) ? Icons.warning_amber_rounded : Icons.info_outline_rounded,
            color: SubtitleIoStrings.isFallback(result.detectedEncoding) ? DanaviewColors.warning : DanaviewColors.textSecondary,
          ),
        if (result.strippedTags > 0)
          _Note(SubtitleIoStrings.strippedTags(result.strippedTags), key: const ValueKey<String>('subtitleIo.stripped'), icon: Icons.format_clear_rounded),
        if (result.ignoredSettings > 0)
          _Note(SubtitleIoStrings.ignoredSettings(result.ignoredSettings), key: const ValueKey<String>('subtitleIo.ignored'), icon: Icons.info_outline_rounded),
        if (issues.isNotEmpty) _Issues(issues),
        if (preview.canImport) ...[
          DanaviewSectionHeader(SubtitleIoStrings.destination, padding: const EdgeInsets.fromLTRB(0, DanaviewSpacing.md, 0, DanaviewSpacing.sm)),
          DanaviewSegmentedControl<SubtitleImportMode>(
            key: const ValueKey<String>('subtitleIo.mode'),
            value: _mode,
            options: [
              const DanaviewOption(value: SubtitleImportMode.newTrack, label: SubtitleIoStrings.newTrack, icon: Icons.add_rounded),
              DanaviewOption(value: SubtitleImportMode.replace, label: SubtitleIoStrings.replaceTrack, icon: Icons.swap_horiz_rounded, enabled: canReplace),
            ],
            onChanged: (m) => setState(() => _mode = m),
          ),
          const SizedBox(height: DanaviewSpacing.sm),
          if (_mode == SubtitleImportMode.newTrack)
            _Note(
              SubtitleIoStrings.newTrackNote(
                preview.trackName.isEmpty ? SubtitleStrings.laneName(tracks.length + 1) : preview.trackName,
                preview.language,
              ),
              icon: Icons.closed_caption_rounded,
              color: DanaviewColors.textSecondary,
            )
          else ...[
            for (final t in tracks)
              DanaviewListTile(
                key: ValueKey<String>('subtitleIo.track.${t.id.value}'),
                title: SubtitlesPanelModel.nameOf(widget.project, t),
                subtitle: t.locked ? '${SubtitleIoStrings.cueCount(t.items.length)} · ${SubtitleIoStrings.locked}' : SubtitleIoStrings.cueCount(t.items.length),
                leading: Icon(t.locked ? Icons.lock_rounded : Icons.closed_caption_rounded, size: 20, color: DanaviewColors.textSecondary),
                trailing: t.id == _target ? const Icon(Icons.check_rounded, size: 20, color: DanaviewColors.primaryLight) : null,
                selected: t.id == _target,
                enabled: !t.locked,
                dense: true,
                onTap: () => setState(() => _target = t.id),
              ),
            if (_targetTrack(tracks) case final Track t)
              Padding(
                padding: const EdgeInsets.only(top: DanaviewSpacing.xs),
                child: _Note(
                  SubtitleIoStrings.replaceNote(t.items.length, SubtitlesPanelModel.nameOf(widget.project, t)),
                  icon: Icons.info_outline_rounded,
                  color: DanaviewColors.textSecondary,
                ),
              ),
          ],
          if (!canReplace) _Note(SubtitleIoStrings.noReplaceTarget, icon: Icons.info_outline_rounded, color: DanaviewColors.textMuted),
        ],
        const SizedBox(height: DanaviewSpacing.lg),
        if (preview.canImport)
          DanaviewButtonBar(
            children: [
              DanaviewButton.secondary(label: SubtitleIoStrings.cancel, onPressed: () => widget.onDone(null)),
              DanaviewButton.primary(
                key: const ValueKey<String>('subtitleIo.importButton'),
                label: SubtitleIoStrings.importAction,
                icon: Icons.file_download_outlined,
                onPressed: _mode == SubtitleImportMode.replace && _target == null ? null : _confirm,
              ),
            ],
          )
        else
          DanaviewButton.secondary(
            key: const ValueKey<String>('subtitleIo.closeButton'),
            label: SubtitleIoStrings.close,
            expand: true,
            onPressed: () => widget.onDone(null),
          ),
      ],
    );
  }

  Track? _targetTrack(List<Track> tracks) {
    for (final t in tracks) {
      if (t.id == _target) return t;
    }
    return null;
  }

  void _confirm() {
    widget.onDone(_mode == SubtitleImportMode.newTrack
        ? const SubtitleImportChoice(SubtitleImportMode.newTrack)
        : SubtitleImportChoice(SubtitleImportMode.replace, track: _target));
  }
}

class _Issues extends StatelessWidget {
  const _Issues(this.issues);

  final List<SubtitleIssue> issues;

  @override
  Widget build(BuildContext context) {
    final listed = issues.take(SubtitleIo.maxListedIssues).toList();
    final more = issues.length - listed.length;
    return Padding(
      key: const ValueKey<String>('subtitleIo.issues'),
      padding: const EdgeInsets.only(top: DanaviewSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Note(SubtitleIoStrings.problemsHeading(issues.length), icon: Icons.warning_amber_rounded),
          for (final i in listed)
            Padding(
              padding: const EdgeInsets.only(left: 26, bottom: DanaviewSpacing.xxs),
              child: Text(SubtitleIoStrings.issue(i.line, i.kind), style: _style(DanaviewTextStyles.caption, DanaviewColors.textSecondary)),
            ),
          if (more > 0)
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Text(SubtitleIoStrings.moreProblems(more), style: _style(DanaviewTextStyles.caption, DanaviewColors.textMuted)),
            ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {super.key, required this.icon, this.color = DanaviewColors.warning});

  final String text;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: DanaviewSpacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: ExcludeSemantics(child: Icon(icon, size: 18, color: color))),
            const SizedBox(width: DanaviewSpacing.sm),
            Expanded(child: Text(text, style: _style(DanaviewTextStyles.caption, color))),
          ],
        ),
      );
}

TextStyle _style(TextStyle base, [Color? color]) => base.copyWith(fontFamily: DanaviewFonts.family, color: color);

// =================================================================================================
// Export
// =================================================================================================

/// Where the exported file goes.
enum SubtitleHandoff {
  /// The system's save dialog (Files / SAF).
  files,

  /// The share sheet.
  share,
}

/// What the user chose in the export sheet.
@immutable
final class SubtitleExportChoice {
  /// Creates a choice.
  const SubtitleExportChoice({required this.track, required this.format, required this.handoff});

  /// The track.
  final TrackId track;

  /// SRT or VTT.
  final SubtitleFormat format;

  /// Files or share.
  final SubtitleHandoff handoff;

  @override
  bool operator ==(Object other) => other is SubtitleExportChoice && other.track == track && other.format == format && other.handoff == handoff;

  @override
  int get hashCode => Object.hash(track, format, handoff);
}

/// How an export ended.
enum SubtitleExportStatus {
  /// Saved or shared.
  done,

  /// The user closed the system sheet.
  cancelled,

  /// Saving was not allowed.
  denied,

  /// The file could not be written.
  writeFailed,

  /// The handoff failed.
  failed,
}

/// Result of [SubtitleExporter.export].
@immutable
final class SubtitleExportOutcome {
  /// Creates an outcome.
  const SubtitleExportOutcome(this.status, this.fileName);

  /// How it ended.
  final SubtitleExportStatus status;

  /// The suggested file name.
  final String fileName;
}

/// Writes a track to a temporary SRT/VTT file, hands it over and deletes it.
final class SubtitleExporter {
  /// Creates the exporter over [env].
  const SubtitleExporter(this.env);

  /// The collaborators.
  final SubtitleIoEnvironment env;

  /// The bytes of [track] in [format].
  static Uint8List bytesOf(Track track, SubtitleFormat format) => SubtitleCodec.serialize(SubtitleIo.cuesOf(track), format);

  /// Exports [track] of [project] as [format] through [handoff].
  Future<SubtitleExportOutcome> export(EditProject project, Track track, SubtitleFormat format, SubtitleHandoff handoff) async {
    final name = SubtitleIo.exportFileName(project, track, format);
    await _sweep();
    final dir = p.join(env.workDir, '${SubtitleIo.exportFolderPrefix}${env.newToken()}');
    final path = p.join(dir, name);
    try {
      try {
        await env.fs.createDirectory(dir);
        await env.fs.writeBytesSynced(path, bytesOf(track, format));
      } on Object catch (e) {
        debugPrint('[SubtitleIo] Could not write the caption file: ${e.runtimeType}');
        return SubtitleExportOutcome(SubtitleExportStatus.writeFailed, name);
      }
      try {
        final r = switch (handoff) {
          SubtitleHandoff.files => await env.files.saveToFiles(path, name),
          SubtitleHandoff.share => await env.files.share(path),
        };
        final status = switch (r.outcome) {
          FileHandoffOutcome.done => SubtitleExportStatus.done,
          FileHandoffOutcome.cancelled => SubtitleExportStatus.cancelled,
          FileHandoffOutcome.denied => SubtitleExportStatus.denied,
          FileHandoffOutcome.failed => SubtitleExportStatus.failed,
        };
        return SubtitleExportOutcome(status, name);
      } on Object catch (e) {
        debugPrint('[SubtitleIo] Handoff failed: ${e.runtimeType}');
        return SubtitleExportOutcome(SubtitleExportStatus.failed, name);
      }
    } finally {
      await _delete(dir);
    }
  }

  /// Removes export folders an earlier run could not delete.
  Future<void> _sweep() async {
    try {
      if (!(await env.fs.stat(env.workDir)).exists) return;
      for (final e in await env.fs.list(env.workDir)) {
        if (e.type == StoreEntityType.directory && p.basename(e.path).startsWith(SubtitleIo.exportFolderPrefix)) await _delete(e.path);
      }
    } on Object catch (e) {
      debugPrint('[SubtitleIo] Could not list the work folder: ${e.runtimeType}');
    }
  }

  Future<void> _delete(String dir) async {
    try {
      await env.deleter.delete(dir, recursive: true);
    } on Object catch (e) {
      debugPrint('[SubtitleIo] Could not delete a temporary caption file: ${e.runtimeType}');
    }
  }
}

/// Shows the export sheet over [project]; null when dismissed. [initialTrack] is preselected
/// when it has captions.
Future<SubtitleExportChoice?> showSubtitleExportSheet(BuildContext context, {required EditProject project, TrackId? initialTrack}) =>
    showDanaviewSheet<SubtitleExportChoice>(
      context,
      title: SubtitleIoStrings.exportTitle,
      builder: (context) => SubtitleExportSheet(
        project: project,
        initialTrack: initialTrack,
        onDone: (choice) => Navigator.of(context).pop(choice),
      ),
    );

/// The export sheet: track (when there are several), SRT or VTT, the file name, Save to Files and
/// Share.
class SubtitleExportSheet extends StatefulWidget {
  /// Creates the sheet content.
  const SubtitleExportSheet({super.key, required this.project, required this.onDone, this.initialTrack});

  /// The project.
  final EditProject project;

  /// The preselected track.
  final TrackId? initialTrack;

  /// Called with the choice (null: cancelled).
  final ValueChanged<SubtitleExportChoice?> onDone;

  @override
  State<SubtitleExportSheet> createState() => _SubtitleExportSheetState();
}

class _SubtitleExportSheetState extends State<SubtitleExportSheet> {
  SubtitleFormat _format = SubtitleFormat.srt;
  TrackId? _track;

  @override
  void initState() {
    super.initState();
    final tracks = SubtitleIo.exportableTracks(widget.project);
    _track = tracks.any((t) => t.id == widget.initialTrack) ? widget.initialTrack : (tracks.isEmpty ? null : tracks.first.id);
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    final tracks = SubtitleIo.exportableTracks(project);
    Track? track;
    for (final t in tracks) {
      if (t.id == _track) track = t;
    }
    final name = track == null ? null : SubtitleIo.exportFileName(project, track, _format);
    return Column(
      key: const ValueKey<String>('subtitleIo.export'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (tracks.length > 1) ...[
          DanaviewSectionHeader(SubtitleIoStrings.exportTrack, padding: const EdgeInsets.fromLTRB(0, 0, 0, DanaviewSpacing.sm)),
          for (final t in tracks)
            DanaviewListTile(
              key: ValueKey<String>('subtitleIo.exportTrack.${t.id.value}'),
              title: SubtitlesPanelModel.nameOf(project, t),
              subtitle: SubtitleIo.isGenerated(t)
                  ? '${SubtitleIoStrings.cueCount(SubtitleIo.cuesOf(t).length)} · ${SubtitleIoStrings.generated}'
                  : SubtitleIoStrings.cueCount(SubtitleIo.cuesOf(t).length),
              leading: Icon(SubtitleIo.isGenerated(t) ? Icons.auto_awesome_rounded : Icons.closed_caption_rounded, size: 20, color: DanaviewColors.textSecondary),
              trailing: t.id == _track ? const Icon(Icons.check_rounded, size: 20, color: DanaviewColors.primaryLight) : null,
              selected: t.id == _track,
              dense: true,
              onTap: () => setState(() => _track = t.id),
            ),
        ],
        DanaviewSectionHeader(SubtitleIoStrings.exportFormat, padding: const EdgeInsets.fromLTRB(0, DanaviewSpacing.sm, 0, DanaviewSpacing.sm)),
        DanaviewSegmentedControl<SubtitleFormat>(
          key: const ValueKey<String>('subtitleIo.format'),
          value: _format,
          options: const [
            DanaviewOption(value: SubtitleFormat.srt, label: SubtitleIoStrings.srt),
            DanaviewOption(value: SubtitleFormat.vtt, label: SubtitleIoStrings.vtt),
          ],
          onChanged: (f) => setState(() => _format = f),
        ),
        const SizedBox(height: DanaviewSpacing.sm),
        Text(
          _format == SubtitleFormat.srt ? SubtitleIoStrings.srtHint : SubtitleIoStrings.vttHint,
          style: _style(DanaviewTextStyles.caption, DanaviewColors.textSecondary),
        ),
        if (name != null) ...[
          DanaviewSectionHeader(SubtitleIoStrings.fileName, padding: const EdgeInsets.fromLTRB(0, DanaviewSpacing.md, 0, DanaviewSpacing.xs)),
          Text(name, key: const ValueKey<String>('subtitleIo.fileName'), style: _style(DanaviewTextStyles.body)),
        ],
        const SizedBox(height: DanaviewSpacing.lg),
        DanaviewButtonBar(
          children: [
            DanaviewButton.secondary(
              key: const ValueKey<String>('subtitleIo.share'),
              label: SubtitleIoStrings.share,
              icon: Icons.ios_share_rounded,
              onPressed: track == null ? null : () => _done(SubtitleHandoff.share),
            ),
            DanaviewButton.primary(
              key: const ValueKey<String>('subtitleIo.saveToFiles'),
              label: SubtitleIoStrings.saveToFiles,
              icon: Icons.save_alt_rounded,
              onPressed: track == null ? null : () => _done(SubtitleHandoff.files),
            ),
          ],
        ),
      ],
    );
  }

  void _done(SubtitleHandoff handoff) {
    final track = _track;
    if (track == null) return;
    widget.onDone(SubtitleExportChoice(track: track, format: _format, handoff: handoff));
  }
}
