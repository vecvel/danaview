// OWNER: UX-09
//
// Editor colour tokens of the timeline (ux.md §6.8), derived from `DanaviewColors`, plus the
// foreground colours computed from them so painted text always keeps its contrast: clip labels sit
// on an `overlayDark` chip (white text >= 7:1 over any thumbnail), ruler labels on the ruler
// surface (>= 4.5:1), marker glyphs on their flag colour. Colours never carry meaning alone: lanes
// have icons and names, badges have glyphs (UX-10/UX-11).

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:danaview_editor_core/model.dart' show TrackKind;
import 'package:danaview_ui_kit/danaview_ui_kit.dart' show DanaviewColors, DanaviewFonts;

/// Colour tokens and text styling of the timeline painters (ruler, canvas, interaction and
/// playhead layers). [TimelineStyle.standard] is the editor's style; tests may override
/// [fontFamily] (for example with the Ahem test font in goldens).
@immutable
final class TimelineStyle {
  /// Creates a style; every token defaults to its ux.md §6.8 value.
  TimelineStyle({
    this.laneBackground = DanaviewColors.background,
    this.laneSeparator = DanaviewColors.hairlineSubtle,
    this.videoAccent = DanaviewColors.primary,
    this.overlayAccent = DanaviewColors.purple,
    this.audioAccent = DanaviewColors.cyan,
    this.textAccent = DanaviewColors.warning,
    this.subtitleAccent = DanaviewColors.success,
    this.videoFill = DanaviewColors.surfaceElevatedHigher,
    Color? audioFill,
    Color? audioWave,
    Color? textFill,
    Color? subtitleFill,
    this.selection = DanaviewColors.primaryLight,
    this.playhead = DanaviewColors.textPrimary,
    this.snapGuide = DanaviewColors.primaryLight,
    Color? offlineFill,
    this.offlineHatch = const Color(0x14FFFFFF),
    this.lockedHatch = const Color(0x14FFFFFF),
    this.gapHatch = DanaviewColors.hairline,
    this.labelChip = DanaviewColors.overlayDark,
    List<Color>? markerPalette,
    this.rulerBackground = DanaviewColors.surface,
    this.rulerSeparator = DanaviewColors.hairline,
    this.rulerMajorTick = DanaviewColors.textMuted,
    this.rulerMinorTick = DanaviewColors.bufferTrack,
    this.rulerLabel = DanaviewColors.textSecondary,
    this.fontFamily = DanaviewFonts.family,
    this.lockedOpacity = 0.6,
    this.hiddenOpacity = 0.4,
  })  : audioFill = audioFill ?? DanaviewColors.cyan.withAlpha(0x29),
        audioWave = audioWave ?? DanaviewColors.cyan.withAlpha(0xCC),
        textFill = textFill ?? DanaviewColors.warning.withAlpha(0x33),
        subtitleFill = subtitleFill ?? DanaviewColors.success.withAlpha(0x29),
        offlineFill = offlineFill ?? DanaviewColors.error.withAlpha(0x33),
        markerPalette = List.unmodifiable(markerPalette ?? defaultMarkerPalette) {
    assert(this.markerPalette.isNotEmpty, 'the marker palette needs at least the default colour');
  }

  /// The editor's timeline style.
  static final TimelineStyle standard = TimelineStyle();

  /// The six marker colours (ux.md §8.5); index 0 is the default `warning`. `Marker.colorIndex`
  /// (core, `markerPaletteSize` = 6) indexes this list.
  static const List<Color> defaultMarkerPalette = [
    DanaviewColors.warning,
    DanaviewColors.error,
    DanaviewColors.success,
    DanaviewColors.cyan,
    DanaviewColors.primaryLight,
    DanaviewColors.purple,
  ];

  // ---- Lanes ------------------------------------------------------------------------------------

  /// Lane background (`background`).
  final Color laneBackground;

  /// The 1 px line between lanes (`hairlineSubtle`).
  final Color laneSeparator;

  /// Main video lane header icon and the selected tool's tint (`primary`).
  final Color videoAccent;

  /// Overlay/PiP clips: the 3 px top stripe (`purple`).
  final Color overlayAccent;

  /// Audio lane icon tint (`cyan`).
  final Color audioAccent;

