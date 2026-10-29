// OWNER: HOM-30
//
// Making signature images (lib/src/signatures/signature_image.dart): a photo's light background
// becomes transparent and the ink keeps its colour with a soft edge, cropped to the ink; a photo
// without ink or without paper is refused with its reason; Otsu's threshold separates ink from
// paper; strokes are smooth curves; and drawn and typed signatures render to transparent PNGs
// cropped to the ink (real Flutter rendering, run outside the fake clock).

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:danaview_documents/danaview_documents.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [w] × [h] "photo": paper of luminance about 225 (with noise) and dark blue ink in [ink].
SignatureBitmap photo(int w, int h, {Rect ink = Rect.zero, int paper = 225, int seed = 1}) {
  final r = math.Random(seed);
  final px = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = (y * w + x) * 4;
      final inInk = ink.contains(Offset(x + 0.5, y + 0.5));
      final n = r.nextInt(14) - 7;
      px[o] = inInk ? 20 : (paper + n).clamp(0, 255);
      px[o + 1] = inInk ? 30 : (paper + n).clamp(0, 255);
      px[o + 2] = inInk ? 120 : (paper - 5 + n).clamp(0, 255);
      px[o + 3] = 255;
    }
  }
  return SignatureBitmap(w, h, px);
}

void main() {
  test('a photo loses its paper, keeps its ink colour and is cropped to the ink', () {
    final p = photo(200, 120, ink: const Rect.fromLTWH(40, 50, 100, 12));
    expect(otsuThreshold(p), inInclusiveRange(40, 215));
    final result = cleanSignaturePhoto(p);
    expect(result.problem, isNull);
    final b = result.bitmap!;
    // 100 × 12 of ink plus the padding on each side.
    expect(b.width, 100 + 2 * signatureInkPadding);
    expect(b.height, 12 + 2 * signatureInkPadding);
    expect(b.alphaAt(0, 0), 0, reason: 'the paper is transparent');
    final mid = ((b.height ~/ 2) * b.width + b.width ~/ 2) * 4;
    expect(b.rgba.sublist(mid, mid + 4), [20, 30, 120, 255], reason: 'the ink keeps its colour, opaque');
  });

  test('a blank photo has no ink; a dark one has no paper', () {
    expect(cleanSignaturePhoto(photo(80, 40)).problem, SignaturePhotoProblem.noInk);
    expect(cleanSignaturePhoto(photo(80, 40, ink: const Rect.fromLTWH(0, 0, 80, 30))).problem, SignaturePhotoProblem.notOnPaper);
    expect(signaturePhotoProblemText(SignaturePhotoProblem.noInk), contains('dark ink on light paper'));
  });

  test('a soft edge: pixels just under the paper are partly transparent', () {
    final px = Uint8List.fromList([
      for (final l in [230, 230, 230, 200, 120, 20]) ...[l, l, l, 255],
    ]);
    final b = cleanSignaturePhoto(SignatureBitmap(6, 1, px), threshold: 210, edge: 100).bitmap!;
    // Cropped to the ink with padding (kept inside): all 6 columns.
    final alphas = [for (var x = 0; x < b.width; x++) b.alphaAt(x, 0)];
    expect(alphas.take(3), [0, 0, 0]);
    expect(alphas[3], inExclusiveRange(0, 60));
    expect(alphas[4], inExclusiveRange(150, 255));
    expect(alphas[5], 255);
  });

  test('crop to the ink, and nothing without ink', () {
    final px = Uint8List(10 * 10 * 4);
    px[(5 * 10 + 7) * 4 + 3] = 255;
    final c = cropToInk(SignatureBitmap(10, 10, px))!;
    expect((c.width, c.height), (10 - 1, 10), reason: 'the padding stays inside the image');
    expect(cropToInk(SignatureBitmap(4, 4, Uint8List(64))), isNull);
    expect(inkBounds(SignatureBitmap(10, 10, px), padding: 0), (left: 7, top: 5, width: 1, height: 1));
  });

  test('strokes are smooth curves; a single point is a dot', () {
    final path = smoothStrokePath(const [Offset(0, 0), Offset(10, 20), Offset(20, 0), Offset(30, 20)]);
    final b = path.getBounds();
    expect(b.left, 0);
    expect(b.right, 30, reason: 'from the first point to the last');
    final length = path.computeMetrics().fold<double>(0, (l, m) => l + m.length);
    expect(length, lessThan(3 * math.sqrt(500)), reason: 'the curve cuts the corners of the polyline');
    expect(smoothStrokePath(const [Offset(5, 5)]).getBounds().left, 5);
    expect(smoothStrokePath(const []).getBounds().isEmpty, isTrue);
  });

  testWidgets('drawn and typed signatures render to transparent PNGs cropped to the ink', (tester) async {
    await tester.runAsync(() async {
      final drawn = await renderDrawnSignature(
        const [
          [Offset(20, 40), Offset(60, 20), Offset(100, 50)],
          [Offset(120, 30)],
        ],
        const Size(300, 100),
        const Color(0xFF1A2F8A),
      );
      expect(drawn, isNotNull);
      // The strokes span x 20…120 and y 20…50 (3 px wide): ~(100 + 3 + 2·pad) × 3 scale.
      expect(drawn!.width, closeTo((100 + 3 + 2 * signatureInkPadding / signatureRenderScale) * signatureRenderScale, 12));
      expect(drawn.height, lessThan(60 * signatureRenderScale));
      expect(drawn.alphaAt(0, 0), 0);
      final png = await encodeSignaturePng(drawn);
      expect(SignatureStore.isPng(png), isTrue);
      expect(SignatureStore.pngSize(png), (drawn.width, drawn.height));
      final codec = await ui.instantiateImageCodec(png);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, drawn.width);
      final round = await bitmapOf(frame.image);
      expect(round.rgba.where((v) => v != 0), isNotEmpty);

      expect(await renderDrawnSignature(const [], const Size(10, 10), const Color(0xFF000000)), isNull);
      final typed = await renderTypedSignature('Ada Lovelace', signatureFallbackFont.style(const Color(0xFF111111), 40));
      expect(typed, isNotNull);
      expect(typed!.width, greaterThan(typed.height), reason: 'a name is wide');
      expect(await renderTypedSignature('  ', const TextStyle(fontSize: 20)), isNull);
    });
  });

  testWidgets('a photo file is decoded at most 1600 px and cleaned off the UI isolate', (tester) async {
    await tester.runAsync(() async {
      final p = photo(400, 200, ink: const Rect.fromLTWH(50, 80, 300, 30));
      final png = await encodeSignaturePng(p);
      final decoded = await decodeSignaturePhoto(png, maxSide: 200);
      expect((decoded.width, decoded.height), (200, 100));
      final cleaned = await cleanSignaturePhotoInBackground(decoded);
      expect(cleaned.problem, isNull);
      expect(cleaned.bitmap!.width, closeTo(150 + 2 * signatureInkPadding, 3));
      final made = await const SignatureImageMaker().photo(png);
      expect(made.problem, isNull);
      expect(SignatureStore.isPng(made.png!), isTrue);
    });
  });
}
