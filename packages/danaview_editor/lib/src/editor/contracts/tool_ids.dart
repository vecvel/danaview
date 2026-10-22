// OWNER: UX-01
// EXTENDED: AIS-01 (1.2.0: no new top-level tool, see below)
// EXTENDED: INT-101 (PhotoToolId, the Still Photo Mode tray; VED plan §6.1)
//
// Top-level tools shown when nothing is selected (ARCH §17.7, ux.md §9.1). Context tools for a
// selection are `EditorActionId`s chosen by `ToolSets.forSelection` (UX-16).
//
// 1.2.0 (AI_STUDIO_PLAN §4.2, §4.4): the strip is unchanged. The rich-subtitle and AI Studio entry
// points (Transcript, AI Studio, Translate, presets, fonts) live in the Captions tool's panel
// header ([ToolId.captions]) and the cue selection tools; AI ones only with `DANAVIEW_AI_STUDIO`.

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

  /// Whether the tool's tile opens a tab of sub-tools (`ToolSets.toolTabs`) instead of a panel:
  /// opening it closes the open panel, and a new selection closes it (the selection's context
  /// tools take its place).
  bool get opensTab => this == ToolId.audio;
}

/// A tool of the Still Photo Mode tray (VED plan §6.1, BUILD_PLAN VED-01). The photo screen is not
/// the timeline: these tools never join [ToolId.stripOrder], and the timeline strip is unchanged.
///
/// Tools are gated by capabilities and build flags and are hidden, not disabled (ARCH v1.2 §3):
/// [beauty] needs `DANAVIEW_BEAUTY` (and, at runtime, the Beauty pack, V2-14).
///
/// See VED plan §6.1, ARCH v1.2 §6.1.
enum PhotoToolId {
  /// Crop, straighten, horizon and keystone (VED-09).
  crop,

  /// Pro tone (VED-06).
  tone,

  /// The 8-band HSL mixer (VED-07).
  hsl,

  /// RGB and channel curves (VED-08).
  curves,

  /// Beauty & Retouching (VED-26; `DANAVIEW_BEAUTY`).
  beauty,

  /// Selective masks and local adjustments (VED-10).
  masks,

  /// Text, stickers and borders (VED-11).
  text,

  /// Photo presets (VED-12).
  presets;

  /// The tray order of VED plan §6.1.
  static const List<PhotoToolId> trayOrder = values;

  /// Whether this tool exists only with `DANAVIEW_BEAUTY` on.
  bool get needsBeauty => this == PhotoToolId.beauty;

  /// The tray of a build: with [beauty] off the Beauty tool is absent (hidden, not disabled).
  static List<PhotoToolId> tray({required bool beauty}) =>
      [for (final tool in trayOrder) if (beauty || !tool.needsBeauty) tool];
}
