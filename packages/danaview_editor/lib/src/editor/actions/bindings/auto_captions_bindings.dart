// OWNER: UX-37
//
// The Auto captions action binding (merged by wiring/action_bindings.dart, ARCH §17.6):
//
// * `autoCaptions` opens the Auto captions sheet (the Captions panel's "Auto captions" button, the
//   registry and the shortcuts sheet). From a clip's context menu the sheet preselects "This clip";
//   with clips selected it offers it.
// * It is hidden unless `DANAVIEW_AUTO_CAPTIONS` is on (D-31) and the transcription service offers
//   at least one tier on this device; it is enabled once the project has opened and is editable.

import 'package:danaview_editor_core/model.dart' show ItemId, MediaClip;
import 'package:danaview_transcription/danaview_transcription.dart' show ClipScope, TranscriptionScope;

import '../../../app/editor_availability.dart' show EditorFlags;
import '../../../app/editor_providers.dart';
import '../../../app/strings/captions_strings.dart';
import '../../contracts/action_binding.dart';
import '../../contracts/action_ids.dart';
import '../../flows/captions/auto_captions_sheet.dart';

bool _visible(EditorActionContext ctx) {
  if (!EditorFlags.autoCaptionsEnabled) return false;
  try {
    return ctx.read(transcriptionServiceProvider).offers.any((o) => o.available);
  } on Object {
    return false;
  }
}

bool _enabled(EditorActionContext ctx) {
  final state = ctx.read(editorControllerProvider(ctx.projectId));
  if (!state.isReady) return false;
  return !ctx.read(editorControllerProvider(ctx.projectId).notifier).readOnly;
}

String? _why(EditorActionContext ctx) {
  final state = ctx.read(editorControllerProvider(ctx.projectId));
  return state.isReady ? CaptionsStrings.readOnly : CaptionsStrings.notReady;
}

/// The clip a context-menu invocation captions (the primary selected media clip), or null.
TranscriptionScope? _scopeOf(EditorActionContext ctx) {
  if (ctx.source != EditorActionSource.contextMenu) return null;
  final state = ctx.read(editorControllerProvider(ctx.projectId));
  final ItemId? primary = state.selection.primary;
  final project = state.project;
  if (primary == null || project == null) return null;
  return project.index.locate(primary)?.item is MediaClip ? ClipScope(primary) : null;
}

Future<void> _open(EditorActionContext ctx) async {
  final context = ctx.context;
  if (!context.mounted) return;
  await AutoCaptionsSheet.show(context, projectId: ctx.projectId, scope: _scopeOf(ctx));
}

/// The Auto captions actions bound by UX-37 (ARCH §17.6). The same instances on every read.
List<EditorActionBinding> get autoCaptionsBindings => _autoCaptionsBindings;

const List<EditorActionBinding> _autoCaptionsBindings = <EditorActionBinding>[
  EditorActionBinding(
    id: EditorActionId.autoCaptions,
    handler: _open,
    isVisible: _visible,
    isEnabled: _enabled,
    disabledReason: _why,
  ),
];
