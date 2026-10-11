// OWNER: UX-09
//
// TimelineStyle (ux.md §6.8): tokens derived from VwishColors exactly as specified, the six marker
// colours, and computed foregrounds that keep painted text readable.

import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_style.dart';
import 'package:vwish_editor_core/model.dart' show TrackKind;
import 'package:vwish_editor_core/ops.dart' show markerPaletteSize;
import 'package:vwish_ui_kit/vwish_ui_kit.dart' show VwishColors, VwishFonts;

void main() {
  final s = TimelineStyle.standard;

  test('tokens are the ux.md §6.8 table', () {
    expect(s.laneBackground, VwishColors.background);
    expect(s.laneSeparator, VwishColors.hairlineSubtle);
    expect(s.videoAccent, VwishColors.primary);
    expect(s.overlayAccent, VwishColors.purple);
    expect(s.audioFill, VwishColors.cyan.withAlpha(0x29));
    expect(s.audioWave, VwishColors.cyan.withAlpha(0xCC));
    expect(s.textFill, VwishColors.warning.withAlpha(0x33));
    expect(s.subtitleFill, VwishColors.success.withAlpha(0x29));
    expect(s.selection, VwishColors.primaryLight);
    expect(s.playhead, VwishColors.textPrimary);
    expect(s.snapGuide, VwishColors.primaryLight);
    expect(s.offlineFill, VwishColors.error.withAlpha(0x33));
    expect(s.offlineHatch, const Color(0x14FFFFFF));
    expect(s.marker, VwishColors.warning);
    expect(s.labelChip, VwishColors.overlayDark);
    expect(s.fontFamily, VwishFonts.family);
    expect(s.lockedOpacity, 0.6);
    expect(s.hiddenOpacity, 0.4);
  });

  test('six marker colours, one per core palette index; out-of-range indices use the default', () {
    expect(s.markerPalette, hasLength(markerPaletteSize));
    expect(s.markerPalette.toSet(), hasLength(markerPaletteSize), reason: 'distinct');
    expect(s.markerColor(0), VwishColors.warning);
    expect(s.markerColor(markerPaletteSize), s.marker);
    expect(s.markerColor(-1), s.marker);
  });

  test('fills and accents by lane kind', () {
    expect(s.clipFill(TrackKind.video), s.videoFill);
    expect(s.clipFill(TrackKind.overlay), s.videoFill);
    expect(s.clipFill(TrackKind.audio), s.audioFill);
    expect(s.clipFill(TrackKind.text), s.textFill);
    expect(s.clipFill(TrackKind.subtitle), s.subtitleFill);
    expect(s.laneAccent(TrackKind.video), VwishColors.primary);
    expect(s.laneAccent(TrackKind.overlay), VwishColors.purple);
    expect({for (final k in TrackKind.values) s.laneAccent(k)}, hasLength(TrackKind.values.length));
  });

  test('clip labels keep >= 7:1 on the overlayDark chip over any thumbnail', () {
    expect(s.labelForeground, VwishColors.textPrimary);
    for (final backdrop in const [Color(0xFFFFFFFF), Color(0xFF000000), Color(0xFFFFEB3B), Color(0xFF00E5FF), Color(0xFF808080)]) {
      final chip = Color.alphaBlend(s.labelChip, backdrop);
      expect(VwishColors.contrastRatio(s.labelForeground, chip), greaterThanOrEqualTo(7), reason: 'over $backdrop');
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
    expect(s.markerForeground(0), VwishColors.textOnLight, reason: 'dark glyph on the amber flag');
    expect(s.contrast(s.rulerLabelForeground, s.rulerBackground), greaterThanOrEqualTo(4.5));
    expect(s.rulerLabelForeground, VwishColors.textSecondary);
  });

  test('a ruler label colour without contrast falls back to the readable foreground', () {
    final low = TimelineStyle(rulerLabel: const Color(0xFF202330));
    expect(low.rulerLabelForeground, VwishColors.textPrimary);
  });

  test('translucent colours are judged as painted on the lanes', () {
    expect(s.opaqueOnLanes(s.audioFill), Color.alphaBlend(s.audioFill, VwishColors.background));
    expect(s.opaqueOnLanes(VwishColors.primary), VwishColors.primary);
  });

  test('value semantics and font override', () {
    expect(TimelineStyle(), s);
    expect(TimelineStyle().hashCode, s.hashCode);
    final ahem = s.withFontFamily('Ahem');
    expect(ahem.fontFamily, 'Ahem');
    expect(ahem, isNot(s));
    expect(ahem.withFontFamily(VwishFonts.family), s);
  });
}
