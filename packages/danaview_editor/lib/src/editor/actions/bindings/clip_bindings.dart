// OWNER: UX-35
//
// The clip action bindings (merged by wiring/action_bindings.dart, ARCH §17.6, ux.md §10.15):
//
// * `reverse` toggles reverse on the selected video clip through `TasksController.reverse` (one
//   history entry; the rendition job starts when none is usable). Undo restores the forward clip.
// * `freeze` asks for the still's duration (default 3 s) in `FreezeFrameSheet`, then
//   `TasksController.freeze` splits at the playhead and inserts a pending still.
// * `replace` picks one file of a kind the clip's lane takes (video lanes: video or image; audio
//   lanes: audio), imports it through UX-06's import sheet without placing it, then applies
//   `ReplaceMedia` (effects, transform and range kept); shorter media trims the clip with the toast
//   "The new video is shorter, so the clip was trimmed to 0:04."
// * `clipInfo` opens the clip info panel (also on locked tracks: it only reads).
// * `tasks` opens the Tasks sheet.
//
// Labels, icons and shortcuts come from the registry (UX-15); copy from `ClipStrings`.

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart' show Icons;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show EditNoticeCodes, ReplaceMedia;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show MediaPickKind, MediaPickRequest, MediaPickSource;
import 'package:danaview_ui_kit/danaview_ui_kit.dart' show DanaviewToast, DanaviewToastKind;

import '../../../app/editor_providers.dart';
import '../../../app/strings/clip_strings.dart';
import '../../contracts/contracts.dart';
import '../../flows/import_media_sheet.dart' show ImportItemResult, showImportMediaSheet;
import '../../flows/tasks_sheet.dart';
import '../../state/editor_controller.dart';
import '../../state/tasks_controller.dart';
import '../../timeline/timeline_semantics.dart' show editorAnnounce;
import 'media_bindings.dart' show MediaOperations;

/// Default length of a freeze frame (ux.md §10.15).
const TimeUs defaultFreezeDuration = 3 * microsPerSecond;

/// Why a clip action can't run on the selection.
enum ClipBlocker {
  /// The project does not accept edits.
  notEditable,

  /// No clip is selected.
  noClip,

  /// The clip is not a video clip.
  notVideo,

  /// Its track is locked.
  locked,

  /// The playhead is not over the clip (freeze).
  playheadOutside,

  /// Read-only projects can't import (replace).
  readOnly,

  /// The clip's media is gone from the pool.
  mediaMissing,
}

/// The message of [blocker].
String clipBlockerMessage(ClipBlocker blocker) => switch (blocker) {
      ClipBlocker.notEditable => ClipStrings.notEditable,
      ClipBlocker.noClip => ClipStrings.selectClip,
      ClipBlocker.notVideo => ClipStrings.selectVideo,
      ClipBlocker.locked => ClipStrings.trackLocked,
      ClipBlocker.playheadOutside => ClipStrings.playheadOutside,
      ClipBlocker.readOnly => ClipStrings.readOnly,
      ClipBlocker.mediaMissing => ClipStrings.mediaMissing,
    };

EditorController _editor(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId).notifier);

/// The primary selected clip and its track, or null.
(MediaClip, Track)? selectedClipOf(EditorActionContext ctx) {
  final state = ctx.read(editorControllerProvider(ctx.projectId));
  final project = state.project;
  final primary = state.selection.primary;
  if (project == null || primary == null) return null;
  final loc = project.index.locate(primary);
  final item = loc?.item;
  if (loc == null || item is! MediaClip) return null;
  return (item, loc.track);
}

MediaAsset? _assetOf(EditorActionContext ctx, MediaClip clip) =>
    ctx.read(editorControllerProvider(ctx.projectId)).project?.pool[clip.media];

