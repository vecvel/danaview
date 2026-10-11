// OWNER: UX-01
//
// Top-level tools shown when nothing is selected (ARCH §17.7, ux.md §9.1). Context tools for a
// selection are `EditorActionId`s chosen by `ToolSets.forSelection` (UX-16).

import 'action_ids.dart';

/// A top-level tool tab of the tool strip or rail.
///
/// See ARCH §17.7, ux.md §9.1.
enum ToolId {
  /// Media bin, import, add at playhead.
  media(EditorActionId.media),

  /// Add music, record voiceover, extract audio.
  audio(EditorActionId.addMusic),

  /// Adds a text item at the playhead and opens the text panel.
  text(EditorActionId.addText),

  /// Subtitles panel: Auto captions, add caption, import/export.
  captions(EditorActionId.captions),

  /// Picture-in-picture overlays.
  overlay(EditorActionId.addOverlay),

  /// Adjust panel (auto-targets the main-lane clip under the playhead).
  effects(EditorActionId.adjust),

  /// Filters and LUTs (same auto-target).
  filters(EditorActionId.filters),

  /// Transitions for the cut nearest the playhead.
  transitions(EditorActionId.transitions),

  /// Canvas: aspect, background, frame rate, resolution base.
  format(EditorActionId.format);

  const ToolId(this.primaryAction);

  /// The action a tap on the tool's tile runs.
  final EditorActionId primaryAction;

  /// The strip order of ux.md §9.1.
  static const List<ToolId> stripOrder = values;
}
