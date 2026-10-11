// OWNER: UX-16
//
// ToolSets (ARCH §17.7, ux.md §9.2): which tools the strip, the rail pane and the expanded pane show
// for the current selection, and which inspector panels an item supports (re-targeting, ux.md §9.3).
//
// * `forSelection(selection, project)` is pure: it classifies the selection (SelectionKind) and
//   returns the context tools of ux.md §9.2 in order, or null when nothing is selected (the
//   top-level tools of ux.md §9.1 show then). Lane-only selections (a header tap) count as nothing.
// * A context tool is either an `EditorActionId` (label, icon, enablement and handler come from the
//   EditorActionRegistry, so a tool appears disabled with "Not available yet" until its feature
//   binds it) or a panel tool that opens an inspector route directly (text tabs, subtitle
//   sections, transition settings), for the entries of ux.md §9.2 that have no action id.
// * Not shown (ux.md §9.2): video "Animation" is reserved and hidden in v1. The image "Duration"
//   tile has no EditorActionId in the contract (UX-01); image duration is changed by trimming.
// * `supports(route, item, project)` decides whether an item panel may re-target to a newly
//   selected item; InspectorHost closes the panel when it may not (ux.md §9.3).
// * `toolTabs` holds the tools whose tile opens a tab of sub-tools instead of running an action
//   (Audio: Add music, Record voiceover, Extract audio).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart' show IconData;
import 'package:vwish_editor_core/model.dart';

import '../contracts/contracts.dart';
import '../state/editor_state.dart' show EditorSelection;
import 'toolbar_strings.dart';

/// What the selection is, for the context tool set and the leading chip (ux.md §9.2).
enum SelectionKind {
  /// A video clip on the main or an extra video lane.
  videoClip,

  /// A video clip on an overlay lane (picture in picture).
  overlayVideo,

  /// A still image.
  image,

  /// A freeze-frame still.
  freezeFrame,

  /// An image on an overlay lane.
  overlayImage,

  /// An audio clip (music, voiceover, extracted audio).
  audioClip,

  /// A text item.
  text,

  /// A subtitle cue.
  subtitleCue,

  /// Several items.
  multi,

  /// A transition (a cut).
  transition,

  /// A gap on the main lane.
  gap,

  /// A marker.
  marker,
}

/// One tile of a tool set.
@immutable
sealed class ToolEntry {
  const ToolEntry();

  /// A stable key (tests, widget keys).
  String get key;
}

/// A tile that runs an [EditorActionId] through the registry.
final class ActionToolEntry extends ToolEntry {
  /// Creates the entry; [label] and [icon] override the registry's.
  const ActionToolEntry(this.action, {this.label, this.icon});

  /// The action.
  final EditorActionId action;

  /// Label override.
  final String? label;

  /// Icon override.
  final IconData? icon;

  @override
  String get key => label == null ? action.name : '${action.name}:$label';

  @override
  bool operator ==(Object other) => other is ActionToolEntry && other.action == action && other.label == label && other.icon == icon;

  @override
  int get hashCode => Object.hash(action, label, icon);

  @override
  String toString() => 'ActionToolEntry(${action.name}${label == null ? '' : ', $label'})';
}

/// A tile that opens [route] in the inspector.
final class PanelToolEntry extends ToolEntry {
  /// Creates the entry.
  const PanelToolEntry({required this.key, required this.label, required this.icon, required this.route});

  @override
  final String key;

  /// Label.
  final String label;

  /// Icon.
  final IconData icon;

  /// The panel it opens.
  final InspectorRoute route;

  @override
  bool operator ==(Object other) => other is PanelToolEntry && other.key == key && other.route == route;

  @override
  int get hashCode => Object.hash(key, route);

  @override
  String toString() => 'PanelToolEntry($key, $route)';
}

/// The context tools of a selection.
@immutable
final class ToolSet {
  /// Creates a set.
  ToolSet({required this.kind, required List<ToolEntry> entries, this.count = 1, this.item, this.locked = false})
      : entries = List.unmodifiable(entries);

  /// What is selected.
  final SelectionKind kind;

  /// The tiles, in order.
  final List<ToolEntry> entries;

  /// Number of selected items (multi-selection).
  final int count;

  /// The item the tools target, if any.
  final ItemId? item;

  /// Whether the target sits on a locked lane (panel tools are disabled then).
  final bool locked;

  /// Label of the leading chip.
  String get chipLabel => ToolbarStrings.selection(kind, count: count);