/// Why reverse can't run, or null.
ClipBlocker? reverseBlocker(EditorActionContext ctx) {
  if (!_editor(ctx).canEdit) return ClipBlocker.notEditable;
  final sel = selectedClipOf(ctx);
  if (sel == null) return ClipBlocker.noClip;
  final asset = _assetOf(ctx, sel.$1);
  if (asset == null) return ClipBlocker.mediaMissing;
  if (asset.kind != MediaKind.video || sel.$1.visual == null) return ClipBlocker.notVideo;
  if (sel.$2.locked) return ClipBlocker.locked;
  return null;
}

/// Why freeze frame can't run, or null.
ClipBlocker? freezeBlocker(EditorActionContext ctx) {
  final blocker = reverseBlocker(ctx);
  if (blocker != null) return blocker;
  final clip = selectedClipOf(ctx)!.$1;
  final project = ctx.read(editorControllerProvider(ctx.projectId)).project!;
  final t = project.settings.frameRate.quantize(ctx.read(playheadProvider(ctx.projectId)).value);
  if (t < clip.start || t >= clip.end) return ClipBlocker.playheadOutside;
  return null;
}

/// Why replace can't run, or null.
ClipBlocker? replaceBlocker(EditorActionContext ctx) {
  final editor = _editor(ctx);
  if (!editor.canEdit) return ClipBlocker.notEditable;
  if (editor.readOnly) return ClipBlocker.readOnly;
  final sel = selectedClipOf(ctx);
  if (sel == null) return ClipBlocker.noClip;
  if (sel.$2.locked) return ClipBlocker.locked;
  return null;
}

/// The pick kinds a clip on [lane] can be replaced with (ux.md §10.15).
Set<MediaPickKind> replacePickKinds(TrackKind lane) =>
    lane == TrackKind.audio ? const {MediaPickKind.audio} : const {MediaPickKind.video, MediaPickKind.image};