  /// Text lane icon tint (`warning`).
  final Color textAccent;

  /// Subtitle lane icon tint (`success`).
  final Color subtitleAccent;

  // ---- Clips ------------------------------------------------------------------------------------

  /// Video, image and freeze clip bodies and missing thumbnail cells (`surfaceElevatedHigher`).
  final Color videoFill;

  /// Audio clip bodies (`cyan @ 0x29`).
  final Color audioFill;

  /// Waveform lines (`cyan @ 0xCC`).
  final Color audioWave;

  /// Text clip bodies (`warning @ 0x33`).
  final Color textFill;

  /// Subtitle cue bodies (`success @ 0x29`).
  final Color subtitleFill;

  /// The 2 px inner outline of selected items and the accent of their handles (`primaryLight`).
  final Color selection;

  /// The 2 px playhead line and its knob (`textPrimary`).
  final Color playhead;

  /// The 1 px snap guide and its time pill (`primaryLight`).
  final Color snapGuide;

  /// Missing-media fill (`error @ 0x33`).
  final Color offlineFill;

  /// The hatch over missing media (`0x14FFFFFF`).
  final Color offlineHatch;

  /// The hatch over clips of locked lanes.
  final Color lockedHatch;

  /// The hatch of main-lane gaps.
  final Color gapHatch;

  /// Background of clip label chips (`overlayDark`).
  final Color labelChip;

  /// Marker colours (see [defaultMarkerPalette]).
  final List<Color> markerPalette;

  /// Opacity of clips on locked lanes.
  final double lockedOpacity;

  /// Opacity of clips on hidden lanes.
  final double hiddenOpacity;

  // ---- Ruler ------------------------------------------------------------------------------------

  /// Ruler surface (`surface`).
  final Color rulerBackground;

  /// The 1 px line under the ruler (`hairline`).
  final Color rulerSeparator;

  /// Major ticks (`textMuted`).
  final Color rulerMajorTick;

  /// Minor ticks (`bufferTrack`).
  final Color rulerMinorTick;

  /// Requested ruler label colour (`textSecondary`); painted as [rulerLabelForeground].
  final Color rulerLabel;

  /// Font family of painted timeline text (`DanaviewFonts.family`).
  final String fontFamily;

  // ---- Derived ----------------------------------------------------------------------------------

  /// The default marker colour (palette entry 0, `warning`).
  Color get marker => markerPalette.first;

  /// Colour of marker [colorIndex]; out-of-range indices (a newer project) use the default.
  Color markerColor(int colorIndex) =>
      colorIndex >= 0 && colorIndex < markerPalette.length ? markerPalette[colorIndex] : markerPalette.first;

  /// Body fill of items on a lane of [kind] (video and overlay share [videoFill]).
  Color clipFill(TrackKind kind) => switch (kind) {
        TrackKind.video || TrackKind.overlay => videoFill,
        TrackKind.audio => audioFill,
        TrackKind.text => textFill,
        TrackKind.subtitle => subtitleFill,
      };

  /// Accent of lanes of [kind] (header icon tint).
  Color laneAccent(TrackKind kind) => switch (kind) {
        TrackKind.video => videoAccent,
        TrackKind.overlay => overlayAccent,
        TrackKind.audio => audioAccent,
        TrackKind.text => textAccent,
        TrackKind.subtitle => subtitleAccent,
      };

  /// [color] as seen on the lanes: translucent colours composited over [laneBackground].
  Color opaqueOnLanes(Color color) => color.a >= 1.0 ? color : Color.alphaBlend(color, laneBackground);

  /// White or near-black, whichever contrasts more with [background] (translucent backgrounds are
  /// composited over [laneBackground] first).
  Color foregroundOn(Color background) {
    final bg = opaqueOnLanes(background);
    return contrast(DanaviewColors.textPrimary, bg) >= contrast(DanaviewColors.textOnLight, bg)
        ? DanaviewColors.textPrimary
        : DanaviewColors.textOnLight;
  }

  /// WCAG contrast of [foreground] on [background] as painted on the lanes.
  double contrast(Color foreground, Color background) => DanaviewColors.contrastRatio(foreground, opaqueOnLanes(background));

