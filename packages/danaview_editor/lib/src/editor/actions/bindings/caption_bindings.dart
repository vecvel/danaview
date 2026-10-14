// OWNER: UX-31
//
// The caption action bindings (merged by wiring/action_bindings.dart, ARCH §17.6, ux.md §9.1,
// §10.9).
//
// * `captions` (the Captions tool, the context tools of a cue and the track menu's Style row) opens
//   the captions panel for a subtitle track: the selected lane when it is a subtitle lane, else the
//   lane of the selected cue, else the topmost subtitle lane; without any subtitle lane the panel
//   shows its start state (add a subtitle track, Auto captions, import). Run from a button with only
//   a subtitle lane selected (the track menu's Style row), it opens the Style section.
// * `addCaption` adds a 2 s caption at the playhead (CORE-15 `AddCue`) on the same target lane
//   (or, without one, on the topmost subtitle lane with room or a new one), selects it and opens
//   the panel on it.
// * Everything else of the panel (text, timing, split, merge, delete, shift, style, position,
//   language, burn-in) dispatches CORE-15 commands directly from the panel.

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show AddCue;

import '../../../app/editor_providers.dart';
import '../../../app/strings/subtitle_strings.dart';
import '../../contracts/contracts.dart';
import '../../state/edit_transaction.dart' show EditApplied;
import '../../state/editor_state.dart' show EditorSelection;

/// The subtitle lane the caption actions target in [project] with [selection]: the selected lane
/// when it is a subtitle lane, else the lane of the primary (or any) selected cue, else the topmost
/// subtitle lane; null when the project has none.
TrackId? captionTargetIn(EditProject project, EditorSelection selection) {
  final index = project.index;
  final lane = selection.lane;
  if (lane != null) {
    final at = index.trackIndexOf(lane);
    if (at != null && project.tracks[at].kind == TrackKind.subtitle) return lane;
  }
  for (final id in [selection.primary, ...selection.items]) {
    if (id == null) continue;
    final loc = index.locate(id);
    if (loc != null && loc.track.kind == TrackKind.subtitle) return loc.track.id;
  }
  // Lanes are stored bottom to top: the last subtitle lane is the topmost.
  for (final t in project.tracks.reversed) {
    if (t.kind == TrackKind.subtitle) return t.id;
  }
  return null;
}

/// The route the `captions` action opens in [project] with [selection] ([fromMenu]: run from a
/// button such as the track menu's Style row).
SubtitlesInspector captionsRouteIn(EditProject project, EditorSelection selection, {bool fromMenu = false}) {
  final track = captionTargetIn(project, selection);
  if (track == null) return const SubtitlesInspector();
  ItemId? cue;
  final primary = selection.primary;
  if (primary != null) {
    final loc = project.index.locate(primary);
    if (loc != null && loc.track.id == track && loc.item is SubtitleCue) cue = primary;
  }
  final style = fromMenu && cue == null && selection.items.isEmpty && selection.lane == track;
  return SubtitlesInspector(track: track, cue: cue, section: style ? SubtitlesPanelSection.style : SubtitlesPanelSection.cues);
}

bool _isReady(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId)).project != null;

bool _canEdit(EditorActionContext ctx) =>
    ctx.read(editorControllerProvider(ctx.projectId).notifier).canEdit && ctx.read(editorControllerProvider(ctx.projectId)).project != null;

String? _notEditable(EditorActionContext ctx) => SubtitleStrings.notEditable;

void _open(EditorActionContext ctx) {
  final state = ctx.read(editorControllerProvider(ctx.projectId));
  final project = state.project;
  if (project == null) return;
  final route = captionsRouteIn(project, state.selection, fromMenu: ctx.source == EditorActionSource.button);
  ctx.read(editorControllerProvider(ctx.projectId).notifier).openInspector(route);
}

void _add(EditorActionContext ctx) {
  final editor = ctx.read(editorControllerProvider(ctx.projectId).notifier);
  final state = ctx.read(editorControllerProvider(ctx.projectId));
  final project = state.project;
  if (project == null) return;
  var track = captionTargetIn(project, state.selection);
  if (track != null) {
    final at = project.index.trackIndexOf(track);
    if (at == null || project.tracks[at].locked) track = null;
  }
  final t = ctx.read(playheadProvider(ctx.projectId)).value;
  final result = editor.apply(AddCue(t, SubtitleStrings.newCueText, track: track));
  if (result is! EditApplied) return;
  final after = ctx.read(editorControllerProvider(ctx.projectId));
  final cue = after.selection.primary;
  final loc = cue == null ? null : after.project?.index.locate(cue);
  if (cue == null || loc == null || loc.item is! SubtitleCue) return;
  editor
    ..openInspector(SubtitlesInspector(track: loc.track.id, cue: cue))
    ..select(cue);
}

/// The caption actions bound by UX-31 (ARCH §17.6). The same instances on every read, so two
/// merges of the bindings compare equal.
List<EditorActionBinding> get captionBindings => _captionBindings;

const List<EditorActionBinding> _captionBindings = <EditorActionBinding>[
  EditorActionBinding(id: EditorActionId.captions, handler: _open, isEnabled: _isReady, disabledReason: _notEditable),
  EditorActionBinding(id: EditorActionId.addCaption, handler: _add, isEnabled: _canEdit, disabledReason: _notEditable),
];
