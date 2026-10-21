// OWNER: UX-01
// EXTENDED: AIS-01 (merges the 1.2.0 binding files; hides the AI Studio actions while
// DANAVIEW_AI_STUDIO is off, AI_STUDIO_PLAN §4.2, D-65)
// EXTENDED: INT-101 (merges the Still Photo Mode and Beauty binding files, VED-01 and VED-26)
//
// Merges the per-feature binding files (ARCH §17.6, BUILD_PLAN §2): each feature ticket owns
// `actions/bindings/<feature>_bindings.dart` and exposes `List<EditorActionBinding> get
// <feature>Bindings`; this file lists every one of them so no feature edits a shared file. An id
// bound by two features is a wiring error ([DuplicateActionBindingError]). An architecture test
// (test/architecture/) checks that every file in `actions/bindings/` is listed here.
//
// 1.2.0 (AIS-01): the seven AI Studio and rich-subtitle binding files are listed after the 1.1
// ones; INT-101 adds the Still Photo Mode (VED-01) and Beauty (VED-26) files after them. While `DANAVIEW_AI_STUDIO` is off, [mergeEditorActionBindings] binds every
// `EditorActionId.aiStudioActions` id as hidden and disabled (whatever ai_bindings.dart or
// review_bindings.dart provide), so no AI action shows in a tool set, menu, semantics action or
// shortcut and none can run.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/editor_availability.dart';
import '../actions/bindings/ai_bindings.dart';
import '../actions/bindings/audio_bindings.dart';
import '../actions/bindings/auto_captions_bindings.dart';
import '../actions/bindings/beauty_bindings.dart';
import '../actions/bindings/caption_bindings.dart';
import '../actions/bindings/clip_bindings.dart';
import '../actions/bindings/color_bindings.dart';
import '../actions/bindings/edit_bindings.dart';
import '../actions/bindings/emoji_bindings.dart';
import '../actions/bindings/export_bindings.dart';
import '../actions/bindings/keyframe_bindings.dart';
import '../actions/bindings/marker_bindings.dart';
import '../actions/bindings/media_bindings.dart';
import '../actions/bindings/overlay_bindings.dart';
import '../actions/bindings/photo_bindings.dart';
import '../actions/bindings/playback_bindings.dart';
import '../actions/bindings/presets_bindings.dart';
import '../actions/bindings/project_bindings.dart';
import '../actions/bindings/relink_bindings.dart';
import '../actions/bindings/render_preview_bindings.dart';
import '../actions/bindings/review_bindings.dart';
import '../actions/bindings/rich_text_bindings.dart';
import '../actions/bindings/speed_bindings.dart';
import '../actions/bindings/subtitle_io_bindings.dart';
import '../actions/bindings/text_bindings.dart';
import '../actions/bindings/timing_bindings.dart';
import '../actions/bindings/track_bindings.dart';
import '../actions/bindings/transcript_bindings.dart';
import '../actions/bindings/transform_bindings.dart';
import '../actions/bindings/transition_bindings.dart';
import '../actions/bindings/voiceover_bindings.dart';
import '../contracts/contracts.dart';

/// One binding file: its feature name (the file is `<file>.dart`), owner ticket and bindings.
///
/// See ARCH §17.6.
final class EditorBindingSource {
  /// Creates a source.
  const EditorBindingSource(this.file, this.owner, this.bindings);

  /// File name without `.dart` (`track_bindings`).
  final String file;

  /// Owner ticket (`UX-11`).
  final String owner;

  /// Reads the file's bindings.
  final List<EditorActionBinding> Function() bindings;

  @override
  String toString() => '$file ($owner)';
}

/// Every per-feature binding file, in ticket order.
///
/// See ARCH §17.6, BUILD_PLAN §2.
final List<EditorBindingSource> editorBindingSources = List.unmodifiable(<EditorBindingSource>[
  EditorBindingSource('track_bindings', 'UX-11', () => trackBindings),
  EditorBindingSource('edit_bindings', 'UX-13', () => editBindings),
  EditorBindingSource('playback_bindings', 'UX-14', () => playbackBindings),
  EditorBindingSource('marker_bindings', 'UX-17', () => markerBindings),
  EditorBindingSource('transform_bindings', 'UX-23', () => transformBindings),
  EditorBindingSource('color_bindings', 'UX-24', () => colorBindings),
  EditorBindingSource('speed_bindings', 'UX-25', () => speedBindings),
  EditorBindingSource('keyframe_bindings', 'UX-26', () => keyframeBindings),
  EditorBindingSource('transition_bindings', 'UX-27', () => transitionBindings),
  EditorBindingSource('overlay_bindings', 'UX-28', () => overlayBindings),
  EditorBindingSource('project_bindings', 'UX-29', () => projectBindings),
  EditorBindingSource('text_bindings', 'UX-30', () => textBindings),
  EditorBindingSource('caption_bindings', 'UX-31', () => captionBindings),
  EditorBindingSource('subtitle_io_bindings', 'UX-32', () => subtitleIoBindings),
  EditorBindingSource('audio_bindings', 'UX-33', () => audioBindings),
  EditorBindingSource('voiceover_bindings', 'UX-34', () => voiceoverBindings),
  EditorBindingSource('clip_bindings', 'UX-35', () => clipBindings),
  EditorBindingSource('media_bindings', 'UX-36', () => mediaBindings),
  EditorBindingSource('auto_captions_bindings', 'UX-37', () => autoCaptionsBindings),
  EditorBindingSource('export_bindings', 'UX-39', () => exportBindings),
  EditorBindingSource('relink_bindings', 'UX-40', () => relinkBindings),
  EditorBindingSource('render_preview_bindings', 'UX-44', () => renderPreviewBindings),
  // 1.2.0 (AI_STUDIO_PLAN §4.4, merged by AIS-01).
  EditorBindingSource('transcript_bindings', 'AIS-17', () => transcriptBindings),
  EditorBindingSource('rich_text_bindings', 'AIS-18', () => richTextBindings),
  EditorBindingSource('timing_bindings', 'AIS-19', () => timingBindings),
  EditorBindingSource('emoji_bindings', 'AIS-20', () => emojiBindings),
  EditorBindingSource('presets_bindings', 'AIS-26', () => presetsBindings),
  EditorBindingSource('ai_bindings', 'AIS-32', () => aiBindings),
  EditorBindingSource('review_bindings', 'AIS-33', () => reviewBindings),
  // 1.2.0 Unified Photo & Video Editor (BUILD_PLAN v1.2 VED-01, VED-26; merged by INT-101).
  EditorBindingSource('photo_bindings', 'VED-01', () => photoBindings),
  EditorBindingSource('beauty_bindings', 'VED-26', () => beautyBindings),
]);

