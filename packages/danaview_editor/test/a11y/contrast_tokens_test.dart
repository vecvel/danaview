// OWNER: QA-08
//
// Computed contrast (ARCH §1.3 rule 4, ux.md §19.1): every token pair the editor uses for text is
// ≥ 4.5:1. The pixel check (`textContrastGuideline`, run by every QA-08 widget test) only sees text
// that has a semantics node; painted text (clip labels, ruler, markers) and the transient states
// are covered here by computation with `DanaviewColors.contrastRatio`.

import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_style.dart';
import 'package:danaview_editor_core/model.dart' show TrackKind;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

const double _minText = 4.5;

/// Chrome surfaces text sits on (resting states).
const Map<String, Color> _surfaces = {
  'background': DanaviewColors.background,
  'surface': DanaviewColors.surface,
  'surfaceElevated': DanaviewColors.surfaceElevated,
  'surfaceElevatedHigher': DanaviewColors.surfaceElevatedHigher,
  'cardGlass': DanaviewColors.cardGlass,
  'fieldActive': DanaviewColors.fieldActive,
  'overlayDark': DanaviewColors.overlayDark,
  'primaryTonal': DanaviewColors.primaryTonal,
  'primarySoft': DanaviewColors.primarySoft,
};

/// Text and icon-with-text tokens of the chrome.
const Map<String, Color> _textTokens = {
  'textPrimary': DanaviewColors.textPrimary,
  'textSecondary': DanaviewColors.textSecondary,
  'textMuted': DanaviewColors.textMuted,
  'primaryLight': DanaviewColors.primaryLight,
  'errorLight': DanaviewColors.errorLight,
  'warning': DanaviewColors.warning,
  'success': DanaviewColors.success,
  'cyan': DanaviewColors.cyan,
};

/// Solid fills that carry text (buttons, solid badges, selected segments and chips).
const Map<String, Color> _solidFills = {
  'primary': DanaviewColors.primary,
  'primaryDark': DanaviewColors.primaryDark,
  'error': DanaviewColors.error,
  'success': DanaviewColors.success,
  'warning': DanaviewColors.warning,
  'cyan': DanaviewColors.cyan,
  'purple': DanaviewColors.purple,
};

/// Colours of the tinted badges the editor shows (Projects cards, media bin).
const Map<String, Color> _badgeColors = {
  'primaryLight': DanaviewColors.primaryLight,
  'errorLight': DanaviewColors.errorLight,
  'warning': DanaviewColors.warning,
  'textSecondary': DanaviewColors.textSecondary,
};

void main() {
  test('chrome text tokens keep 4.5:1 on every chrome surface', () {
    final failures = <String>[];
    for (final fg in _textTokens.entries) {
      for (final bg in _surfaces.entries) {
        final ratio = DanaviewColors.contrastRatio(fg.value, bg.value);
        if (ratio < _minText) failures.add('${fg.key} on ${bg.key}: ${ratio.toStringAsFixed(2)}');
      }
    }
    expect(failures, isEmpty);
  });

  test('foregroundOn picks a readable foreground for every solid fill', () {
    for (final fill in _solidFills.entries) {
      final fg = DanaviewColors.foregroundOn(fill.value);
      expect(DanaviewColors.contrastRatio(fg, fill.value), greaterThanOrEqualTo(_minText), reason: fill.key);
    }
  });

  test('tinted badges (10 % fill, DanaviewBadge.tintFor) keep 4.5:1 on the cards they sit on', () {
    for (final color in _badgeColors.entries) {
      for (final card in const [DanaviewColors.cardGlass, DanaviewColors.surface, DanaviewColors.surfaceElevated]) {
        final bg = Color.alphaBlend(DanaviewBadge.tintFor(color.value), card);
        expect(DanaviewColors.contrastRatio(color.value, bg), greaterThanOrEqualTo(_minText), reason: '${color.key} on $card');
      }
    }
  });

  test('the theme text styles use readable tokens', () {
    for (final style in [
      DanaviewTextStyles.largeTitle,
      DanaviewTextStyles.title,
      DanaviewTextStyles.headline,
      DanaviewTextStyles.body,
      DanaviewTextStyles.bodySecondary,
      DanaviewTextStyles.label,
      DanaviewTextStyles.caption,
      DanaviewTextStyles.micro,
    ]) {
      for (final bg in _surfaces.entries) {
        expect(DanaviewColors.contrastRatio(style.color!, bg.value), greaterThanOrEqualTo(_minText), reason: '$style on ${bg.key}');
      }
    }
  });

  group('painted timeline text', () {
    final style = TimelineStyle();

    test('clip labels on their chip over any thumbnail', () {
      for (final backdrop in const [Color(0xFFFFFFFF), Color(0xFF000000), Color(0xFF808080), Color(0xFFFFFF00)]) {
        final chip = Color.alphaBlend(style.labelChip, backdrop);
        expect(DanaviewColors.contrastRatio(style.labelForeground, chip), greaterThanOrEqualTo(_minText), reason: 'over $backdrop');
      }
    });

    test('text and cue excerpts on their lane fill, markers, ruler labels', () {
      for (final kind in TrackKind.values) {
        expect(style.contrast(style.clipForeground(kind), style.clipFill(kind)), greaterThanOrEqualTo(_minText), reason: '$kind');
      }
      for (var i = 0; i < style.markerPalette.length; i++) {
        expect(style.contrast(style.markerForeground(i), style.markerColor(i)), greaterThanOrEqualTo(_minText), reason: 'marker $i');
      }
      expect(style.contrast(style.rulerLabelForeground, style.rulerBackground), greaterThanOrEqualTo(_minText));
    });
  });
}
