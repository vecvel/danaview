// OWNER: UX-33
//
// The audio action bindings (merged by wiring/action_bindings.dart, ARCH §17.6, ux.md §10.4) and
// `AudioOperations`, the edits shared by the bindings and the audio panel.
//
// * `volume` and `fades` open the audio panel on the selected clip with sound (an audio clip, or a
//   video clip whose media has audio), focused on that section. Enabled while the project accepts
//   edits and the clip's lane is unlocked.
// * `extractAudio` runs core `ExtractAudio` on the selected video clip: a linked audio clip with the
//   same media, range and speed on an `AudioRole.original` lane (created when needed); the video's
//   own audio stops playing. Non-destructive and one history entry ("Extract audio"). Disabled,
//   with the reason, for clips without sound, already extracted audio and locked lanes.
// * `addMusic` is the Add music flow: the files picker (audio only) → UX-06's import sheet
//   (free-space preflight, progress, cancel) through UX-36's `MediaOperations.importJob` → core
//   `InsertMedia` at the playhead of the moment the action ran, with no lane given, so audio files
//   land on the first music-role audio lane that is free there (a new music lane when needed).
//   Not offered while the project is opening or open read-only (imports copy files).
// * Labels, icons and shortcuts come from the registry (UX-15); copy from `AudioStrings`.

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart' show Icons;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show ExtractAudio;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show MediaPickKind, MediaPickRequest, MediaPickSource;
import 'package:danaview_ui_kit/danaview_ui_kit.dart' show DanaviewToast, DanaviewToastKind;

import '../../../app/editor_providers.dart';
import '../../../app/strings/audio_strings.dart';
import '../../contracts/contracts.dart';
import '../../flows/import_media_sheet.dart' show showImportMediaSheet;
import '../../state/editor_controller.dart';
import '../../timeline/timeline_semantics.dart' show editorAnnounce;
import '../../toolbar/tool_sets.dart';
import 'media_bindings.dart' show MediaOperations;

/// Why a clip's audio can't be extracted.
enum ExtractBlocker {
  /// No video clip.
  notVideo,

  /// The video has no sound.
  noAudio,

  /// Its audio already plays from its own clip.
  alreadyExtracted,

  /// Its lane is locked.
  locked,
}

/// The edits behind the audio panel and actions.
abstract final class AudioOperations {
  /// Why [item] of [project] can't have its audio extracted, or null when it can.
  static ExtractBlocker? extractBlocker(EditProject project, ItemId item) {
    final loc = project.index.locate(item);
    final clip = loc?.item;
    if (loc == null || clip is! MediaClip || clip.visual == null) return ExtractBlocker.notVideo;
    final asset = project.pool[clip.media];
    if (asset == null || asset.kind != MediaKind.video) return ExtractBlocker.notVideo;
    if (!asset.probe.hasAudio) return ExtractBlocker.noAudio;
    if (clip.detachedAudio) return ExtractBlocker.alreadyExtracted;
    if (loc.track.locked) return ExtractBlocker.locked;
    return null;
  }

  /// The copy that explains [blocker].
  static String reasonOf(ExtractBlocker blocker) => switch (blocker) {
        ExtractBlocker.notVideo => AudioStrings.extractNeedsVideo,
        ExtractBlocker.noAudio => AudioStrings.extractNoAudio,
        ExtractBlocker.alreadyExtracted => AudioStrings.extractDone,
        ExtractBlocker.locked => AudioStrings.actionTrackLocked,
      };

  /// Extracts the audio of video clip [item] (one history entry). Returns the new audio clip, or
  /// null when the command was refused. [project] reads the project after the edit.
  static ItemId? extract(EditorController editor, ItemId item, EditProject? Function() project) {
    final result = editor.apply(ExtractAudio(item));
    if (result is! EditApplied) return null;
    final now = project();
    return now == null ? null : extractedPartner(now, item);
  }

  /// The audio clip that plays the sound of video clip [item] after an extract (same link group,
  /// same media, no picture), or null.
  static ItemId? extractedPartner(EditProject project, ItemId item) {
    final clip = project.index.item(item);
    if (clip is! MediaClip || clip.link == null) return null;
    for (final track in project.timeline.tracks) {
      if (track.kind != TrackKind.audio) continue;
      for (final other in track.items) {
        if (other is MediaClip && other.id != item && other.link == clip.link && other.media == clip.media && other.visual == null) {
          return other.id;
        }
      }
    }
    return null;
  }
}

// -------------------------------------------------------------------------------------------------
// Targets
// -------------------------------------------------------------------------------------------------

/// The clip the volume and fades actions would edit: the primary selected item when it has sound
/// (`ToolSets.supports(AudioInspector)`), else null. [unlocked] also requires an unlocked lane.
ItemId? audioTarget(EditorActionContext ctx, {bool unlocked = false}) {
  final state = ctx.read(editorControllerProvider(ctx.projectId));
  final project = state.project;
  final primary = state.selection.primary;
  if (project == null || primary == null) return null;
  final loc = project.index.locate(primary);
  if (loc == null || !ToolSets.supports(AudioInspector(primary), loc.item, loc.track, project.pool)) return null;
  if (unlocked && loc.track.locked) return null;
  return primary;
}