  /// The actions of the set, in order (panel tools left out).
  List<EditorActionId> get actions => [
        for (final e in entries)
          if (e is ActionToolEntry) e.action,
      ];

  @override
  bool operator ==(Object other) =>
      other is ToolSet &&
      other.kind == kind &&
      other.count == count &&
      other.item == item &&
      other.locked == locked &&
      listEquals(other.entries, entries);

  @override
  int get hashCode => Object.hash(kind, count, item, locked, Object.hashAll(entries));

  @override
  String toString() => 'ToolSet(${kind.name}, $entries)';
}

/// Context tool sets and panel support (ARCH §17.7, ux.md §9.2, §9.3).
abstract final class ToolSets {
  /// Tools whose tile opens a tab of sub-tools instead of running an action (ux.md §9.1).
  static const Map<ToolId, List<EditorActionId>> toolTabs = {
    ToolId.audio: [EditorActionId.addMusic, EditorActionId.recordVoiceover, EditorActionId.extractAudio],
  };

  static const ActionToolEntry _split = ActionToolEntry(EditorActionId.split);
  static const ActionToolEntry _speed = ActionToolEntry(EditorActionId.speed);
  static const ActionToolEntry _volume = ActionToolEntry(EditorActionId.volume);
  static const ActionToolEntry _fades = ActionToolEntry(EditorActionId.fades);
  static const ActionToolEntry _transform = ActionToolEntry(EditorActionId.transform);
  static const ActionToolEntry _crop = ActionToolEntry(EditorActionId.crop);
  static const ActionToolEntry _adjust = ActionToolEntry(EditorActionId.adjust);
  static const ActionToolEntry _filters = ActionToolEntry(EditorActionId.filters);
  static const ActionToolEntry _chroma = ActionToolEntry(EditorActionId.chromaKey);
  static const ActionToolEntry _mask = ActionToolEntry(EditorActionId.mask);
  static const ActionToolEntry _keyframes = ActionToolEntry(EditorActionId.keyframes);
  static const ActionToolEntry _reverse = ActionToolEntry(EditorActionId.reverse);
  static const ActionToolEntry _freeze = ActionToolEntry(EditorActionId.freeze);
  static const ActionToolEntry _extractAudio = ActionToolEntry(EditorActionId.extractAudio);
  static const ActionToolEntry _replace = ActionToolEntry(EditorActionId.replace);
  static const ActionToolEntry _duplicate = ActionToolEntry(EditorActionId.duplicate);
  static const ActionToolEntry _copy = ActionToolEntry(EditorActionId.copy);
  static const ActionToolEntry _cut = ActionToolEntry(EditorActionId.cut);
  static const ActionToolEntry _moveToTrack = ActionToolEntry(EditorActionId.moveToTrack);
  static const ActionToolEntry _rippleDelete = ActionToolEntry(EditorActionId.rippleDelete);
  static const ActionToolEntry _delete = ActionToolEntry(EditorActionId.delete);
  static const ActionToolEntry _info = ActionToolEntry(EditorActionId.clipInfo);
  static const ActionToolEntry _forward = ActionToolEntry(EditorActionId.bringForward);
  static const ActionToolEntry _backward = ActionToolEntry(EditorActionId.sendBackward);

  /// Video clip (ux.md §9.2; "Animation" is reserved and hidden in v1).
  static const List<ToolEntry> video = [
    _split, _speed, _volume, _transform, _crop, _adjust, _filters, _chroma, _mask, _keyframes, //
    _reverse, _freeze, _extractAudio, _replace, _duplicate, _copy, _rippleDelete, _delete, _info,
  ];

  /// Image or freeze frame (ux.md §9.2, without "Duration": see the file comment).
  static const List<ToolEntry> image = [
    _split,
    _transform,
    _crop,
    _adjust,
    _filters,
    _chroma,
    _mask,
    _keyframes,
    _replace,
    _duplicate,
    _copy,
    _delete,
    _info,
  ];

  /// Audio clip (ux.md §9.2).
  static const List<ToolEntry> audio = [
    _split,
    _volume,
    _fades,
    _speed,
    _keyframes,
    _replace,
    _duplicate,
    _copy,
    _rippleDelete,
    _delete,
    _info,
  ];

  /// Multi-selection (ux.md §9.2).
  static const List<ToolEntry> multi = [_duplicate, _copy, _cut, _moveToTrack, _rippleDelete, _delete];

