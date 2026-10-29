// OWNER: HOM-30
//
// Turning a drawing, a typed name or a photo into a signature image (HOM plan §8.5): a transparent
// PNG cropped to the ink. Drawn strokes and typed names are painted by Flutter at a high scale on a
// transparent canvas; a photo is decoded (at most [signaturePhotoMaxSide] px), its background is
// removed by a luminance threshold (Otsu's method over the photo, with a soft edge so the strokes
// stay smooth; the ink keeps its own colour) and it is cropped to the ink. The pixel work runs in a
// background isolate. No image or path is logged (rule 30).

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Signature ink: black and dark blue.
const List<int> signatureInkColors = [0xFF111111, 0xFF1A2F8A];

/// The spoken names of [signatureInkColors].
const Map<int, String> signatureInkNames = {0xFF111111: 'Black', 0xFF1A2F8A: 'Dark blue'};

/// Imported photos are decoded at most this many pixels on their longer side.
const int signaturePhotoMaxSide = 1600;

/// Drawn and typed signatures are rendered at this many pixels per logical pixel.
const double signatureRenderScale = 3;

/// Transparent space kept around the ink (pixels).
const int signatureInkPadding = 6;

/// An RGBA image (straight alpha, row-major).
@immutable
final class SignatureBitmap {
  /// [rgba] of [width] × [height] pixels.
  const SignatureBitmap(this.width, this.height, this.rgba);

  /// Pixels across.
  final int width;

  /// Pixels down.
  final int height;

  /// 4 bytes per pixel.
  final Uint8List rgba;

  /// The alpha of pixel ([x], [y]).
  int alphaAt(int x, int y) => rgba[(y * width + x) * 4 + 3];

  @override
  String toString() => 'SignatureBitmap($width×$height)';
}