EditorController _editor(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId).notifier);

// ---- Volume and fades ---------------------------------------------------------------------------

bool _canOpen(EditorActionContext ctx) => _editor(ctx).canEdit && audioTarget(ctx, unlocked: true) != null;

String? _openReason(EditorActionContext ctx) {
  if (!_editor(ctx).canEdit) return AudioStrings.notEditable;
  if (audioTarget(ctx) == null) return AudioStrings.selectClip;
  return AudioStrings.actionTrackLocked;
}

void _open(EditorActionContext ctx, AudioPanelFocus focus) {
  final item = audioTarget(ctx, unlocked: true);
  if (item == null) return;
  _editor(ctx).openInspector(AudioInspector(item, focus: focus));
}

void _openVolume(EditorActionContext ctx) => _open(ctx, AudioPanelFocus.volume);

void _openFades(EditorActionContext ctx) => _open(ctx, AudioPanelFocus.fades);

// ---- Extract audio ------------------------------------------------------------------------------

ItemId? _primary(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId)).selection.primary;

bool _canExtract(EditorActionContext ctx) {
  final project = ctx.read(editorControllerProvider(ctx.projectId)).project;
  final item = _primary(ctx);
  return _editor(ctx).canEdit && project != null && item != null && AudioOperations.extractBlocker(project, item) == null;
}

String? _extractReason(EditorActionContext ctx) {
  if (!_editor(ctx).canEdit) return AudioStrings.notEditable;
  final project = ctx.read(editorControllerProvider(ctx.projectId)).project;
  final item = _primary(ctx);
  if (project == null || item == null) return AudioStrings.extractNeedsVideo;
  final blocker = AudioOperations.extractBlocker(project, item);
  return blocker == null ? null : AudioOperations.reasonOf(blocker);
}

void _extract(EditorActionContext ctx) {
  final item = _primary(ctx);
  if (item == null) return;
  final added = AudioOperations.extract(_editor(ctx), item, () => ctx.read(editorControllerProvider(ctx.projectId)).project);
  if (added != null && ctx.context.mounted) editorAnnounce(ctx.context, AudioStrings.extracted);
}

// ---- Add music ----------------------------------------------------------------------------------

bool _canAddMusic(EditorActionContext ctx) => _editor(ctx).canEdit && !_editor(ctx).readOnly;

String? _addMusicReason(EditorActionContext ctx) => _editor(ctx).readOnly ? AudioStrings.readOnly : AudioStrings.notEditable;

Future<void> _addMusic(EditorActionContext ctx) async {
  final ops = MediaOperations.of(ctx);
  if (!ops.canEdit || ops.readOnly) return;
  // "At the playhead" means where it was when the user asked, whatever happens while picking.
  final at = ops.playhead;
  final context = ctx.context;
  try {
    final picked = await ctx
        .read(editorEngineProvider)
        .picker
        .pick(const MediaPickRequest(source: MediaPickSource.files, kinds: {MediaPickKind.audio}));
    if (picked.isEmpty || !context.mounted) return;
    final edit = ops.session.editOrNull;
    if (edit == null) return;
    final job = ops.importJob(pool: ctx.read(mediaPoolServiceProvider), edit: edit, at: at);
    final before = ops.project?.timeline;
    await showImportMediaSheet(context, picks: picked, job: job, title: AudioStrings.importTitle);
    if (context.mounted && ops.project?.timeline != before) editorAnnounce(context, AudioStrings.musicAdded);
  } on Object catch (e) {
    debugPrint('[AudioBindings] Picker failed: ${e.runtimeType}');
    if (context.mounted) {
      DanaviewToast.show(context, AudioStrings.pickerFailed, icon: Icons.error_outline_rounded, kind: DanaviewToastKind.error);
    }
  }
}

/// The audio actions bound by UX-33 (ARCH §17.6). The same instances on every read, so two merges
/// of the bindings compare equal (the wiring test relies on it).
List<EditorActionBinding> get audioBindings => _audioBindings;

final List<EditorActionBinding> _audioBindings = List.unmodifiable(<EditorActionBinding>[
  const EditorActionBinding(id: EditorActionId.volume, handler: _openVolume, isEnabled: _canOpen, disabledReason: _openReason),
  const EditorActionBinding(id: EditorActionId.fades, handler: _openFades, isEnabled: _canOpen, disabledReason: _openReason),
  const EditorActionBinding(id: EditorActionId.extractAudio, handler: _extract, isEnabled: _canExtract, disabledReason: _extractReason),
  const EditorActionBinding(id: EditorActionId.addMusic, handler: _addMusic, isEnabled: _canAddMusic, disabledReason: _addMusicReason),
]);