  /// Gap on the main lane (ux.md §9.2).
  static const List<ToolEntry> gap = [ActionToolEntry(EditorActionId.deleteGap)];

  /// Marker (ux.md §9.2): the marker sheet edits name, colour and note.
  static const List<ToolEntry> marker = [
    ActionToolEntry(EditorActionId.editMarker, label: ToolbarStrings.markerRename, icon: Icons.drive_file_rename_outline_rounded),
    ActionToolEntry(EditorActionId.editMarker, label: ToolbarStrings.markerColor, icon: Icons.palette_outlined),
    ActionToolEntry(EditorActionId.editMarker, label: ToolbarStrings.markerNote, icon: Icons.notes_rounded),
    ActionToolEntry(EditorActionId.deleteMarker, label: 'Delete'),
  ];

  /// Text tools for [item] (ux.md §9.2).
  static List<ToolEntry> text(ItemId item) => [
        PanelToolEntry(key: 'text.edit', label: ToolbarStrings.textEdit, icon: Icons.edit_rounded, route: TextInspector(item)),
        PanelToolEntry(
            key: 'text.font',
            label: ToolbarStrings.textFont,
            icon: Icons.font_download_rounded,
            route: TextInspector(item, tab: TextPanelTab.font)),
        PanelToolEntry(
            key: 'text.style',
            label: ToolbarStrings.textStyle,
            icon: Icons.format_color_text_rounded,
            route: TextInspector(item, tab: TextPanelTab.style)),
        PanelToolEntry(
            key: 'text.animation',
            label: ToolbarStrings.textAnimation,
            icon: Icons.animation_rounded,
            route: TextInspector(item, tab: TextPanelTab.animation)),
        _transform,
        _keyframes,
        _duplicate,
        _copy,
        _delete,
      ];

  /// Subtitle cue tools for [cue] on [track] (ux.md §9.2).
  static List<ToolEntry> subtitleCue(TrackId track, ItemId cue) {
    SubtitlesInspector at(SubtitlesPanelSection section) => SubtitlesInspector(track: track, cue: cue, section: section);
    return [
      PanelToolEntry(key: 'cue.edit', label: ToolbarStrings.cueEdit, icon: Icons.edit_rounded, route: at(SubtitlesPanelSection.cues)),
      PanelToolEntry(key: 'cue.timing', label: ToolbarStrings.cueTiming, icon: Icons.timer_outlined, route: at(SubtitlesPanelSection.cues)),
      _split,
      PanelToolEntry(key: 'cue.merge', label: ToolbarStrings.cueMerge, icon: Icons.merge_rounded, route: at(SubtitlesPanelSection.cues)),
      PanelToolEntry(
          key: 'cue.style', label: ToolbarStrings.cueStyle, icon: Icons.format_color_text_rounded, route: at(SubtitlesPanelSection.style)),
      PanelToolEntry(
          key: 'cue.position',
          label: ToolbarStrings.cuePosition,
          icon: Icons.vertical_align_bottom_rounded,
          route: at(SubtitlesPanelSection.position)),
      _delete,
    ];
  }

  /// Transition tools for [cut] (ux.md §9.2): the transitions panel edits type, duration and
  /// direction and applies to all cuts; Remove deletes the selected transition.
  static List<ToolEntry> transition(TransitionRef cut) {
    final route = TransitionInspector(cut);
    return [
      PanelToolEntry(key: 'transition.type', label: ToolbarStrings.transitionType, icon: Icons.compare_rounded, route: route),
      PanelToolEntry(key: 'transition.duration', label: ToolbarStrings.transitionDuration, icon: Icons.timelapse_rounded, route: route),
      PanelToolEntry(key: 'transition.direction', label: ToolbarStrings.transitionDirection, icon: Icons.swap_horiz_rounded, route: route),
      PanelToolEntry(key: 'transition.applyAll', label: ToolbarStrings.transitionApplyAll, icon: Icons.done_all_rounded, route: route),
      const ActionToolEntry(EditorActionId.delete, label: ToolbarStrings.transitionRemove),
    ];
  }

