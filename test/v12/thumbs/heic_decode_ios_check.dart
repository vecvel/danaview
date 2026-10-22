// OWNER: HOM-04
//
// ARCH v1.2 V2-28 [VERIFY: HOM-04]: can Flutter's iOS engine decode the HEIC thumbnails the
// Apple thumbnailer writes? A hosted check, not a host test (no `_test.dart` suffix, so
// `flutter test` skips it): it runs as the app's entry point on a booted iOS Simulator, draws a
// 1200 x 800 source locally (nothing downloaded), asks the real `NativeThumbnails` for an M-class
// thumbnail in HEIC and in JPEG, decodes each output through `UiThumbDecoder` (the service's
// decoder), prints one `DV_HEIC_CHECK` line per format and a verdict, then exits.
//
//   flutter run -d <ios-26.5-iphone-16-udid> -t test/v12/thumbs/heic_decode_ios_check.dart
//
// Verdict `DV_HEIC_CHECK verdict=pass` means HEIC was written and decoded; only then may
// `thumbnailFormatFor(TargetPlatform.iOS)` return HEIC again (record the run in
// docs/v1.2/BUILD_STATE.md / the S2 QA report). Nothing here prints paths (rule 30).
// ignore_for_file: depend_on_referenced_packages, avoid_print

import 'dart:io';
import 'dart:ui' as ui;

import 'package:danaview_features/src/library/thumbs/thumb_key.dart';
import 'package:danaview_features/src/library/thumbs/thumbnail_service.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:flutter/widgets.dart';

Future<String> _writeSource(Directory dir) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  const w = 1200.0, h = 800.0;
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, w, h),
    ui.Paint()
      ..shader = ui.Gradient.linear(ui.Offset.zero, const ui.Offset(w, h), const [ui.Color(0xFF1E88E5), ui.Color(0xFFFFB300)]),
  );
  canvas.drawCircle(const ui.Offset(w / 2, h / 2), 220, ui.Paint()..color = const ui.Color(0xFFE53935));
  final image = await rec.endRecording().toImage(w.toInt(), h.toInt());
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final f = File('${dir.path}/source.png');
  await f.writeAsBytes(png!.buffer.asUint8List());
  return f.path;
}

Future<bool> _check(NativeThumbnails gen, String source, Directory dir, NativeThumbnailFormat fmt) async {
  const size = ThumbSizeClass.m;
  try {
    final out = await gen.mediaThumbnail(
      requestId: 'heic-check-${fmt.name}',
      source: source,
      width: size.pixels,
      height: size.pixels,
      outputPath: '${dir.path}/out_${fmt.name}.thumb',
      mode: size.mode,
      format: fmt,
    );
    final bytes = await File(out.path).length();
    try {
      final b = await const UiThumbDecoder().decode(out.path);
      print('DV_HEIC_CHECK requested=${fmt.name} written=${out.format.name} bytes=$bytes decoded=${b.width}x${b.height}');
      b.dispose();
      return out.format == fmt;
    } on Object catch (e) {
      print('DV_HEIC_CHECK requested=${fmt.name} written=${out.format.name} bytes=$bytes decoded=failed error=${e.runtimeType}');
      return false;
    }
  } on Object catch (e) {
    print('DV_HEIC_CHECK requested=${fmt.name} generate=failed error=${e.runtimeType}');
    return false;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ColoredBox(color: Color(0xFF000000)));
  final dir = await Directory.systemTemp.createTemp('dv_heic_check');
  var code = 1;
  try {
    print('DV_HEIC_CHECK os=${Platform.operatingSystem} version=${Platform.operatingSystemVersion.replaceAll(' ', '_')}');
    final source = await _writeSource(dir);
    final gen = NativeThumbnails();
    final jpeg = await _check(gen, source, dir, NativeThumbnailFormat.jpeg);
    final heic = await _check(gen, source, dir, NativeThumbnailFormat.heic);
    print('DV_HEIC_CHECK verdict=${heic ? 'pass' : 'fail'} jpeg=${jpeg ? 'ok' : 'failed'}');
    code = heic && jpeg ? 0 : 1;
  } finally {
    await dir.delete(recursive: true);
  }
  exit(code);
}
