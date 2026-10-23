// OWNER: UX-01
// EXTENDED: AIS-01 (SubtitlesPanelSection.transcript, review, cue; AI_STUDIO_PLAN §4.4)
// EXTENDED: INT-101 (BeautyCategory, BeautyInspector and PhotoToolRoute: the Beauty clip inspector
// and the Still Photo Mode panel routes)
//
// What the inspector shows (ARCH §17.7, ux.md §9.3). `InspectorHost` (UX-16) maps each route to
// its panel; panel constructors take their route (`TransformPanel(route: TransformInspector(…))`).
// Markers, the track menu, history, export, captions and relink are sheets, not inspector routes.

import 'package:flutter/foundation.dart';
import 'package:danaview_editor_core/model.dart';

import 'tool_ids.dart';

/// Which tab the text panel opens on (UX-30).
///
/// See ARCH §17.7, ux.md §10.8.
enum TextPanelTab {
  /// Multiline text.
  edit,

  /// Font picker.
  font,

  /// Size, weight, alignment, colour, spacing.
  style,

  /// Background box.
  background,

  /// Stroke.
  stroke,

  /// Shadow.
  shadow,

  /// In/out animation.
  animation,
}

/// Which part of the audio panel is focused (UX-33).
///
/// See ux.md §10.4.
enum AudioPanelFocus {
  /// Volume, mute, keep pitch, role.
  volume,

  /// Fade in/out.
  fades,
}

/// Which section of the subtitles panel is shown (UX-31).
///
/// See ux.md §10.9.
enum SubtitlesPanelSection {
  /// Cue list and cue editing (text, timing, split, merge).
  cues,

  /// Track style.
  style,

  /// Track position.
  position,

  /// Transcript view and the rich cue editor (AIS-17; AI_STUDIO_PLAN §4.3 U4).
  transcript,

  /// Review of AI suggestions (AIS-33; AI_STUDIO_PLAN §4.3).
  review,

  /// The focused cue: placement, overrides, speaker, emotion (AIS-18; AI_STUDIO_PLAN §4.3).
  cue;

  /// The 1.1 sections (UX-31's Captions / Style / Position switcher). The 1.2.0 sections are added
  /// to the panel by their owners (AIS-17, AIS-18, AIS-33); until then the panel shows the cue
  /// list for them.
  static const List<SubtitlesPanelSection> v11 = [cues, style, position];
}

/// A panel of the inspector and what it targets.
///
/// See ARCH §17.7, ux.md §9.3.
@immutable
sealed class InspectorRoute {
  const InspectorRoute();

  /// The item the panel edits, or null for project-level panels.
  ItemId? get target;

  /// The route to show when the selection changes to [item]: item panels re-target (same panel,
  /// new item); project-level panels stay; panels whose target cannot be re-pointed at a plain item
  /// (transitions, subtitles) return null so the host closes them and shows the context tools. The
  /// host still checks that the new item supports the panel (ToolSets, UX-16).
  InspectorRoute? retarget(ItemId item);
}

/// A route bound to one timeline item.
///
/// See ux.md §9.3.
sealed class ItemInspectorRoute extends InspectorRoute {
  const ItemInspectorRoute(this.item);

  /// The edited item.
  final ItemId item;

  @override
  ItemId get target => item;

  /// This route for [item].
  ItemInspectorRoute withItem(ItemId item);

  @override
  InspectorRoute retarget(ItemId item) => item == this.item ? this : withItem(item);

  @override
  bool operator ==(Object other) => other.runtimeType == runtimeType && other is ItemInspectorRoute && other.item == item;

  @override
  int get hashCode => Object.hash(runtimeType, item);

  @override
  String toString() => '$runtimeType($item)';
}

/// A project-level route (no target item).
///
/// See ux.md §9.3.
sealed class ProjectInspectorRoute extends InspectorRoute {
  const ProjectInspectorRoute();

  @override
  ItemId? get target => null;

  @override
  InspectorRoute retarget(ItemId item) => this;

  @override
  bool operator ==(Object other) => other.runtimeType == runtimeType;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => '$runtimeType()';
}

/// Media bin (UX-36).
///
/// See ux.md §10.1.
final class MediaInspector extends ProjectInspectorRoute {
  /// Creates the route.
  const MediaInspector();
}

/// Voiceover recording (UX-34; only when the engine has a voice recorder).
///
/// See ux.md §10.5.
final class VoiceoverInspector extends ProjectInspectorRoute {
  /// Creates the route.
  const VoiceoverInspector();
}

/// Add a picture-in-picture overlay (UX-28).
///
/// See ux.md §10.13.
final class OverlayInspector extends ProjectInspectorRoute {
  /// Creates the route.
  const OverlayInspector();
}

/// Canvas / Format (UX-29).
///
/// See ux.md §10.14.
final class CanvasInspector extends ProjectInspectorRoute {
  /// Creates the route.
  const CanvasInspector();
}

