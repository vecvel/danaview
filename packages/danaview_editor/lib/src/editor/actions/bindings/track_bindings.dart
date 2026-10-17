// OWNER: UX-11
//
// The track action bindings (merged by wiring/action_bindings.dart, ARCH §17.6):
//
// * `addTrack`: opens the add-track sheet (a track of any kind; CORE-17 `AddTrack`).
// * `laneHeight`: cycles the height of every lane Compact -> Normal -> Large -> Compact (the
//   timeline-wide `EditModes.laneHeight`; not a history entry).
//
// Everything else of UX-11 (flag toggles, rename, move, delete, role) lives on the headers and the
// track menu and dispatches the CORE-17 commands directly; the menu's subtitle rows run actions
// that UX-31, UX-32 and UX-37 bind (`captions`, `importSubtitles`, `exportSubtitles`,
// `regenerateCaptions`).

import '../../../app/editor_providers.dart';
import '../../../app/strings/track_strings.dart';
import '../../contracts/contracts.dart';
import '../../timeline/timeline_metrics.dart' show LaneHeightPreset;
import '../../timeline/track_menu_sheet.dart';

/// The next lane height in the Compact, Normal, Large cycle.
LaneHeightPreset nextLaneHeight(LaneHeightPreset current) => switch (current) {
      LaneHeightPreset.compact => LaneHeightPreset.normal,
      LaneHeightPreset.normal => LaneHeightPreset.large,
      LaneHeightPreset.large => LaneHeightPreset.compact,
    };

bool _canEdit(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId).notifier).canEdit;

Future<void> _addTrack(EditorActionContext ctx) => AddTrackSheet.show(ctx.context, projectId: ctx.projectId);

void _cycleLaneHeight(EditorActionContext ctx) {
  final controller = ctx.read(editorControllerProvider(ctx.projectId).notifier);
  controller.setModes((m) => m.copyWith(laneHeight: nextLaneHeight(m.laneHeight)));
}

bool _isReady(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId)).isReady;

String? _notEditable(EditorActionContext ctx) => TrackStrings.notEditable;

/// The track actions bound by UX-11 (ARCH §17.6).
List<EditorActionBinding> get trackBindings => _trackBindings;

const List<EditorActionBinding> _trackBindings = <EditorActionBinding>[
  EditorActionBinding(id: EditorActionId.addTrack, handler: _addTrack, isEnabled: _canEdit, disabledReason: _notEditable),
  EditorActionBinding(id: EditorActionId.laneHeight, handler: _cycleLaneHeight, isEnabled: _isReady, disabledReason: _notEditable),
];
