// OWNER: UX-01
//
// Merges the per-feature binding files (ARCH §17.6, BUILD_PLAN §2): each feature ticket owns
// `actions/bindings/<feature>_bindings.dart` and exposes `List<EditorActionBinding> get
// <feature>Bindings`; this file lists every one of them so no feature edits a shared file. An id
// bound by two features is a wiring error ([DuplicateActionBindingError]). An architecture test
// (test/architecture/) checks that every file in `actions/bindings/` is listed here.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../actions/bindings/audio_bindings.dart';
import '../actions/bindings/auto_captions_bindings.dart';
import '../actions/bindings/caption_bindings.dart';
import '../actions/bindings/clip_bindings.dart';
import '../actions/bindings/color_bindings.dart';
import '../actions/bindings/edit_bindings.dart';
import '../actions/bindings/export_bindings.dart';
import '../actions/bindings/keyframe_bindings.dart';
import '../actions/bindings/marker_bindings.dart';
import '../actions/bindings/media_bindings.dart';
import '../actions/bindings/overlay_bindings.dart';
import '../actions/bindings/playback_bindings.dart';
import '../actions/bindings/project_bindings.dart';
import '../actions/bindings/relink_bindings.dart';
import '../actions/bindings/speed_bindings.dart';
import '../actions/bindings/subtitle_io_bindings.dart';
import '../actions/bindings/text_bindings.dart';
import '../actions/bindings/track_bindings.dart';
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
/// See ARCH §17.6.
Map<EditorActionId, EditorActionBinding> mergeEditorActionBindings([Iterable<EditorBindingSource>? sources]) {
  final out = <EditorActionId, EditorActionBinding>{};
  final from = <EditorActionId, EditorBindingSource>{};
  for (final source in sources ?? editorBindingSources) {
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
