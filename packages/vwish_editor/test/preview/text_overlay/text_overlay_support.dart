// OWNER: UX-19
//
// Helpers of the text overlay tests: Figtree loading, projects with styled/animated text, the
// overlay rendered to RGBA, and the export path's equivalent (the API-04 sprite of the same item
// composited with the placement matrix core uses for sprite layers), plus a "within 1 px"
// comparison.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/preview/canvas_geometry.dart';
import 'package:vwish_editor/src/editor/preview/text_overlay_painter.dart';
import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';
import 'package:vwish_editor_core/plan.dart' show SpriteRequest, SpriteSource, contentFontsVersion, spriteKeyOf;
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

const int us = microsPerSecond;

bool _figtree = false;

/// Loads Figtree (regular, bold) from the UI kit under the family the text engine resolves to.
Future<void> loadFigtree() async {
  if (_figtree) return;
  for (final f in ['Figtree-Regular.ttf', 'Figtree-Bold.ttf']) {
    final file = File('../vwish_ui_kit/fonts/$f');
    expect(file.existsSync(), isTrue, reason: 'Figtree is bundled in vwish_ui_kit');
    await ui.loadFontFromList(file.readAsBytesSync(), fontFamily: figtreeFamily);
  }
  _figtree = true;
}

/// A 1920×1080 30 fps project with one text item [text] (0–[duration]) in [style] with
/// [animation], after [extra] commands built from the item id.
(EditProject, ItemId) textProject(
  String text, {
  TextStyleSpec style = const TextStyleSpec(),
  TextAnimation animation = const TextAnimation(),
  TimeUs duration = 4 * us,
  List<EditCommand> Function(ItemId id) extra = _none,
}) {
  final now = DateTime.utc(2026, 10, 11);
  final empty = EditProject(
    id: const ProjectId('pr_text'),
    meta: ProjectMeta(name: 'Text', createdAt: now, updatedAt: now),
    timeline: Timeline(),
  );
  final edit = EditSession(empty, ids: SeededIdGenerator(11));
  final added = edit.apply(AddText(0, text: text, duration: duration, style: style));
  if (!added.changed) throw StateError('AddText: $added');
  final id = added.affected.single;
  if (animation != const TextAnimation()) {
    final a = edit.apply(SetTextAnimation([id], animation));
    if (!a.changed) throw StateError('SetTextAnimation: $a');
  }
  for (final c in extra(id)) {
    final out = edit.apply(c);
    if (!out.changed) throw StateError('$c -> $out');
  }
  return (edit.committedProject, id);
}

List<EditCommand> _none(ItemId id) => const [];

/// RGBA of [image].
Future<Uint8List> rgbaOf(ui.Image image) async {
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  return data.buffer.asUint8List();
}

/// The overlay of [project] at [t] painted at canvas scale [scale] (view = canvas × scale).
Future<ui.Image> overlayImage(TextOverlayScene scene, EditProject project, TimeUs t, {double scale = 1}) async {
  final c = project.settings.canvas;
  final w = (c.widthPx * scale).round();
  final h = (c.heightPx * scale).round();
  final geometry = CanvasGeometry.letterbox(ui.Size(c.widthPx.toDouble(), c.heightPx.toDouble()), ui.Size(w.toDouble(), h.toDouble()));
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  TextOverlayPainter(scene: scene, project: project, playhead: ValueNotifier<TimeUs>(t), geometry: geometry)
      .paint(canvas, ui.Size(w.toDouble(), h.toDouble()));
  return rec.endRecording().toImage(w, h);
}

