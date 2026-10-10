// OWNER: API-04
//
// Shared helpers of the render-prep tests: font loading (Figtree from vwish_ui_kit, an optional
// host Unicode font standing in for the device's system fallback), spec and request builders.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/plan.dart';

/// Family name the host fallback font is registered under.
const String hostFallbackFamily = 'VwishHostFallback';

bool _figtree = false;
bool? _fallback;

/// Loads Figtree (regular, bold) from the UI kit's bundled files under [figtreeFamily] once.
Future<void> loadFigtree() async {
  if (_figtree) return;
  for (final f in ['Figtree-Regular.ttf', 'Figtree-Bold.ttf']) {
    final file = File('../vwish_ui_kit/fonts/$f');
    expect(file.existsSync(), isTrue, reason: 'Figtree is bundled in vwish_ui_kit');
    await ui.loadFontFromList(file.readAsBytesSync(), fontFamily: 'Figtree');
  }
  _figtree = true;
}

/// Host fonts with wide script coverage (macOS); they play the device's system fallback.
const List<String> hostFallbackCandidates = [
  '/Library/Fonts/Arial Unicode.ttf',
  '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
  '/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf',
];

/// Loads the first available host fallback font; false when none exists (CI without fonts).
Future<bool> loadHostFallback() async {
  final cached = _fallback;
  if (cached != null) return cached;
  for (final path in hostFallbackCandidates) {
    final f = File(path);
    if (f.existsSync()) {
      await ui.loadFontFromList(f.readAsBytesSync(), fontFamily: hostFallbackFamily);
      return _fallback = true;
    }
  }
  return _fallback = false;
}

/// A text layout spec on a 1920×1080 canvas.
TextLayoutSpec spec(
  String text, {
  double fontSizePx = 64,
  double maxWidthPx = 1400,
  TextAlignH align = TextAlignH.center,
  bool bold = false,
  bool italic = false,
  TextBoxSpec? box,
  TextStrokeSpec? stroke,
  TextShadowSpec? shadow,
  List<TextRun>? runs,
  int? maxLines,
  String fontFamily = 'figtree',
  double lineHeight = 1.2,
  double letterSpacingPx = 0,
  int color = 0xFFFFFFFF,
}) =>
    TextLayoutSpec(
      runs: runs ?? [TextRun(text)],
      fontFamily: fontFamily,
      fontSizePx: fontSizePx,
      bold: bold,
      italic: italic,
      color: color,
      letterSpacingPx: letterSpacingPx,
      lineHeight: lineHeight,
      align: align,
      maxWidthPx: maxWidthPx,
      maxLines: maxLines,
      box: box,
      stroke: stroke,
      shadow: shadow,
      scale: 1,
      canvasWidth: 1920,
      canvasHeight: 1080,
    );

/// A sprite request for [s] at [scale] onto an output canvas of [outW]×[outH].
SpriteRequest request(TextLayoutSpec s, {double scale = 1, bool reveal = false, int outW = 1920, int outH = 1080, String id = 'it_t'}) =>
    SpriteRequest(
      key: spriteKeyOf(s, scale, outW, outH, contentFontsVersion, reveal),
      itemId: id,
      source: SpriteSource.text,
      layoutSpec: s.toJson(),
      scale: scale,
      canvasWidth: outW,
      canvasHeight: outH,
      fontsVersion: contentFontsVersion,
      reveal: reveal,
    );

/// Alpha of pixel (x, y) of an RGBA buffer [w] wide.
int alphaAt(List<int> rgba, int w, int x, int y) => rgba[(y * w + x) * 4 + 3];
