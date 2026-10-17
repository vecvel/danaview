// OWNER: UX-40
//
// The relink action binding (merged by wiring/action_bindings.dart, ARCH §17.6): `relink` opens the
// Missing media sheet (the banner's Relink, the preview's "Media missing" card, and the toasts and
// pre-checks that offer EditorMessageAction.relink). Label, icon and shortcut come from the registry
// (UX-15). It is enabled while the open project has offline media; otherwise it explains that
// everything is available.

import '../../../app/editor_providers.dart';
import '../../../app/strings/relink_strings.dart';
import '../../contracts/contracts.dart';
import '../../flows/relink/relink_sheet.dart';

bool _hasOfflineMedia(EditorActionContext ctx) => !ctx.read(editorControllerProvider(ctx.projectId)).media.isOk;

String? _nothingMissing(EditorActionContext ctx) => RelinkStrings.allGoodMessage;

void _open(EditorActionContext ctx) {
  final context = ctx.context;
  if (!context.mounted) return;
  showRelinkSheet(context, projectId: ctx.projectId);
}

/// The relink actions bound by UX-40 (ARCH §17.6). The same instances on every read, so two merges
/// of the bindings compare equal (the wiring test relies on it).
List<EditorActionBinding> get relinkBindings => _relinkBindings;

final List<EditorActionBinding> _relinkBindings = List.unmodifiable(<EditorActionBinding>[
  const EditorActionBinding(id: EditorActionId.relink, handler: _open, isEnabled: _hasOfflineMedia, disabledReason: _nothingMissing),
]);
