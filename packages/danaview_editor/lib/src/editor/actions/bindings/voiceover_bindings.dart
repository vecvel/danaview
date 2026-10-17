// OWNER: UX-34
//
// The voiceover action bindings (merged by wiring/action_bindings.dart, ARCH §17.6, ux.md §10.5).
//
// * `recordVoiceover` opens the voiceover panel (VoiceoverInspector). It is shown only when the
//   engine has a voice recorder (`EditorEngine.voiceRecorder != null`), and enabled while the
//   project accepts edits and is not open read-only (a recording adds media and a clip).
// * Labels, icons and shortcuts come from the registry (UX-15); copy from `VoiceoverStrings`.

import '../../../app/editor_providers.dart';
import '../../../app/strings/voiceover_strings.dart';
import '../../contracts/contracts.dart';
import '../../state/editor_controller.dart';

EditorController _editor(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId).notifier);

bool _hasRecorder(EditorActionContext ctx) => ctx.read(editorEngineProvider).voiceRecorder != null;

bool _canRecord(EditorActionContext ctx) => _hasRecorder(ctx) && _editor(ctx).canEdit && !_editor(ctx).readOnly;

String? _recordReason(EditorActionContext ctx) {
  if (!_hasRecorder(ctx)) return VoiceoverStrings.actionUnavailable;
  if (_editor(ctx).readOnly) return VoiceoverStrings.readOnly;
  return VoiceoverStrings.notEditable;
}

void _record(EditorActionContext ctx) {
  if (!_canRecord(ctx)) return;
  _editor(ctx).openInspector(const VoiceoverInspector());
}

/// The voiceover actions bound by UX-34 (ARCH §17.6). The same instances on every read, so two
/// merges of the bindings compare equal (the wiring test relies on it).
List<EditorActionBinding> get voiceoverBindings => _voiceoverBindings;

final List<EditorActionBinding> _voiceoverBindings = List.unmodifiable(<EditorActionBinding>[
  const EditorActionBinding(
    id: EditorActionId.recordVoiceover,
    handler: _record,
    isVisible: _hasRecorder,
    isEnabled: _canRecord,
    disabledReason: _recordReason,
  ),
]);