/// Transform (UX-23).
///
/// See ux.md §10.2.
final class TransformInspector extends ItemInspectorRoute {
  /// Creates the route.
  const TransformInspector(super.item);

  @override
  TransformInspector withItem(ItemId item) => TransformInspector(item);
}

/// Crop mode (UX-23).
///
/// See ux.md §7.5.
final class CropInspector extends ItemInspectorRoute {
  /// Creates the route.
  const CropInspector(super.item);

  @override
  CropInspector withItem(ItemId item) => CropInspector(item);
}

/// Mask (UX-23).
///
/// See ux.md §10.10.
final class MaskInspector extends ItemInspectorRoute {
  /// Creates the route.
  const MaskInspector(super.item);

  @override
  MaskInspector withItem(ItemId item) => MaskInspector(item);
}

/// Speed and speed curve (UX-25).
///
/// See ux.md §10.3.
final class SpeedInspector extends ItemInspectorRoute {
  /// Creates the route.
  const SpeedInspector(super.item);

  @override
  SpeedInspector withItem(ItemId item) => SpeedInspector(item);
}

/// Audio: volume, fades, pitch, role (UX-33).
///
/// See ux.md §10.4.
final class AudioInspector extends ItemInspectorRoute {
  /// Creates the route.
  const AudioInspector(super.item, {this.focus = AudioPanelFocus.volume});

  /// The focused section.
  final AudioPanelFocus focus;

  @override
  AudioInspector withItem(ItemId item) => AudioInspector(item, focus: focus);

  @override
  bool operator ==(Object other) => other is AudioInspector && other.item == item && other.focus == focus;

  @override
  int get hashCode => Object.hash(AudioInspector, item, focus);

  @override
  String toString() => 'AudioInspector($item, ${focus.name})';
}

/// Adjust: light, colour, detail (UX-24).
///
/// See ux.md §10.6.
final class AdjustInspector extends ItemInspectorRoute {
  /// Creates the route.
  const AdjustInspector(super.item);

  @override
  AdjustInspector withItem(ItemId item) => AdjustInspector(item);
}

/// Filters and LUTs (UX-24).
///
/// See ux.md §10.7.
final class FiltersInspector extends ItemInspectorRoute {
  /// Creates the route.
  const FiltersInspector(super.item);

  @override
  FiltersInspector withItem(ItemId item) => FiltersInspector(item);
}

/// Chroma key (UX-28).
///
/// See ux.md §10.10.
final class ChromaInspector extends ItemInspectorRoute {
  /// Creates the route.
  const ChromaInspector(super.item);

  @override
  ChromaInspector withItem(ItemId item) => ChromaInspector(item);
}

/// Keyframes list (UX-26).
///
/// See ux.md §10.11.
final class KeyframesInspector extends ItemInspectorRoute {
  /// Creates the route.
  const KeyframesInspector(super.item);

  @override
  KeyframesInspector withItem(ItemId item) => KeyframesInspector(item);
}

/// Text (UX-30).
///
/// See ux.md §10.8.
final class TextInspector extends ItemInspectorRoute {
  /// Creates the route.
  const TextInspector(super.item, {this.tab = TextPanelTab.edit});

  /// The open tab.
  final TextPanelTab tab;

  @override
  TextInspector withItem(ItemId item) => TextInspector(item, tab: tab);

  @override
  bool operator ==(Object other) => other is TextInspector && other.item == item && other.tab == tab;

  @override
  int get hashCode => Object.hash(TextInspector, item, tab);

  @override
  String toString() => 'TextInspector($item, ${tab.name})';
}

/// Clip info (UX-35).
///
/// See ux.md §10.15.
final class ClipInfoInspector extends ItemInspectorRoute {
  /// Creates the route.
  const ClipInfoInspector(super.item);

  @override
  ClipInfoInspector withItem(ItemId item) => ClipInfoInspector(item);
}

/// Subtitles of one track, optionally focused on one cue (UX-31). A null [track] shows the
/// Captions tool's start state (add a subtitle track, Auto captions, import).
///
/// See ux.md §10.9.
final class SubtitlesInspector extends InspectorRoute {
  /// Creates the route.
  const SubtitlesInspector({this.track, this.cue, this.section = SubtitlesPanelSection.cues});

  /// The subtitle track, or null.
  final TrackId? track;

  /// The focused cue, or null.
  final ItemId? cue;

  /// The shown section.
  final SubtitlesPanelSection section;

  @override
  ItemId? get target => cue;

  @override
  InspectorRoute? retarget(ItemId item) => item == cue ? this : null;

  @override
  bool operator ==(Object other) => other is SubtitlesInspector && other.track == track && other.cue == cue && other.section == section;

  @override
  int get hashCode => Object.hash(SubtitlesInspector, track, cue, section);