  /// The context tools of [selection] in [project], or null when nothing (or only a lane) is
  /// selected.
  static ToolSet? forSelection(EditorSelection selection, EditProject? project) {
    if (project == null || selection.isEmpty) return null;
    final index = project.index;
    if (selection.items.length > 1) {
      final locked = selection.items.any((i) => index.locate(i)?.track.locked ?? false);
      return ToolSet(kind: SelectionKind.multi, entries: multi, count: selection.items.length, locked: locked);
    }
    final itemId = selection.primary ?? selection.items.firstOrNull ?? selection.keyframe?.item;
    if (itemId != null) {
      final loc = index.locate(itemId);
      if (loc == null) return null;
      final kind = kindOf(loc.item, loc.track, project.pool);
      final entries = switch (kind) {
        SelectionKind.videoClip => video,
        SelectionKind.overlayVideo => [...video, _forward, _backward],
        SelectionKind.image || SelectionKind.freezeFrame => image,
        SelectionKind.overlayImage => [...image, _forward, _backward],
        SelectionKind.audioClip => audio,
        SelectionKind.text => text(itemId),
        SelectionKind.subtitleCue => subtitleCue(loc.track.id, itemId),
        _ => const <ToolEntry>[],
      };
      return ToolSet(kind: kind, entries: entries, item: itemId, locked: loc.track.locked);
    }
    final cut = selection.transition;
    if (cut != null) {
      return ToolSet(kind: SelectionKind.transition, entries: transition(cut), locked: _locked(project, cut.track));
    }
    final gapRef = selection.gap;
    if (gapRef != null) {
      return ToolSet(kind: SelectionKind.gap, entries: gap, locked: _locked(project, gapRef.track));
    }
    if (selection.marker != null) return ToolSet(kind: SelectionKind.marker, entries: marker);
    return null;
  }

  /// The selection kind of [item] on [track].
  static SelectionKind kindOf(TimelineItem item, Track track, MediaPool pool) {
    switch (item) {
      case TextItem():
        return SelectionKind.text;
      case SubtitleCue():
        return SelectionKind.subtitleCue;
      case MediaClip(:final media):
        final asset = pool[media];
        final mediaKind = asset?.kind;
        final overlay = track.kind == TrackKind.overlay;
        if (track.kind == TrackKind.audio || mediaKind == MediaKind.audio || mediaKind == MediaKind.recording) {
          return SelectionKind.audioClip;
        }
        final still = mediaKind == MediaKind.still || asset?.derived is StillSpec;
        if (still) return overlay ? SelectionKind.overlayImage : SelectionKind.freezeFrame;
        if (mediaKind == MediaKind.image) return overlay ? SelectionKind.overlayImage : SelectionKind.image;
        return overlay ? SelectionKind.overlayVideo : SelectionKind.videoClip;
    }
  }

  /// Whether [item] supports the panel of [route] (ux.md §9.3 re-targeting). Project panels,
  /// transitions and subtitles are always supported here (their routes re-target themselves).
  static bool supports(InspectorRoute route, TimelineItem item, Track track, MediaPool pool) {
    if (route is! ItemInspectorRoute) return true;
    final kind = kindOf(item, track, pool);
    final visualClip = switch (kind) {
      SelectionKind.videoClip ||
      SelectionKind.overlayVideo ||
      SelectionKind.image ||
      SelectionKind.freezeFrame ||
      SelectionKind.overlayImage =>
        true,
      _ => false,
    };
    final videoClip = kind == SelectionKind.videoClip || kind == SelectionKind.overlayVideo;
    final mediaClip = item is MediaClip;
    return switch (route) {
      TransformInspector() => visualClip || kind == SelectionKind.text,
      CropInspector() || MaskInspector() || ChromaInspector() || AdjustInspector() || FiltersInspector() => visualClip,
      SpeedInspector() => videoClip || kind == SelectionKind.audioClip,
      AudioInspector() => kind == SelectionKind.audioClip || (videoClip && _hasAudio(item, pool)),
      KeyframesInspector() => mediaClip || kind == SelectionKind.text,
      TextInspector() => kind == SelectionKind.text,
      ClipInfoInspector() => mediaClip,
    };
  }

  /// [supports] for the item [id] of [project] (false when it is gone).
  static bool supportsItem(InspectorRoute route, ItemId id, EditProject project) {
    final loc = project.index.locate(id);
    if (loc == null) return false;
    return supports(route, loc.item, loc.track, project.pool);
  }

  static bool _locked(EditProject project, TrackId id) {
    final i = project.index.trackIndexOf(id);
    return i != null && project.timeline.tracks[i].locked;
  }

  static bool _hasAudio(TimelineItem item, MediaPool pool) {
    if (item is! MediaClip) return false;
    final asset = pool[item.media];
    return asset == null || asset.probe.hasAudio;
  }
}
