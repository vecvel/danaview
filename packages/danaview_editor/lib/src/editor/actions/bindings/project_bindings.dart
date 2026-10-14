// OWNER: UX-29
//
// The project action bindings (merged by wiring/action_bindings.dart, ARCH §17.6, ux.md §6.4,
// §10.14, §14):
//
// * `save` (⌘S/Ctrl+S, works in text fields): `saveNow(manual: true)`; the controller shows "Saved"
//   or the failure. Disabled while opening or read-only.
// * `undo` / `redo` (⌘Z, ⇧⌘Z and Ctrl+Y): one history step each, one plan patch (the controller).
//   Disabled with "Nothing to undo/redo" when there is nothing.
// * `projectSheet` (title button): the Project sheet. Enabled once the project is open.
// * `history` (long-press on undo, Project sheet › Edit history): the History sheet.
// * `format` (the Format tool tile, Project sheet › Format, export's "Change format"): opens the
//   Format panel (`CanvasInspector`). Enabled while the project accepts edits.
// * Labels, icons and shortcuts come from the registry (UX-15); copy from `ProjectStrings` and the
//   registry's shared reasons, so the built-in fallbacks and these bindings read the same.

import '../../../app/editor_providers.dart';
import '../../../app/strings/project_strings.dart';
import '../../contracts/contracts.dart';
import '../../flows/history_sheet.dart';
import '../../flows/project_sheet.dart';
import '../../state/editor_state.dart';
import '../editor_action_registry.dart' show EditorActionStrings;

EditorState _state(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId));

bool _ready(EditorActionContext ctx) => _state(ctx).isReady;

// ---- save -----------------------------------------------------------------------------------------

bool _canSave(EditorActionContext ctx) => _ready(ctx) && _state(ctx).save.phase != SavePhase.readOnly;

String? _saveReason(EditorActionContext ctx) => _ready(ctx) ? EditorActionStrings.readOnly : EditorActionStrings.notOpen;

Future<void> _save(EditorActionContext ctx) async {
  await ctx.read(editorControllerProvider(ctx.projectId).notifier).saveNow(manual: true);
}

// ---- undo / redo ----------------------------------------------------------------------------------

bool _canUndo(EditorActionContext ctx) => _ready(ctx) && _state(ctx).history.canUndo;

bool _canRedo(EditorActionContext ctx) => _ready(ctx) && _state(ctx).history.canRedo;

String? _undoReason(EditorActionContext ctx) => _ready(ctx) ? EditorActionStrings.nothingToUndo : EditorActionStrings.notOpen;

String? _redoReason(EditorActionContext ctx) => _ready(ctx) ? EditorActionStrings.nothingToRedo : EditorActionStrings.notOpen;

void _undo(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId).notifier).undo();

void _redo(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId).notifier).redo();

// ---- sheets ---------------------------------------------------------------------------------------

String? _notOpen(EditorActionContext ctx) => ProjectStrings.notOpen;

Future<void> _projectSheet(EditorActionContext ctx) => ProjectSheet.show(ctx);

Future<void> _history(EditorActionContext ctx) => HistorySheet.show(ctx.context, projectId: ctx.projectId);

// ---- format ---------------------------------------------------------------------------------------

bool _canFormat(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId).notifier).canEdit;

String? _formatReason(EditorActionContext ctx) => _ready(ctx) ? ProjectStrings.formatUnavailable : ProjectStrings.notOpen;

void _format(EditorActionContext ctx) =>
    ctx.read(editorControllerProvider(ctx.projectId).notifier).openInspector(const CanvasInspector());

/// The project actions bound by UX-29 (ARCH §17.6). The same instances on every read, so two merges
/// of the bindings compare equal (the wiring test relies on it).
List<EditorActionBinding> get projectBindings => _projectBindings;

final List<EditorActionBinding> _projectBindings = List.unmodifiable(<EditorActionBinding>[
  const EditorActionBinding(id: EditorActionId.save, handler: _save, isEnabled: _canSave, disabledReason: _saveReason),
  const EditorActionBinding(id: EditorActionId.undo, handler: _undo, isEnabled: _canUndo, disabledReason: _undoReason),
  const EditorActionBinding(id: EditorActionId.redo, handler: _redo, isEnabled: _canRedo, disabledReason: _redoReason),
  const EditorActionBinding(id: EditorActionId.projectSheet, handler: _projectSheet, isEnabled: _ready, disabledReason: _notOpen),
  const EditorActionBinding(id: EditorActionId.history, handler: _history, isEnabled: _ready, disabledReason: _notOpen),
  const EditorActionBinding(id: EditorActionId.format, handler: _format, isEnabled: _canFormat, disabledReason: _formatReason),
]);
