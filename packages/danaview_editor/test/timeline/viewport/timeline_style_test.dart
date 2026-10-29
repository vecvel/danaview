// OWNER: UX-09
//
// TimelineStyle (ux.md §6.8): tokens derived from DanaviewColors exactly as specified, the six marker
// colours, and computed foregrounds that keep painted text readable.

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter/painting.dart' show HSVColor;

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_style.dart';
import 'package:danaview_editor_core/model.dart' show TrackKind;
import 'package:danaview_editor_core/ops.dart' show markerPaletteSize;
import 'package:danaview_ui_kit/danaview_ui_kit.dart' show DanaviewColors, DanaviewFonts;

void main() {
  final s = TimelineStyle.standard;

  test('tokens are the ux.md §6.8 table', () {
    expect(s.laneBackground, DanaviewColors.background);
    expect(s.laneSeparator, DanaviewColors.hairlineSubtle);
    expect(s.videoAccent, TimelineStyle.steel);
    expect(s.overlayAccent, TimelineStyle.mauve);
    expect(s.audioAccent, TimelineStyle.teal);
    expect(s.textAccent, TimelineStyle.sand);
    expect(s.subtitleAccent, TimelineStyle.sage);
    expect(s.audioFill, TimelineStyle.teal.withAlpha(0x29));
    expect(s.audioWave, TimelineStyle.teal.withAlpha(0xCC));
    expect(s.textFill, TimelineStyle.sand.withAlpha(0x33));
    expect(s.subtitleFill, TimelineStyle.sage.withAlpha(0x29));
    expect(s.selection, DanaviewColors.primaryLight);
    expect(s.playhead, DanaviewColors.primaryLight);
    expect(s.mark, DanaviewColors.textPrimary);
    expect(s.snapGuide, DanaviewColors.textPrimary);
    expect(s.offlineFill, DanaviewColors.error.withAlpha(0x33));
    expect(s.offlineHatch, const Color(0x14FFFFFF));
    expect(s.marker, DanaviewColors.warning);
    expect(s.labelChip, DanaviewColors.overlayDark);
    expect(s.fontFamily, DanaviewFonts.family);
    expect(s.lockedOpacity, 0.6);
    expect(s.hiddenOpacity, 0.4);
  });

  test('six marker colours, one per core palette index; out-of-range indices use the default', () {
    expect(s.markerPalette, hasLength(markerPaletteSize));
    expect(s.markerPalette.toSet(), hasLength(markerPaletteSize), reason: 'distinct');
    expect(s.markerColor(0), DanaviewColors.warning);
    expect(s.markerColor(markerPaletteSize), s.marker);
    expect(s.markerColor(-1), s.marker);
  });

  test('fills and accents by lane kind', () {
    expect(s.clipFill(TrackKind.video), s.videoFill);
    expect(s.clipFill(TrackKind.overlay), s.videoFill);
    expect(s.clipFill(TrackKind.audio), s.audioFill);
    expect(s.clipFill(TrackKind.text), s.textFill);
    expect(s.clipFill(TrackKind.subtitle), s.subtitleFill);
    expect(s.laneAccent(TrackKind.video), TimelineStyle.steel);
    expect(s.laneAccent(TrackKind.overlay), TimelineStyle.mauve);
    expect({for (final k in TrackKind.values) s.laneAccent(k)}, hasLength(TrackKind.values.length));
  });

  test('lane colours are muted, read on black, and never look like the red accent or the old indigo', () {
    double hue(Color c) => HSVColor.fromColor(c).hue;
    double hueGap(double a, double b) => math.min((a - b).abs(), 360 - (a - b).abs());
    const oldIndigo = Color(0xFF5E60EE);
    for (final k in TrackKind.values) {
      final c = s.laneAccent(k);
      expect(hueGap(hue(c), hue(DanaviewColors.primary)), greaterThan(40), reason: '$k is not red');
      expect(hueGap(hue(c), hue(oldIndigo)), greaterThan(25), reason: '$k is not indigo');
      expect(HSVColor.fromColor(c).saturation, lessThanOrEqualTo(0.5), reason: '$k is muted');
      expect(DanaviewColors.contrastRatio(c, DanaviewColors.surfaceElevated), greaterThanOrEqualTo(3), reason: '$k icon on its header');
    }
  });

  test('clip labels keep >= 7:1 on the overlayDark chip over any thumbnail', () {
    expect(s.labelForeground, DanaviewColors.textPrimary);
    for (final backdrop in const [Color(0xFFFFFFFF), Color(0xFF000000), Color(0xFFFFEB3B), Color(0xFF00E5FF), Color(0xFF808080)]) {
      final chip = Color.alphaBlend(s.labelChip, backdrop);
      expect(DanaviewColors.contrastRatio(s.labelForeground, chip), greaterThanOrEqualTo(7), reason: 'over $backdrop');
    }
  });

  test('computed foregrounds keep >= 4.5:1 on every fill and marker colour', () {
    for (final k in TrackKind.values) {
      final fill = s.clipFill(k);
      expect(s.contrast(s.clipForeground(k), fill), greaterThanOrEqualTo(4.5), reason: '$k');
    }
    for (var i = 0; i < s.markerPalette.length; i++) {
      expect(s.contrast(s.markerForeground(i), s.markerColor(i)), greaterThanOrEqualTo(4.5), reason: 'marker $i');
    }
    expect(s.markerForeground(0), DanaviewColors.textOnLight, reason: 'dark glyph on the amber flag');
    expect(s.contrast(s.rulerLabelForeground, s.rulerBackground), greaterThanOrEqualTo(4.5));
    expect(s.rulerLabelForeground, DanaviewColors.textSecondary);
  });

  test('a ruler label colour without contrast falls back to the readable foreground', () {
    final low = TimelineStyle(rulerLabel: const Color(0xFF202330));
    expect(low.rulerLabelForeground, DanaviewColors.textPrimary);
  });

  test('translucent colours are judged as painted on the lanes', () {
    expect(s.opaqueOnLanes(s.audioFill), Color.alphaBlend(s.audioFill, DanaviewColors.background));
    expect(s.opaqueOnLanes(DanaviewColors.primary), DanaviewColors.primary);
  });

  test('value semantics and font override', () {
    expect(TimelineStyle(), s);
    expect(TimelineStyle().hashCode, s.hashCode);
    final ahem = s.withFontFamily('Ahem');
    expect(ahem.fontFamily, 'Ahem');
    expect(ahem, isNot(s));
    expect(ahem.withFontFamily(DanaviewFonts.family), s);
  });
}
