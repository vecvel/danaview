// OWNER: UX-30
//
// The text action binding (merged by wiring/action_bindings.dart, ARCH §17.6, ux.md §10.8).
//
// * `addText` adds a `TextItem` at the playhead (3 s, centred, "Your text") with CORE-14's
//   `AddText`: it lands on the topmost free text lane, or a new one. The new item is selected and
//   the text panel opens on Edit with its field focused (keyboard up) through
//   `TextPanel.focusRequest`. The timeline's "Add text here" seeks first, then runs this.
// * It is enabled while the project accepts edits; otherwise the reason is shown.
// * The text panel's tabs dispatch CORE-14 commands directly (SetText, SetTextStyle,
//   SetTextAnimation) and the tool tiles of a selected text item open its tabs (UX-14).

import 'package:danaview_editor_core/model.dart' show ItemId;
import 'package:danaview_editor_core/ops.dart' show AddText;

import '../../../app/editor_providers.dart';
import '../../../app/strings/text_strings.dart';
import '../../contracts/contracts.dart';
import '../../panels/text_panel.dart';

bool _canAdd(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId).notifier).canEdit;

String? _reason(EditorActionContext ctx) => _canAdd(ctx) ? null : TextStrings.notEditable;

void _add(EditorActionContext ctx) {
  final editor = ctx.read(editorControllerProvider(ctx.projectId).notifier);
  final at = ctx.read(playheadProvider(ctx.projectId)).value;
  final result = editor.apply(AddText(at, text: TextStrings.newText));
  if (!result.applied) return;
  final ItemId? item = ctx.read(editorControllerProvider(ctx.projectId)).selection.primary;
  if (item == null) return;
  TextPanel.focusRequest.value = item;
  editor.openInspector(TextInspector(item));
}

/// The text actions bound by UX-30 (ARCH §17.6). The same instances on every read, so two merges
/// of the bindings compare equal.
List<EditorActionBinding> get textBindings => _textBindings;

final List<EditorActionBinding> _textBindings = List.unmodifiable(<EditorActionBinding>[
  const EditorActionBinding(id: EditorActionId.addText, handler: _add, isEnabled: _canAdd, disabledReason: _reason),
]);