/// The rect of [b]'s pixels with alpha above [minAlpha], grown by [padding] and kept inside the
/// image; null when there is none.
({int left, int top, int width, int height})? inkBounds(SignatureBitmap b, {int minAlpha = 8, int padding = signatureInkPadding}) {
  var minX = b.width, minY = b.height, maxX = -1, maxY = -1;
  for (var y = 0; y < b.height; y++) {
    final row = y * b.width * 4;
    for (var x = 0; x < b.width; x++) {
      if (b.rgba[row + x * 4 + 3] > minAlpha) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) return null;
  final left = math.max(0, minX - padding);
  final top = math.max(0, minY - padding);
  final right = math.min(b.width - 1, maxX + padding);
  final bottom = math.min(b.height - 1, maxY + padding);
  return (left: left, top: top, width: right - left + 1, height: bottom - top + 1);
}

/// [b] cropped to its ink (with padding); null without ink.
SignatureBitmap? cropToInk(SignatureBitmap b) {
  final r = inkBounds(b);
  if (r == null) return null;
  if (r.left == 0 && r.top == 0 && r.width == b.width && r.height == b.height) return b;
  final out = Uint8List(r.width * r.height * 4);
  for (var y = 0; y < r.height; y++) {
    final src = ((r.top + y) * b.width + r.left) * 4;
    out.setRange(y * r.width * 4, (y + 1) * r.width * 4, b.rgba, src);
  }
  return SignatureBitmap(r.width, r.height, out);
}

int _luma(Uint8List p, int o) => (p[o] * 299 + p[o + 1] * 587 + p[o + 2] * 114) ~/ 1000;

/// The luminance below which [b]'s pixels are ink: Otsu's split of its opaque pixels.
int otsuThreshold(SignatureBitmap b) {
  final hist = List<int>.filled(256, 0);
  var total = 0;
  for (var o = 0; o < b.rgba.length; o += 4) {
    if (b.rgba[o + 3] < 128) continue;
    hist[_luma(b.rgba, o)]++;
    total++;
  }
  if (total == 0) return 128;
  var sum = 0.0;
  for (var i = 0; i < 256; i++) {
    sum += i * hist[i];
  }
  // The split with the largest between-class variance; the threshold is halfway between the two
  // classes' means, so a wide gap (ink far darker than paper) is split in its middle.
  var sumB = 0.0, wB = 0, best = -1.0, threshold = 128;
  for (var t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    final mB = sumB / wB;
    final mF = (sum - sumB) / wF;
    final between = wB * wF * (mB - mF) * (mB - mF);
    if (between > best) {
      best = between;
      threshold = ((mB + mF) / 2).round();
    }
  }
  return threshold;
}

/// Why a photo gave no signature.
enum SignaturePhotoProblem {
  /// Nothing dark enough to be ink.
  noInk,

  /// Too much is dark: not a signature on light paper.
  notOnPaper,
}

/// The result of [cleanSignaturePhoto]: a bitmap, or the problem.
typedef SignaturePhotoResult = ({SignatureBitmap? bitmap, SignaturePhotoProblem? problem});

/// Removes the light background of a signature photo [b]: pixels darker than the paper become ink
/// in their own colour, with an alpha ramp over [edge] luminance levels below the threshold so
/// strokes stay smooth; the rest becomes transparent; cropped to the ink.
SignaturePhotoResult cleanSignaturePhoto(SignatureBitmap b, {int? threshold, int edge = 40}) {
  final t = threshold ?? otsuThreshold(b);
  // The paper's own luminance is above the threshold; a dark image (t very low) has no paper.
  final out = Uint8List(b.rgba.length);
  var ink = 0, opaque = 0;
  final hi = t;
  final lo = math.max(0, t - edge);
  for (var o = 0; o < b.rgba.length; o += 4) {
    if (b.rgba[o + 3] < 128) continue;
    opaque++;
    final l = _luma(b.rgba, o);
    if (l >= hi) continue;
    final a = l <= lo ? 255 : (255 * (hi - l) / (hi - lo)).round();
    out[o] = b.rgba[o];
    out[o + 1] = b.rgba[o + 1];
    out[o + 2] = b.rgba[o + 2];
    out[o + 3] = a;
    if (a > 128) ink++;
  }
  if (ink == 0 || opaque == 0) return (bitmap: null, problem: SignaturePhotoProblem.noInk);
  if (ink > opaque * 0.45) return (bitmap: null, problem: SignaturePhotoProblem.notOnPaper);
  final cropped = cropToInk(SignatureBitmap(b.width, b.height, out));
  if (cropped == null) return (bitmap: null, problem: SignaturePhotoProblem.noInk);
  return (bitmap: cropped, problem: null);
}

/// [cleanSignaturePhoto] in a background isolate.
Future<SignaturePhotoResult> cleanSignaturePhotoInBackground(SignatureBitmap b) => compute(_clean, b);

SignaturePhotoResult _clean(SignatureBitmap b) => cleanSignaturePhoto(b);

/// [cropToInk] in a background isolate.
Future<SignatureBitmap?> cropToInkInBackground(SignatureBitmap b) => compute(cropToInk, b);

/// The RGBA pixels of [image] (straight alpha).
Future<SignatureBitmap> bitmapOf(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  if (data == null) throw StateError('no pixels');
  return SignatureBitmap(image.width, image.height, data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
}

/// [b] as PNG bytes.
Future<Uint8List> encodeSignaturePng(SignatureBitmap b) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(b.rgba);
  final descriptor = ui.ImageDescriptor.raw(buffer, width: b.width, height: b.height, pixelFormat: ui.PixelFormat.rgba8888);
  final codec = await descriptor.instantiateCodec();
  try {
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    if (png == null) throw StateError('not encoded');
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } finally {
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

/// Decodes the image file [bytes] at most [maxSide] pixels on its longer side.
Future<SignatureBitmap> decodeSignaturePhoto(Uint8List bytes, {int maxSide = signaturePhotoMaxSide}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final w = descriptor.width, h = descriptor.height;
  final scale = math.min(1.0, maxSide / math.max(w, h));
  final codec = await descriptor.instantiateCodec(
    targetWidth: math.max(1, (w * scale).round()),
    targetHeight: math.max(1, (h * scale).round()),
  );
  try {
    final frame = await codec.getNextFrame();
    try {
      return await bitmapOf(frame.image);
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

/// The smooth path through [points]: quadratic curves through the midpoints, so a stroke drawn
/// fast doesn't look like a polygon; one point is a dot.
Path smoothStrokePath(List<Offset> points) {
  final path = Path();
  if (points.isEmpty) return path;
  path.moveTo(points.first.dx, points.first.dy);
  if (points.length == 1) {
    path.lineTo(points.first.dx + 0.01, points.first.dy);
    return path;
  }
  for (var i = 1; i < points.length - 1; i++) {
    final mid = Offset((points[i].dx + points[i + 1].dx) / 2, (points[i].dy + points[i + 1].dy) / 2);
    path.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
  }
  path.lineTo(points.last.dx, points.last.dy);
  return path;
}

/// The ink paint of a drawn signature.
Paint signatureInkPaint(Color color, double width) => Paint()
  ..color = color
  ..style = PaintingStyle.stroke
  ..strokeWidth = width
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round
  ..isAntiAlias = true;

/// Stroke width of drawn signatures (logical pixels).
const double signatureStrokeWidth = 3;

Future<SignatureBitmap?> _render(Size size, double scale, void Function(Canvas canvas) paint) async {
  final w = math.max(1, (size.width * scale).ceil());
  final h = math.max(1, (size.height * scale).ceil());
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(scale);
  paint(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  picture.dispose();
  try {
    return cropToInkInBackground(await bitmapOf(image));
  } finally {
    image.dispose();
  }
}

/// [strokes] drawn on a [size] pad in [color], as a cropped transparent bitmap; null without ink.
Future<SignatureBitmap?> renderDrawnSignature(List<List<Offset>> strokes, Size size, Color color, {double scale = signatureRenderScale}) {
  if (strokes.every((s) => s.isEmpty)) return Future.value();
  return _render(size, scale, (canvas) {
    final paint = signatureInkPaint(color, signatureStrokeWidth);
    for (final s in strokes) {
      if (s.isNotEmpty) canvas.drawPath(smoothStrokePath(s), paint);
    }
  });
}

/// [name] typed in [style] (its colour is the ink), as a cropped transparent bitmap; null for an
/// empty name.
Future<SignatureBitmap?> renderTypedSignature(String name, TextStyle style, {double scale = signatureRenderScale}) {
  final text = name.trim();
  if (text.isEmpty) return Future.value();
  final painter = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr, maxLines: 1)..layout();
  // Script fonts swing past their line box: room on every side.
  final pad = (style.fontSize ?? 48) * 0.5;
  final size = Size(painter.width + pad * 2, painter.height + pad * 2);
  return _render(size, scale, (canvas) => painter.paint(canvas, Offset(pad, pad))).whenComplete(painter.dispose);
}
