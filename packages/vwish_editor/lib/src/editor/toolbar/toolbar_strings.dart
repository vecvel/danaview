// OWNER: UX-16
//
// Copy of the tool strip, the tool rail and the context tool sets (ux.md §9.1, §9.2). Action labels
// and icons come from the EditorActionRegistry (UX-15); this file only holds what the registry has
// no entry for: the top-level tool names and icons, the leading selection chip, the panel-opening
// context tools (text tabs, subtitle sections, transition settings) and the explanations of tiles
// that are not actions.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../contracts/contracts.dart';
import 'tool_sets.dart';

/// Copy of the toolbar (ux.md §9).
abstract final class ToolbarStrings {
  /// Semantics label of the strip and the rail.
  static const String toolsRegion = 'Editing tools';

  /// Title of the side pane when it shows the top-level tools.
  static const String toolsTitle = 'Tools';

  /// Tooltip and semantics hint of the leading chip.
  static const String clearSelection = 'Clear selection';

  /// Tooltip and semantics hint of the leading chip of a tool tab (Audio).
  static const String closeTool = 'Back to tools';

  /// The project is still opening.
  static const String notOpen = 'The project is still opening';

  /// The selected item's lane is locked.
  static const String trackLocked = 'This track is locked';

  /// The name of a top-level tool (ux.md §9.1).
  static String tool(ToolId tool) => switch (tool) {
        ToolId.media => 'Media',
        ToolId.audio => 'Audio',
        ToolId.text => 'Text',
        ToolId.captions => 'Captions',
        ToolId.overlay => 'Overlay',
        ToolId.effects => 'Effects',
        ToolId.filters => 'Filters',
        ToolId.transitions => 'Transitions',
        ToolId.format => 'Format',
      };

  /// The icon of a top-level tool (ux.md §9.1).
  static IconData toolIcon(ToolId tool) => switch (tool) {
        ToolId.media => Icons.video_library_rounded,
        ToolId.audio => Icons.music_note_rounded,
        ToolId.text => Icons.text_fields_rounded,
        ToolId.captions => Icons.closed_caption_rounded,
        ToolId.overlay => Icons.picture_in_picture_alt_rounded,
        ToolId.effects => Icons.tune_rounded,
        ToolId.filters => Icons.palette_rounded,
        ToolId.transitions => Icons.compare_rounded,
        ToolId.format => Icons.aspect_ratio_rounded,
      };

  /// The leading chip of a selection ("Video clip"; [count] items for a multi-selection).
  static String selection(SelectionKind kind, {int count = 0}) => switch (kind) {
        SelectionKind.videoClip => 'Video clip',
        SelectionKind.overlayVideo => 'Overlay',
        SelectionKind.image => 'Image',
        SelectionKind.freezeFrame => 'Freeze frame',
        SelectionKind.overlayImage => 'Overlay',
        SelectionKind.audioClip => 'Audio clip',
        SelectionKind.text => 'Text',
        SelectionKind.subtitleCue => 'Caption',
        SelectionKind.multi => '$count items',
        SelectionKind.transition => 'Transition',
        SelectionKind.gap => 'Gap',
        SelectionKind.marker => 'Marker',
      };

  // Panel-opening context tools (no EditorActionId of their own).

  /// Text: edit the text.
  static const String textEdit = 'Edit';

  /// Text: font picker.
  static const String textFont = 'Font';

  /// Text: style tab.
  static const String textStyle = 'Style';

  /// Text: in/out animation.
  static const String textAnimation = 'Animation';

  /// Caption: edit the cue text.
  static const String cueEdit = 'Edit text';

  /// Caption: cue timing.
  static const String cueTiming = 'Timing';

  /// Caption: merge with the next cue (in the cue editor).
  static const String cueMerge = 'Merge with next';

  /// Caption: the track style.
  static const String cueStyle = 'Style';

  /// Caption: the track position.
  static const String cuePosition = 'Position';

  /// Transition: type.
  static const String transitionType = 'Type';

  /// Transition: duration.
  static const String transitionDuration = 'Duration';

  /// Transition: direction.
  static const String transitionDirection = 'Direction';

  /// Transition: apply to all cuts.
  static const String transitionApplyAll = 'Apply to all';

  /// Transition: remove it.
  static const String transitionRemove = 'Remove';

  /// Marker: rename.
  static const String markerRename = 'Rename';

  /// Marker: colour.
  static const String markerColor = 'Color';

  /// Marker: note.
  static const String markerNote = 'Note';

  /// Tile semantics hint of an enabled action with a shortcut ("Shortcut S").
  static String shortcutHint(String shortcut) => 'Shortcut $shortcut';
}
