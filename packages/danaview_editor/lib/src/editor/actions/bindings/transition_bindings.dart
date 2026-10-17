// OWNER: UX-27
//
// The transition action binding (merged by wiring/action_bindings.dart, ARCH §17.6, ux.md §9.1,
// §10.12).
//
// * `transitions` opens the transitions panel for a cut: the selected transition's cut when one is
//   selected, else the cut nearest the playhead on the main lane, else the nearest cut on any other
//   video or overlay lane. The cut is selected too, so the context tools show the transition tools.
// * It is enabled while the project accepts edits and some lane has a cut; otherwise the reason is
//   "Add at least two clips to use transitions" (shown when the disabled tile is tapped).
// * Removing a selected transition is `delete` (UX-12's edit bindings); the panel's tiles, slider,
//   direction and "Apply to all cuts" dispatch CORE-16 commands directly.

import 'package:danaview_editor_core/eval.dart' show TransitionLimits;
import 'package:danaview_editor_core/model.dart' show EditProject, TimeUs, TrackKind, TransitionRef;

import '../../../app/editor_providers.dart';
import '../../../app/strings/transition_strings.dart';
import '../../contracts/contracts.dart';

/// The cut the transitions action opens at playhead [t] in [project] with [selected] the selected
/// transition: [selected] when it still names a cut, else the cut nearest [t] on the main lane,
/// else the nearest cut on another video or overlay lane; null when there is no cut.
TransitionRef? transitionTargetIn(EditProject project, TimeUs t, {TransitionRef? selected}) {
  if (selected != null && TransitionLimits.isCut(project, selected)) return selected;
  TransitionRef? best;
  var bestDistance = 0;
  var bestMain = false;
  for (final track in project.tracks) {
    if (track.kind != TrackKind.video && track.kind != TrackKind.overlay) continue;
    final ends = {for (final item in track.items) item.id: item.end};
    for (final cut in TransitionLimits.cutsOf(track)) {
      final d = ((ends[cut.left] ?? 0) - t).abs();
      final better = best == null || (track.isMain && !bestMain) || (track.isMain == bestMain && d < bestDistance);
      if (better) {
        best = cut;
        bestDistance = d;
        bestMain = track.isMain;
      }
    }
  }
  return best;
}

/// The cut the action would open, or null.
TransitionRef? transitionTarget(EditorActionContext ctx) {
  final state = ctx.read(editorControllerProvider(ctx.projectId));
  final project = state.project;
  if (project == null) return null;
  final t = ctx.read(playheadProvider(ctx.projectId)).value;
  return transitionTargetIn(project, t, selected: state.selection.transition);
}

bool _canOpen(EditorActionContext ctx) =>
    ctx.read(editorControllerProvider(ctx.projectId).notifier).canEdit && transitionTarget(ctx) != null;

String? _reason(EditorActionContext ctx) {
  if (!ctx.read(editorControllerProvider(ctx.projectId).notifier).canEdit) return TransitionStrings.notEditable;
  return TransitionStrings.needTwoClips;
}

void _open(EditorActionContext ctx) {
  final cut = transitionTarget(ctx);
  if (cut == null) return;
  ctx.read(editorControllerProvider(ctx.projectId).notifier)
    ..selectTransition(cut)
    ..openInspector(TransitionInspector(cut));
}

/// The transition actions bound by UX-27 (ARCH §17.6). The same instances on every read, so two
/// merges of the bindings compare equal (the wiring test relies on it).
List<EditorActionBinding> get transitionBindings => _transitionBindings;

final List<EditorActionBinding> _transitionBindings = List.unmodifiable(<EditorActionBinding>[
  const EditorActionBinding(id: EditorActionId.transitions, handler: _open, isEnabled: _canOpen, disabledReason: _reason),
]);
