// OWNER: UX-32
//
// The subtitle file action bindings (merged by wiring/action_bindings.dart, ARCH §17.6, ux.md
// §10.9). The flows' pieces (environment, parser, sheets, exporter) live in
// `panels/subtitle_io.dart`.
//
// * `importSubtitles` (the captions panel's start state and track menu, the timeline track menu):
//   picker -> parse in an isolate -> the result sheet -> one `ImportSubtitles` (new track, or
//   replacing the chosen track; the selected subtitle lane is the default target) -> the captions
//   panel opens on the imported track, with a toast "Imported 312 captions from movie.srt" (plus
//   the spill / skip notices). Enabled while the project accepts edits and is not read-only.
// * `exportSubtitles`: the export sheet (track, SRT or VTT, Save to Files or Share) -> the
//   temporary file is handed over and deleted. The selected subtitle lane (or the lane of the
//   selected cue, else the topmost) is preselected. Enabled once the project is open and has a
//   subtitle track with captions (generated captions included); works in read-only projects too.
// * Labels, icons and shortcuts come from the registry (UX-15); copy from `SubtitleIoStrings`.

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart' show Icons;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show SubtitleNoticeCodes;
import 'package:danaview_ui_kit/danaview_ui_kit.dart' show DanaviewToast, DanaviewToastKind;

import '../../../app/editor_providers.dart';
import '../../../app/strings/subtitle_io_strings.dart';
import '../../contracts/contracts.dart';
import '../../panels/subtitle_io.dart';
import '../../state/editor_controller.dart';
import '../../timeline/timeline_semantics.dart' show editorAnnounce;
import 'caption_bindings.dart' show captionTargetIn;

EditorController _editor(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId).notifier);

EditProject? _project(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId)).project;

void _toast(EditorActionContext ctx, String message, {DanaviewToastKind kind = DanaviewToastKind.info}) {
  final context = ctx.context;
  if (!context.mounted) return;
  DanaviewToast.show(
    context,
    message,
    kind: kind,
    icon: switch (kind) {
      DanaviewToastKind.error => Icons.error_outline_rounded,
      DanaviewToastKind.success => Icons.check_circle_outline_rounded,
      DanaviewToastKind.info => Icons.info_outline_rounded,
    },
  );
}

SubtitleIoEnvironment? _environment(EditorActionContext ctx) {
  try {
    return ctx.read(subtitleIoEnvironmentProvider);
  } on Object catch (e) {
    debugPrint('[SubtitleIo] Not configured: ${e.runtimeType}');
    return null;
  }
}

// ---- Import -------------------------------------------------------------------------------------

bool _canImport(EditorActionContext ctx) => _editor(ctx).canEdit && !_editor(ctx).readOnly && _project(ctx) != null;

String? _importReason(EditorActionContext ctx) => _editor(ctx).readOnly ? SubtitleIoStrings.readOnly : SubtitleIoStrings.notEditable;

Future<void> _import(EditorActionContext ctx) async {
  if (!_canImport(ctx)) return;
  final env = _environment(ctx);
  if (env == null) {
    _toast(ctx, SubtitleIoStrings.pickerFailed, kind: DanaviewToastKind.error);
    return;
  }
  final loaded = await SubtitleImporter(env).pickAndLoad();
  final context = ctx.context;
  if (!context.mounted) return;
  final SubtitleImportPreview preview;
  switch (loaded) {
    case SubtitleLoadCancelled():
      return;
    case SubtitleLoadFailed(:final message):
      _toast(ctx, message, kind: DanaviewToastKind.error);
      return;
    case SubtitleLoaded(preview: final p):
      preview = p;
  }
  final before = ctx.read(editorControllerProvider(ctx.projectId));
  final project = before.project;
  if (project == null) return;
  final choice = await showSubtitleImportSheet(
    context,
    preview: preview,
    project: project,
    replaceTarget: captionTargetIn(project, before.selection),
  );
  if (choice == null || !context.mounted) return;
  final editor = _editor(ctx);
  final result = editor.apply(SubtitleIo.commandFor(preview, choice));
  if (result is! EditApplied) return;
  final after = ctx.read(editorControllerProvider(ctx.projectId));
  final lane = after.selection.lane;
  if (lane != null) editor.openInspector(SubtitlesInspector(track: lane));
  final count = after.selection.items.length;
  final parts = [SubtitleIoStrings.imported(count, preview.fileName)];
  for (final n in result.notices) {
    final c = n.count;
    if (c <= 0) continue;
    if (n.code == SubtitleNoticeCodes.cuesSpilled) parts.add(SubtitleIoStrings.spilled(c));
    if (n.code == SubtitleNoticeCodes.cuesSkipped) parts.add(SubtitleIoStrings.skipped(c));
  }
  final message = parts.join(' ');
  _toast(ctx, message, kind: DanaviewToastKind.success);
  if (context.mounted) editorAnnounce(context, message);
}

// ---- Export -------------------------------------------------------------------------------------

bool _canExport(EditorActionContext ctx) {
  final project = _project(ctx);
  return project != null && SubtitleIo.exportableTracks(project).isNotEmpty;
}

String? _exportReason(EditorActionContext ctx) => _project(ctx) == null ? SubtitleIoStrings.exportNotReady : SubtitleIoStrings.nothingToExport;

Future<void> _export(EditorActionContext ctx) async {
  final state = ctx.read(editorControllerProvider(ctx.projectId));
  final project = state.project;
  if (project == null || SubtitleIo.exportableTracks(project).isEmpty) return;
  final context = ctx.context;
  final choice = await showSubtitleExportSheet(context, project: project, initialTrack: captionTargetIn(project, state.selection));
  if (choice == null || !context.mounted) return;
  // The sheet may have stayed open across edits: export what the track holds now.
  final now = _project(ctx) ?? project;
  final at = now.index.trackIndexOf(choice.track);
  if (at == null) return;
  final env = _environment(ctx);
  if (env == null) {
    _toast(ctx, SubtitleIoStrings.handoffFailed, kind: DanaviewToastKind.error);
    return;
  }
  final outcome = await SubtitleExporter(env).export(now, now.tracks[at], choice.format, choice.handoff);
  switch (outcome.status) {
    case SubtitleExportStatus.done:
      final message = choice.handoff == SubtitleHandoff.files ? SubtitleIoStrings.saved(outcome.fileName) : SubtitleIoStrings.shared(outcome.fileName);
      _toast(ctx, message, kind: DanaviewToastKind.success);
      if (context.mounted) editorAnnounce(context, message);
    case SubtitleExportStatus.cancelled:
      break;
    case SubtitleExportStatus.denied:
      _toast(ctx, SubtitleIoStrings.handoffDenied, kind: DanaviewToastKind.error);
    case SubtitleExportStatus.writeFailed:
      _toast(ctx, SubtitleIoStrings.writeFailed, kind: DanaviewToastKind.error);
    case SubtitleExportStatus.failed:
      _toast(ctx, SubtitleIoStrings.handoffFailed, kind: DanaviewToastKind.error);
  }
}

/// The subtitle file actions bound by UX-32 (ARCH §17.6). The same instances on every read, so
/// two merges of the bindings compare equal.
List<EditorActionBinding> get subtitleIoBindings => _subtitleIoBindings;

const List<EditorActionBinding> _subtitleIoBindings = <EditorActionBinding>[
  EditorActionBinding(id: EditorActionId.importSubtitles, handler: _import, isEnabled: _canImport, disabledReason: _importReason),
  EditorActionBinding(id: EditorActionId.exportSubtitles, handler: _export, isEnabled: _canExport, disabledReason: _exportReason),
];