/// "0:04" (m:ss, rounded down to whole seconds).
String clipLengthLabel(TimeUs t) {
  final total = t ~/ microsPerSecond;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final sec = (total % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

// ---- Reverse ------------------------------------------------------------------------------------

void _reverse(EditorActionContext ctx) {
  if (reverseBlocker(ctx) != null) return;
  final clip = selectedClipOf(ctx)!.$1;
  final result = ctx.read(tasksControllerProvider(ctx.projectId)).reverse(clip.id);
  if (result is EditApplied && ctx.context.mounted) {
    editorAnnounce(ctx.context, clip.reversed ? ClipStrings.reverseOff : ClipStrings.reverseOn);
  }
}

// ---- Freeze -------------------------------------------------------------------------------------

Future<void> _freeze(EditorActionContext ctx) async {
  if (freezeBlocker(ctx) != null) return;
  final clip = selectedClipOf(ctx)!.$1;
  final at = ctx.read(playheadProvider(ctx.projectId)).value;
  final context = ctx.context;
  // Read before the sheet: the provider must exist while the editor is open.
  final tasks = ctx.read(tasksControllerProvider(ctx.projectId));
  final duration = await FreezeFrameSheet.show(context);
  if (duration == null) return;
  final result = tasks.freeze(clip.id, at, duration);
  if (result is EditApplied && context.mounted) editorAnnounce(context, ClipStrings.freezeInserted);
}

// ---- Replace ------------------------------------------------------------------------------------

Future<void> _replace(EditorActionContext ctx) async {
  if (replaceBlocker(ctx) != null) return;
  final (clip, track) = selectedClipOf(ctx)!;
  final ops = MediaOperations.of(ctx);
  final context = ctx.context;
  final kinds = replacePickKinds(track.kind);
  try {
    final picked = await ctx.read(editorEngineProvider).picker.pick(MediaPickRequest(
          source: track.kind == TrackKind.audio ? MediaPickSource.files : MediaPickSource.photos,
          kinds: kinds,
          multiple: false,
        ));
    if (picked.isEmpty || !context.mounted) return;
    final edit = ops.session.editOrNull;
    if (edit == null) return;
    final job = ops.importJob(pool: ctx.read(mediaPoolServiceProvider), edit: edit, place: false);
    final result = await showImportMediaSheet(context, picks: picked.take(1).toList(), job: job, title: ClipStrings.replaceImportTitle);
    MediaAsset? asset;
    for (final i in result?.job?.items ?? const <ImportItemResult>[]) {
      asset ??= i.asset;
    }
    if (!context.mounted) return;
    if (asset == null) return;
    final current = ops.project?.pool[asset.id] ?? asset;
    // The selection may have moved while the sheet was up: replace the clip the user chose.
    if (ops.project?.index.locate(clip.id) == null) return;
    final blocker = ops.replaceBlocker(current);
    if (blocker != null && ops.selectedClip?.id == clip.id) {
      DanaviewToast.show(context, blocker, icon: Icons.info_outline_rounded);
      return;
    }
    final applied = _editor(ctx).apply(ReplaceMedia(clip.id, current.id));
    if (applied is! EditApplied || !context.mounted) return;
    if (applied.notices.any((n) => n.code == EditNoticeCodes.trimmedToFit)) {
      final now = ops.project?.index.item(clip.id);
      final length = clipLengthLabel(now is MediaClip ? now.duration : clip.duration);
      final message = ClipStrings.replaceTrimmed(current.kind, length);
      DanaviewToast.show(context, message, icon: Icons.content_cut_rounded);
      editorAnnounce(context, message);
    } else {
      editorAnnounce(context, ClipStrings.replaced);
    }
  } on Object catch (e) {
    debugPrint('[ClipBindings] Replace failed: ${e.runtimeType}');
    if (context.mounted) {
      DanaviewToast.show(context, ClipStrings.pickerFailed, icon: Icons.error_outline_rounded, kind: DanaviewToastKind.error);
    }
  }
}

// ---- Info and tasks -----------------------------------------------------------------------------

String? _infoReason(EditorActionContext ctx) {
  if (!ctx.read(editorControllerProvider(ctx.projectId)).isReady) return ClipStrings.notEditable;
  return selectedClipOf(ctx) == null ? ClipStrings.selectClip : null;
}

bool _canInfo(EditorActionContext ctx) => _infoReason(ctx) == null;

void _info(EditorActionContext ctx) {
  final sel = selectedClipOf(ctx);
  if (sel == null) return;
  _editor(ctx).openInspector(ClipInfoInspector(sel.$1.id));
}

bool _ready(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId)).isReady;

String? _notReady(EditorActionContext ctx) => ClipStrings.notEditable;

Future<void> _tasks(EditorActionContext ctx) async {
  // Keeps the controller alive (and the rows current) while the sheet is up.
  ctx.read(tasksControllerProvider(ctx.projectId));
  await TasksSheet.show(ctx.context, projectId: ctx.projectId);
}

/// The clip actions bound by UX-35 (ARCH §17.6). The same instances on every read, so two merges
/// of the bindings compare equal (the wiring test relies on it).
List<EditorActionBinding> get clipBindings => _clipBindings;

final List<EditorActionBinding> _clipBindings = List.unmodifiable(<EditorActionBinding>[
  EditorActionBinding(
    id: EditorActionId.reverse,
    handler: _reverse,
    isEnabled: (ctx) => reverseBlocker(ctx) == null,
    disabledReason: (ctx) => switch (reverseBlocker(ctx)) { final b? => clipBlockerMessage(b), null => null },
  ),
  EditorActionBinding(
    id: EditorActionId.freeze,
    handler: _freeze,
    isEnabled: (ctx) => freezeBlocker(ctx) == null,
    disabledReason: (ctx) => switch (freezeBlocker(ctx)) { final b? => clipBlockerMessage(b), null => null },
  ),
  EditorActionBinding(
    id: EditorActionId.replace,
    handler: _replace,
    isEnabled: (ctx) => replaceBlocker(ctx) == null,
    disabledReason: (ctx) => switch (replaceBlocker(ctx)) { final b? => clipBlockerMessage(b), null => null },
  ),
  const EditorActionBinding(id: EditorActionId.clipInfo, handler: _info, isEnabled: _canInfo, disabledReason: _infoReason),
  const EditorActionBinding(id: EditorActionId.tasks, handler: _tasks, isEnabled: _ready, disabledReason: _notReady),
]);