/// The export path's pixels of [item] at [t]: the API-04 sprite of its layout spec (scale 1, with
/// the glyph map for a typewriter) composited on the canvas with core's placement matrix
/// (`boxAt`: keyframed transform plus the text animation), the evaluated opacity and the
/// typewriter's reveal rule (`RenderMath.spriteTexelDrawn`).
Future<Uint8List> exportLikeRgba(TextSpriteRasterizer rasterizer, EditProject project, ItemId item, TimeUs t) async {
  final c = project.settings.canvas;
  final w = c.widthPx;
  final h = c.heightPx;
  final loc = project.index.locate(item)!;
  final text = loc.item as TextItem;
  final spec = textLayoutSpecOf(text, c);
  final reveal = text.animation.inKind == TextAnimKind.typewriter;
  final request = SpriteRequest(
    key: spriteKeyOf(spec, 1, w, h, contentFontsVersion, reveal),
    itemId: item.value,
    source: SpriteSource.text,
    layoutSpec: spec.toJson(),
    scale: 1,
    canvasWidth: w,
    canvasHeight: h,
    fontsVersion: contentFontsVersion,
    reveal: reveal,
  );
  final sprite = await rasterizer.rasterize(request);
  final anim = evaluateTextAnimation(text, t, c);
  final rgba = Uint8List.fromList(sprite.rgba);
  final glyphs = sprite.glyphs;
  if (glyphs != null) {
    final reveal = anim.reveal;
    for (var i = 0; i < glyphs.length; i++) {
      if (!RenderMath.spriteTexelDrawn(glyphs[i], reveal)) {
        rgba[i * 4] = rgba[i * 4 + 1] = rgba[i * 4 + 2] = rgba[i * 4 + 3] = 0;
      }
    }
  }
  final image = await _imageOf(rgba, sprite.width, sprite.height);
  final box = boxAt(project, item, t, text: rasterizer.engine)!;
  final m = placementMatrix(
    center: box.center,
    base: Size2(sprite.width / sprite.scale, sprite.height / sprite.scale),
    scale: box.scale,
    rotationDeg: box.rotationDeg,
  );
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.transform(Float64List.fromList([m.a, m.b, 0, 0, m.c, m.d, 0, 0, 0, 0, 1, 0, m.tx, m.ty, 0, 1]));
  canvas.scale(1 / sprite.scale);
  final paint = ui.Paint()
    ..filterQuality = ui.FilterQuality.low
    ..color = ui.Color.fromRGBO(0, 0, 0, box.opacity.clamp(0.0, 1.0));
  canvas.drawImage(image, ui.Offset.zero, paint);
  final out = await rec.endRecording().toImage(w, h);
  final bytes = await rgbaOf(out);
  image.dispose();
  out.dispose();
  return bytes;
}

Future<ui.Image> _imageOf(Uint8List rgba, int w, int h) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final descriptor = ui.ImageDescriptor.raw(buffer, width: w, height: h, pixelFormat: ui.PixelFormat.rgba8888);
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return frame.image;
}

/// Bounding box of pixels with alpha above [threshold], or null.
ui.Rect? inkBounds(Uint8List rgba, int w, int h, {int threshold = 24}) {
  var x0 = w, y0 = h, x1 = -1, y1 = -1;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (rgba[(y * w + x) * 4 + 3] > threshold) {
        x0 = math.min(x0, x);
        y0 = math.min(y0, y);
        x1 = math.max(x1, x);
        y1 = math.max(y1, y);
      }
    }
  }
  return x1 < 0 ? null : ui.Rect.fromLTRB(x0.toDouble(), y0.toDouble(), x1 + 1.0, y1 + 1.0);
}

/// The alpha channel of [rgba] box-blurred over 3×3 pixels.
List<int> _blurredAlpha(Uint8List rgba, int w, int h) {
  final out = List<int>.filled(w * h, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var sum = 0;
      var n = 0;
      for (var dy = -1; dy <= 1; dy++) {
        final yy = y + dy;
        if (yy < 0 || yy >= h) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final xx = x + dx;
          if (xx < 0 || xx >= w) continue;
          sum += rgba[(yy * w + xx) * 4 + 3];
          n++;
        }
      }
      out[y * w + x] = sum ~/ n;
    }
  }
  return out;
}

/// Pixels where the 3×3-blurred alphas of [a] and [b] differ by more than [tolerance]: zero when
/// every difference is explained by anti-aliasing and a displacement of at most 1 px (a 1 px shift
/// of a hard edge changes the blurred alpha by at most 85; a 2 px shift by 170).
int mismatchesBeyond1px(Uint8List a, Uint8List b, int w, int h, {int tolerance = 96}) {
  final ba = _blurredAlpha(a, w, h);
  final bb = _blurredAlpha(b, w, h);
  var n = 0;
  for (var i = 0; i < ba.length; i++) {
    if ((ba[i] - bb[i]).abs() > tolerance) n++;
  }
  return n;
}