  @override
  String toString() => 'SubtitlesInspector($track, $cue, ${section.name})';
}

/// One transition, addressed by its cut (UX-27).
///
/// See ux.md §10.12.
final class TransitionInspector extends InspectorRoute {
  /// Creates the route.
  const TransitionInspector(this.cut);

  /// The cut between two items.
  final TransitionRef cut;

  @override
  ItemId? get target => null;

  @override
  InspectorRoute? retarget(ItemId item) => null;

  @override
  bool operator ==(Object other) => other is TransitionInspector && other.cut == cut;

  @override
  int get hashCode => Object.hash(TransitionInspector, cut);

  @override
  String toString() => 'TransitionInspector(${cut.track}: ${cut.left}|${cut.right})';
}

// -------------------------------------------------------------------------------------------------
// 1.2.0 (INT-101): Still Photo Mode routes (VED plan §6.1, §6.2; BUILD_PLAN VED-01, VED-26).
// -------------------------------------------------------------------------------------------------

/// A category tab of the Beauty & Retouching inspector (VED plan §6.2, BUILD_PLAN VED-26), shared
/// by the clip inspector and the photo tool tray.
///
/// See VED plan §6.2.
enum BeautyCategory {
  /// Face shape and slimming (VED-20).
  faceShape,

  /// Eyes and eyebrows (VED-21).
  eyesBrows,

  /// Nose and lips (VED-22).
  noseLips,

  /// Skin retouching and teeth (VED-23).
  skin,

  /// Virtual makeup and appearance (VED-24).
  makeup,

  /// Body reshaping (VED-25).
  body,

  /// Filters, portrait bokeh and stickers (VED-34).
  filters,

  /// Beauty presets and automatic enhancement (VED-28).
  presets,
}

/// The panel of the Still Photo Mode screen: one tray tool of the open photo (VED-01). Stills have
/// no timeline item, so these routes are separate from [InspectorRoute] and the photo screen hosts
/// them itself.
///
/// See VED plan §6.1, ARCH v1.2 §6.1.
@immutable
final class PhotoToolRoute {
  /// Creates the route; [beautyCategory] is the open tab of the [PhotoToolId.beauty] tool.
  const PhotoToolRoute(this.tool, {this.beautyCategory = BeautyCategory.faceShape});

  /// The tray tool.
  final PhotoToolId tool;

  /// The open beauty tab (meaningful for [PhotoToolId.beauty] only).
  final BeautyCategory beautyCategory;

  /// This route with the beauty tab [category].
  PhotoToolRoute withBeautyCategory(BeautyCategory category) => PhotoToolRoute(tool, beautyCategory: category);

  @override
  bool operator ==(Object other) =>
      other is PhotoToolRoute &&
      other.tool == tool &&
      (tool != PhotoToolId.beauty || other.beautyCategory == beautyCategory);

  @override
  int get hashCode => tool == PhotoToolId.beauty ? Object.hash(tool, beautyCategory) : tool.hashCode;

  @override
  String toString() =>
      tool == PhotoToolId.beauty ? 'PhotoToolRoute(${tool.name}, ${beautyCategory.name})' : 'PhotoToolRoute(${tool.name})';
}

/// The Beauty & Retouching tab of the clip inspector for one timeline clip (VED plan §6.2,
/// BUILD_PLAN VED-26), opened by `EditorActionId.beauty` while `DANAVIEW_BEAUTY` is on.
///
/// It re-targets like an item route (same tab, new clip). It is not yet a member of the sealed
/// [InspectorRoute] family: a new subtype breaks the exhaustive route switches of UX-16's
/// `InspectorHost` and `ToolSets`, so the clip inspector hosts it once those files gain a
/// `BeautyInspector` arm ([INTEGRATION] with VED-26).
///
/// See VED plan §6.2, ARCH v1.2 §6.4.
@immutable
final class BeautyInspector {
  /// Creates the route on [item] with the tab [category].
  const BeautyInspector(this.item, {this.category = BeautyCategory.faceShape});

  /// The edited clip.
  final ItemId item;

  /// The open category tab.
  final BeautyCategory category;

  /// The item the panel edits.
  ItemId get target => item;

  /// This route for [item] (same tab).
  BeautyInspector withItem(ItemId item) => BeautyInspector(item, category: category);

  /// This route with the tab [category].
  BeautyInspector withCategory(BeautyCategory category) => BeautyInspector(item, category: category);

  /// The route to show when the selection changes to [item]: the same tab on the new clip.
  BeautyInspector retarget(ItemId item) => item == this.item ? this : withItem(item);

  @override
  bool operator ==(Object other) => other is BeautyInspector && other.item == item && other.category == category;

  @override
  int get hashCode => Object.hash(BeautyInspector, item, category);

  @override
  String toString() => 'BeautyInspector($item, ${category.name})';
}