  /// Text colour of clip label chips (white on `overlayDark`).
  Color get labelForeground => foregroundOn(labelChip);

  /// Text colour of clip bodies of [kind] when text sits directly on the fill (text and cue
  /// excerpts).
  Color clipForeground(TrackKind kind) => foregroundOn(clipFill(kind));

  /// Glyph colour drawn on marker [colorIndex]'s flag.
  Color markerForeground(int colorIndex) => foregroundOn(markerColor(colorIndex));

  /// The ruler label colour: [rulerLabel] when it keeps 4.5:1 on [rulerBackground], otherwise the
  /// readable foreground of the ruler surface.
  Color get rulerLabelForeground {
    final bg = opaqueOnLanes(rulerBackground);
    return DanaviewColors.contrastRatio(rulerLabel, bg) >= 4.5 ? rulerLabel : foregroundOn(bg);
  }

  /// A copy with [fontFamily] replaced (tests use the Ahem font in goldens).
  TimelineStyle withFontFamily(String fontFamily) => TimelineStyle(
        laneBackground: laneBackground,
        laneSeparator: laneSeparator,
        videoAccent: videoAccent,
        overlayAccent: overlayAccent,
        audioAccent: audioAccent,
        textAccent: textAccent,
        subtitleAccent: subtitleAccent,
        videoFill: videoFill,
        audioFill: audioFill,
        audioWave: audioWave,
        textFill: textFill,
        subtitleFill: subtitleFill,
        selection: selection,
        playhead: playhead,
        snapGuide: snapGuide,
        offlineFill: offlineFill,
        offlineHatch: offlineHatch,
        lockedHatch: lockedHatch,
        gapHatch: gapHatch,
        labelChip: labelChip,
        markerPalette: markerPalette,
        rulerBackground: rulerBackground,
        rulerSeparator: rulerSeparator,
        rulerMajorTick: rulerMajorTick,
        rulerMinorTick: rulerMinorTick,
        rulerLabel: rulerLabel,
        fontFamily: fontFamily,
        lockedOpacity: lockedOpacity,
        hiddenOpacity: hiddenOpacity,
      );

  @override
  bool operator ==(Object other) =>
      other is TimelineStyle &&
      other.laneBackground == laneBackground &&
      other.laneSeparator == laneSeparator &&
      other.videoAccent == videoAccent &&
      other.overlayAccent == overlayAccent &&
      other.audioAccent == audioAccent &&
      other.textAccent == textAccent &&
      other.subtitleAccent == subtitleAccent &&
      other.videoFill == videoFill &&
      other.audioFill == audioFill &&
      other.audioWave == audioWave &&
      other.textFill == textFill &&
      other.subtitleFill == subtitleFill &&
      other.selection == selection &&
      other.playhead == playhead &&
      other.snapGuide == snapGuide &&
      other.offlineFill == offlineFill &&
      other.offlineHatch == offlineHatch &&
      other.lockedHatch == lockedHatch &&
      other.gapHatch == gapHatch &&
      other.labelChip == labelChip &&
      listEquals(other.markerPalette, markerPalette) &&
      other.rulerBackground == rulerBackground &&
      other.rulerSeparator == rulerSeparator &&
      other.rulerMajorTick == rulerMajorTick &&
      other.rulerMinorTick == rulerMinorTick &&
      other.rulerLabel == rulerLabel &&
      other.fontFamily == fontFamily &&
      other.lockedOpacity == lockedOpacity &&
      other.hiddenOpacity == hiddenOpacity;

  @override
  int get hashCode => Object.hashAll([
        laneBackground,
        laneSeparator,
        videoAccent,
        overlayAccent,
        audioAccent,
        textAccent,
        subtitleAccent,
        videoFill,
        audioFill,
        audioWave,
        textFill,
        subtitleFill,
        selection,
        playhead,
        snapGuide,
        offlineFill,
        offlineHatch,
        lockedHatch,
        gapHatch,
        labelChip,
        Object.hashAll(markerPalette),
        rulerBackground,
        rulerSeparator,
        rulerMajorTick,
        rulerMinorTick,
        rulerLabel,
        fontFamily,
        lockedOpacity,
        hiddenOpacity,
      ]);
}