/// Thrown when two binding files bind the same [EditorActionId].
///
/// See ARCH §17.6.
final class DuplicateActionBindingError extends StateError {
  /// Creates the error.
  DuplicateActionBindingError(this.id, this.first, this.second)
      : super('${id.name} is bound by both ${first.file} (${first.owner}) and ${second.file} (${second.owner})');

  /// The doubly bound action.
  final EditorActionId id;

  /// The first source binding it.
  final EditorBindingSource first;

  /// The second source binding it.
  final EditorBindingSource second;
}

/// Merges [sources] (default: [editorBindingSources]) into one binding per action id. Unbound ids
/// are absent (the registry shows them disabled or hides them).
///
/// With the default sources the result is also passed through [gateAiStudioActions] with
/// [aiStudio] (default: [EditorFlags.aiStudioEnabled]); explicit [sources] are merged as given.
///
/// See ARCH §17.6, AI_STUDIO_PLAN §4.2.
Map<EditorActionId, EditorActionBinding> mergeEditorActionBindings([Iterable<EditorBindingSource>? sources, bool? aiStudio]) {
  final merged = _merge(sources ?? editorBindingSources);
  if (sources != null) return merged;
  return gateAiStudioActions(merged, aiStudio: aiStudio ?? EditorFlags.aiStudioEnabled);
}

/// [bindings] unchanged while [aiStudio] is on; otherwise with every
/// `EditorActionId.aiStudioActions` id bound as hidden and disabled (AI_STUDIO_PLAN §4.2, D-65:
/// with `DANAVIEW_AI_STUDIO=false` there is no AI Studio button, Translate or Ask AI). The hidden
/// bindings are the same instances on every call, so two gated merges compare equal.
///
/// See AI_STUDIO_PLAN §4.2.
Map<EditorActionId, EditorActionBinding> gateAiStudioActions(Map<EditorActionId, EditorActionBinding> bindings, {required bool aiStudio}) {
  if (aiStudio) return bindings;
  return Map.unmodifiable(<EditorActionId, EditorActionBinding>{...bindings, ..._aiStudioOffBindings});
}

void _aiStudioOff(EditorActionContext ctx) {}

bool _never(EditorActionContext ctx) => false;

const Map<EditorActionId, EditorActionBinding> _aiStudioOffBindings = {
  EditorActionId.aiStudio: EditorActionBinding(id: EditorActionId.aiStudio, handler: _aiStudioOff, isEnabled: _never, isVisible: _never),
  EditorActionId.askAi: EditorActionBinding(id: EditorActionId.askAi, handler: _aiStudioOff, isEnabled: _never, isVisible: _never),
  EditorActionId.translateTrack:
      EditorActionBinding(id: EditorActionId.translateTrack, handler: _aiStudioOff, isEnabled: _never, isVisible: _never),
  EditorActionId.reviewAiChanges:
      EditorActionBinding(id: EditorActionId.reviewAiChanges, handler: _aiStudioOff, isEnabled: _never, isVisible: _never),
};

Map<EditorActionId, EditorActionBinding> _merge(Iterable<EditorBindingSource> sources) {
  final out = <EditorActionId, EditorActionBinding>{};
  final from = <EditorActionId, EditorBindingSource>{};
  for (final source in sources) {
    for (final binding in source.bindings()) {
      final previous = from[binding.id];
      if (previous != null) throw DuplicateActionBindingError(binding.id, previous, source);
      from[binding.id] = source;
      out[binding.id] = binding;
    }
  }
  return Map.unmodifiable(out);
}

/// The merged bindings, read by the `EditorActionRegistry` (UX-15). Tests may override it.
///
/// See ARCH §17.6.
final editorActionBindingsProvider = Provider<Map<EditorActionId, EditorActionBinding>>(
  (ref) => mergeEditorActionBindings(),
  name: 'editorActionBindingsProvider',
);
