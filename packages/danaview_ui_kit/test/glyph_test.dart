import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'test_utils.dart';

const _white = Color(0xFFFFFFFF);

class _Pixels {
  _Pixels(this.data, this.width, this.height);

  final ByteData data;
  final int width;
  final int height;

  int alpha(int x, int y) => data.getUint8((y * width + x) * 4 + 3);

  /// Straight (unpremultiplied) colour of one pixel.
  Color color(int x, int y) {
    final i = (y * width + x) * 4;
    return Color.fromARGB(data.getUint8(i + 3), data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
  }
}

/// Renders [child] centred in a [box]-sized square, [padding] logical px in from the image edge.
Future<_Pixels> _render(
  WidgetTester tester,
  Widget child, {
  required double box,
  double devicePixelRatio = 1,
  double padding = 0,
}) async {
  tester.view.devicePixelRatio = devicePixelRatio;
  tester.view.physicalSize = Size.square((box + padding * 2 + 8) * devicePixelRatio);
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: key,
          child: Padding(
            padding: EdgeInsets.all(padding),
            child: SizedBox.square(dimension: box, child: Center(child: child)),
          ),
        ),
      ),
    ),
  );
  expect(tester.takeException(), isNull);
  return _capture(tester, key, devicePixelRatio);
}

/// Alpha-weighted ink area (in design units squared) and centroid, and the middle of the inked
/// rows (both in design units), of a glyph [size] logical px wide, centred in a [box] square.
({double area, Offset centroid, double outlineMiddle}) _ink(
  _Pixels p, {
  required double size,
  required double box,
  required double dpr,
}) {
  var ink = 0.0;
  var sx = 0.0;
  var sy = 0.0;
  int? top;
  var bottom = 0;
  for (var y = 0; y < p.height; y++) {
    for (var x = 0; x < p.width; x++) {
      final a = p.alpha(x, y) / 255;
      if (a > 0.5) {
        top ??= y;
        bottom = y;
      }
      ink += a;
      sx += a * (x + 0.5);
      sy += a * (y + 0.5);
    }
  }
  final unit = size * dpr / 24;
  final offset = (box - size) / 2 * dpr;
  return (
    area: ink / unit / unit,
    centroid: Offset((sx / ink - offset) / unit, (sy / ink - offset) / unit),
    outlineMiddle: ((top! + bottom + 1) / 2 - offset) / unit,
  );
}

/// Pixels along one [row] or [column] that are neither empty nor solid nor a back plate: the
/// anti-aliased fringe of an edge that missed the pixel grid.
int _softPixels(_Pixels p, {int? row, int? column}) {
  var soft = 0;
  final length = row != null ? p.width : p.height;
  for (var i = 0; i < length; i++) {
    final a = row != null ? p.alpha(i, row) : p.alpha(column!, i);
    final back = (DanaviewGlyphPainter.backAlphaFor(_white) * 255).round();
    if (a > 8 && a < 247 && (a - back).abs() > 8) soft++;
  }
  return soft;
}

/// Captures the [RepaintBoundary] under [key] at [dpr].
Future<_Pixels> _capture(WidgetTester tester, GlobalKey key, double dpr) async {
  late _Pixels pixels;
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: dpr);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    pixels = _Pixels(data!, image.width, image.height);
    image.dispose();
  });
  return pixels;
}

void main() {
  testWidgets('every kind paints inside its box at 16, 24, 40 and 96 px', (tester) async {
    for (final dpr in [1.0, 3.0]) {
      for (final size in [16.0, 24.0, 40.0, 96.0]) {
        for (final kind in DanaviewGlyphKind.values) {
          const padding = 6.0;
          final p = await _render(
            tester,
            DanaviewGlyph(kind, size: size, color: _white),
            box: size,
            devicePixelRatio: dpr,
            padding: padding,
          );
          final unit = size * dpr / 24;
          final start = padding * dpr;
          var inked = 0;
          for (var y = 0; y < p.height; y++) {
            for (var x = 0; x < p.width; x++) {
              final a = p.alpha(x, y);
              if (a == 0) continue;
              inked++;
              // The clip is a backstop: the geometry itself keeps half a unit clear of the edge.
              final ux = (x + 0.5 - start) / unit;
              final uy = (y + 0.5 - start) / unit;
              expect(ux > 0.5 && ux < 23.5 && uy > 0.5 && uy < 23.5, isTrue,
                  reason: '$kind at ${size}px @${dpr}x inks ($ux, $uy)');
            }
          }
          expect(inked, greaterThan(0), reason: '$kind at ${size}px @${dpr}x drew nothing');
        }
      }
    }
  });

  testWidgets('honours the colour and derives the back plate from it', (tester) async {
    const size = 48.0;
    for (final color in [DanaviewColors.cyan, DanaviewColors.purple]) {
      final p = await _render(tester, DanaviewGlyph(DanaviewGlyphKind.folder, size: size, color: color), box: size);
      const unit = size / 24;
      // Front panel and back plate centres (the folder sits 0.4 units high).
      final front = p.color((12 * unit).floor(), (14 * unit).floor());
      final back = p.color((12 * unit).floor(), (6.8 * unit).floor());
      expect(front, isSameColorAs(color, threshold: 0.004));
      expect(back.a, closeTo(DanaviewGlyphPainter.backAlphaFor(color), 0.02));
      expect(back.withValues(alpha: 1), isSameColorAs(color, threshold: 0.02));
    }
  });

  test('darker colours get stronger back plates, so the tab keeps 3:1 on its tile', () {
    double onTile(Color color, double alpha) => DanaviewColors.contrastRatio(
          color.withValues(alpha: alpha),
          Color.alphaBlend(color.withValues(alpha: 0.16), DanaviewColors.surfaceElevated),
        );
    for (final color in const [
      DanaviewColors.cyan,
      DanaviewColors.errorLight,
      DanaviewColors.primaryLight,
      DanaviewColors.warning,
      DanaviewColors.textSecondary,
      DanaviewColors.textPrimary,
    ]) {
      final alpha = DanaviewGlyphPainter.backAlphaFor(color);
      expect(alpha, inInclusiveRange(DanaviewGlyphPainter.backAlpha, DanaviewGlyphPainter.maxBackAlpha));
      expect(onTile(color, alpha), greaterThanOrEqualTo(3), reason: '$color');
    }
    // Purple and the deep red are too dark to reach 3:1 without losing the two tones; they get the
    // strongest plate (and §7 puts glyphs on neutral tiles anyway).
    expect(DanaviewGlyphPainter.backAlphaFor(DanaviewColors.purple), DanaviewGlyphPainter.maxBackAlpha);
    expect(DanaviewGlyphPainter.backAlphaFor(DanaviewColors.primary), DanaviewGlyphPainter.maxBackAlpha);
    expect(DanaviewGlyphPainter.backAlphaFor(DanaviewColors.primary),
        greaterThan(DanaviewGlyphPainter.backAlphaFor(DanaviewColors.cyan)));
    // Destructive is #FF5A62 (= primaryLight) since it was lifted for 4.5:1 on menus: its plate
    // reaches 3:1 like the other light colours.
    expect(DanaviewGlyphPainter.backAlphaFor(DanaviewColors.destructive), DanaviewGlyphPainter.backAlphaFor(DanaviewColors.primaryLight));
    expect(onTile(DanaviewColors.destructive, DanaviewGlyphPainter.backAlphaFor(DanaviewColors.destructive)), greaterThanOrEqualTo(3));
    // Only the colour's hue and lightness count, not its alpha.
    expect(DanaviewGlyphPainter.backAlphaFor(DanaviewColors.purple.withValues(alpha: 0.4)), DanaviewGlyphPainter.maxBackAlpha);
  });

  testWidgets('falls back to the IconTheme size, colour and opacity', (tester) async {
    final p = await _render(
      tester,
      const IconTheme(
        data: IconThemeData(size: 30, color: DanaviewColors.purple, opacity: 0.5),
        child: DanaviewGlyph(DanaviewGlyphKind.device),
      ),
      box: 40,
    );
    expect(tester.getSize(find.byType(DanaviewGlyph)), const Size.square(30));
    final centre = p.color(20, 28);
    expect(centre.a, closeTo(0.5, 0.02));
    expect(centre.withValues(alpha: 1), isSameColorAs(DanaviewColors.purple, threshold: 0.02));
  });

  testWidgets('fits its constraints like Icon and never grows past its size', (tester) async {
    Future<Size> sizeIn(Widget parent) async {
      await tester.pumpWidget(Directionality(textDirection: TextDirection.ltr, child: Center(child: parent)));
      expect(tester.takeException(), isNull);
      return tester.getSize(find.byType(DanaviewGlyph));
    }

    expect(await sizeIn(const DanaviewGlyph(DanaviewGlyphKind.folder)), const Size.square(24));
    expect(
      await sizeIn(const SizedBox(width: 10, height: 30, child: DanaviewGlyph(DanaviewGlyphKind.folder, size: 24))),
      const Size(10, 30),
    );
    expect(
      await sizeIn(const SizedBox.square(dimension: 60, child: DanaviewGlyph(DanaviewGlyphKind.device, size: 24))),
      const Size.square(60),
    );
  });

  testWidgets('a forced larger box still draws the glyph at its own size', (tester) async {
    final p = await _render(
      tester,
      const SizedBox.square(dimension: 48, child: DanaviewGlyph(DanaviewGlyphKind.device, size: 24, color: _white)),
      box: 48,
    );
    // The phone is about 20.5 of 24 units tall: 20-21 px at 24 px, not 41 px at 48. The column
    // runs down its solid side, 7 units into the glyph (which starts 12 px in).
    var rows = 0;
    for (var y = 0; y < p.height; y++) {
      if (p.alpha(12 + 7, y) > 128) rows++;
    }
    expect(rows, inInclusiveRange(18, 22));
  });

  testWidgets('is decorative unless it has a label', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Column(children: [
        Semantics(container: true, child: const DanaviewGlyph(DanaviewGlyphKind.device, semanticLabel: 'On this device')),
        Semantics(container: true, child: const DanaviewGlyph(DanaviewGlyphKind.folder)),
      ]),
    ));
    expect(find.bySemanticsLabel('On this device'), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(DanaviewGlyph).first),
      matchesSemantics(label: 'On this device', isImage: true),
    );
    expect(tester.getSemantics(find.byType(DanaviewGlyph).last), matchesSemantics());
    handle.dispose();
  });

  test('the painter repaints only when its inputs change', () {
    const painter = DanaviewGlyphPainter(kind: DanaviewGlyphKind.folder, color: DanaviewColors.cyan, devicePixelRatio: 2);
    expect(painter.shouldRepaint(painter), isFalse);
    expect(
      painter.shouldRepaint(
        const DanaviewGlyphPainter(kind: DanaviewGlyphKind.folder, color: DanaviewColors.cyan, devicePixelRatio: 2),
      ),
      isFalse,
    );
    for (final other in const [
      DanaviewGlyphPainter(kind: DanaviewGlyphKind.folderOpen, color: DanaviewColors.cyan, devicePixelRatio: 2),
      DanaviewGlyphPainter(kind: DanaviewGlyphKind.folder, color: DanaviewColors.purple, devicePixelRatio: 2),
      DanaviewGlyphPainter(kind: DanaviewGlyphKind.folder, color: DanaviewColors.cyan, devicePixelRatio: 3),
    ]) {
      expect(painter.shouldRepaint(other), isTrue);
    }
  });

  testWidgets('the painter stays inside its canvas', (tester) async {
    final p = await _render(
      tester,
      const CustomPaint(
        size: Size(20, 30),
        painter: DanaviewGlyphPainter(kind: DanaviewGlyphKind.folderOpen, color: _white, devicePixelRatio: 2),
      ),
      box: 30,
      devicePixelRatio: 2,
    );
    for (var y = 0; y < p.height; y++) {
      for (final x in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59]) {
        expect(p.alpha(x, y), 0, reason: 'ink at ($x, $y) outside the 20 px wide canvas');
      }
    }
  });

  testWidgets('snaps straight edges to device pixels, even at a fractional offset', (tester) async {
    // A 40 px tile's 22.4 px glyph starts 8.8 px in: on most screens its edges fall mid-pixel.
    for (final dpr in [1.5, 2.0, 2.625, 3.0]) {
      Future<int> softEdgePixels({required bool pixelSnap}) async {
        final p = await _render(
          tester,
          DanaviewGlyph(DanaviewGlyphKind.folder, size: 22.4, color: _white, pixelSnap: pixelSnap),
          box: 40,
          devicePixelRatio: dpr,
        );
        const unit = 22.4 / 24;
        return _softPixels(p, row: ((8.8 + 14 * unit) * dpr).floor()) +
            _softPixels(p, column: ((8.8 + 12 * unit) * dpr).floor());
      }

      expect(await softEdgePixels(pixelSnap: true), 0, reason: '@${dpr}x');
      expect(await softEdgePixels(pixelSnap: false), greaterThan(0), reason: '@${dpr}x');
    }
  });

  testWidgets('a glyph painted mid-zoom behind a repaint boundary snaps once the zoom ends', (tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(120, 120) * 3;
    addTearDown(tester.view.reset);
    final zoom = AnimationController(vsync: tester, duration: const Duration(milliseconds: 200), lowerBound: 0.9)
      ..value = 0.9;
    addTearDown(zoom.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: key,
        child: Center(
          child: ScaleTransition(
            scale: zoom,
            // Like a route's page or a menu's scroll view: the zoom only moves this cached layer.
            child: const RepaintBoundary(
              child: Padding(
                padding: EdgeInsets.only(left: 0.3, top: 0.3),
                child: DanaviewGlyph(DanaviewGlyphKind.folder, size: 22.4, color: _white),
              ),
            ),
          ),
        ),
      ),
    ));
    zoom.forward();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final rect = tester.getRect(find.byType(DanaviewGlyph));
    final unit = rect.width / 24;
    final p = await _capture(tester, key, 3);
    expect(_softPixels(p, row: ((rect.top + 14 * unit) * 3).floor()), 0);
    expect(_softPixels(p, column: ((rect.left + 12 * unit) * 3).floor()), 0);
  });

  testWidgets('a lasting scale stops the snap checks', (tester) async {
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: Transform.scale(scale: 0.9, child: const DanaviewGlyph(DanaviewGlyphKind.folder, color: _white)),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dialogs and menus draw their glyphs, snapped once open', (tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(360, 640) * 3;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    late BuildContext context;
    var opened = 0;
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: DanaviewTheme.darkTheme,
        home: Scaffold(
          body: Builder(builder: (c) {
            context = c;
            return Center(
              child: DanaviewMenuIconTrigger(
                icon: Icons.more_horiz,
                entries: [DanaviewMenuItem(label: 'Open', glyph: DanaviewGlyphKind.folderOpen, onTap: () => opened++)],
              ),
            );
          }),
        ),
      ),
    ));

    // Repainting the glyph now must not change a pixel: it already shows its snapped picture.
    Future<void> expectSettled(DanaviewGlyphKind kind, double size) async {
      final glyph = find.byWidgetPredicate((w) => w is DanaviewGlyph && w.kind == kind);
      expect(glyph, findsOneWidget);
      expect(tester.getSize(glyph), Size.square(size));
      final settled = await _capture(tester, key, 3);
      tester.renderObject(glyph).markNeedsPaint();
      await tester.pump();
      final repainted = await _capture(tester, key, 3);
      expect(listEquals(settled.data.buffer.asUint8List(), repainted.data.buffer.asUint8List()), isTrue,
          reason: '$kind still showed the picture painted mid-zoom');
    }

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await expectSettled(DanaviewGlyphKind.folderOpen, 18);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(opened, 1);

    final confirmed = showDanaviewConfirm(
      context,
      title: "Can't open folder",
      glyph: DanaviewGlyphKind.folderOff,
      destructive: true,
    );
    await tester.pumpAndSettle();
    await expectSettled(DanaviewGlyphKind.folderOff, 22);
    final dialogGlyph = tester.widget<DanaviewGlyph>(find.byType(DanaviewGlyph));
    expect(dialogGlyph.color, DanaviewColors.destructive);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await confirmed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('takes taps like Icon', (tester) async {
    var taps = 0;
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: GestureDetector(onTap: () => taps++, child: const DanaviewGlyph(DanaviewGlyphKind.folder)),
      ),
    ));
    await tester.tap(find.byType(DanaviewGlyph));
    expect(taps, 1);
  });

  testWidgets('never fails at tiny sizes, on any pixel grid', (tester) async {
    final sizes = [for (var s = 0.25; s <= 16; s += 0.25) s];
    for (final dpr in [1.0, 1.5, 2.0, 2.625, 3.0]) {
      for (final shift in [0.0, 0.37]) {
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = const Size(800, 900) * dpr;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: Padding(
            padding: EdgeInsets.only(left: shift, top: shift),
            child: Wrap(children: [
              for (final size in sizes)
                for (final kind in DanaviewGlyphKind.values) DanaviewGlyph(kind, size: size, color: _white),
              // Squeezed by tight constraints, like a collapsing container.
              for (final height in [0.25, 0.5, 1.0, 2.0])
                for (final kind in DanaviewGlyphKind.values)
                  SizedBox(height: height, child: DanaviewTileIcon.glyph(kind, size: 40)),
            ]),
          ),
        ));
        expect(tester.takeException(), isNull, reason: '@${dpr}x, shifted by $shift');
      }
    }

    // The painter snaps from its canvas origin, or not at all at ratio 0.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (final dpr in [0.0, 1.0, 1.5, 2.0, 2.625, 3.0]) {
      for (final size in sizes) {
        for (final kind in DanaviewGlyphKind.values) {
          for (final canvasSize in [Size.square(size), Size(size, size * 0.4)]) {
            DanaviewGlyphPainter(kind: kind, color: _white, devicePixelRatio: dpr).paint(canvas, canvasSize);
          }
        }
      }
    }
    recorder.endRecording().dispose();
  });

  testWidgets('the phone and the folders stay equally heavy and centred', (tester) async {
    const folders = [
      DanaviewGlyphKind.folder,
      DanaviewGlyphKind.folderOpen,
      DanaviewGlyphKind.folderAdd,
      DanaviewGlyphKind.folderOff,
      DanaviewGlyphKind.folderVideo,
    ];
    // (glyph size, ratio, box): plain sizes, and the glyph of a 40 px DanaviewTileIcon on a 3x phone.
    for (final (size, dpr, box) in [(96.0, 1.0, 96.0), (24.0, 2.0, 24.0), (22.4, 3.0, 40.0), (16.0, 1.0, 16.0)]) {
      Future<({double area, Offset centroid, double outlineMiddle})> measure(DanaviewGlyphKind kind) async {
        final p = await _render(tester, DanaviewGlyph(kind, size: size, color: _white), box: box, devicePixelRatio: dpr);
        return _ink(p, size: size, box: box, dpr: dpr);
      }

      final at = '${size}px @${dpr}x';
      final device = await measure(DanaviewGlyphKind.device);
      final folder = await measure(DanaviewGlyphKind.folder);
      expect(device.area / folder.area, inInclusiveRange(0.92, 1.12), reason: 'phone/folder ink at $at');
      expect(device.centroid.dx, closeTo(12, 0.25), reason: 'phone centre x at $at');
      expect(device.centroid.dy, closeTo(12.1, 0.25), reason: 'phone centre y at $at');
      for (final kind in folders) {
        final m = kind == DanaviewGlyphKind.folder ? folder : await measure(kind);
        expect(m.area / folder.area, inInclusiveRange(0.8, 1.0), reason: '$kind ink at $at');
        expect(m.centroid.dx, closeTo(11.8, 0.5), reason: '$kind centre x at $at');
        // Halfway between centring the outline, which lines up with icons beside it, and centring
        // the weight, which the solid front pulls down.
        expect(m.outlineMiddle, inInclusiveRange(11.25, 12.1), reason: '$kind outline middle at $at');
        expect(m.centroid.dy - device.centroid.dy, inInclusiveRange(0.4, 1.2), reason: '$kind centre y at $at');
      }
    }
  });

  testWidgets('a 16 px phone on a 1x screen keeps a readable play mark', (tester) async {
    const size = 16.0;
    final p = await _render(tester, const DanaviewGlyph(DanaviewGlyphKind.device, size: size, color: _white), box: size);
    var top = p.height;
    var bottom = -1;
    var left = p.width;
    var right = -1;
    for (var y = 0; y < p.height; y++) {
      for (var x = 0; x < p.width; x++) {
        if (p.alpha(x, y) < 128) continue;
        top = y < top ? y : top;
        bottom = y > bottom ? y : bottom;
        left = x < left ? x : left;
        right = x > right ? x : right;
      }
    }
    // Holes inside the phone: a clear play mark at least 4 px tall and 3 wide, and no island,
    // which would only be a faint dash at this size.
    final holeRows = <int>{};
    final holeColumns = <int>{};
    for (var y = top + 1; y < bottom; y++) {
      for (var x = left + 1; x < right; x++) {
        if (p.alpha(x, y) < 64) {
          holeRows.add(y);
          holeColumns.add(x);
        }
      }
    }
    expect(holeRows.length, greaterThanOrEqualTo(4));
    expect(holeColumns.length, greaterThanOrEqualTo(3));
    expect(holeRows.reduce((a, b) => a < b ? a : b) - top, greaterThanOrEqualTo(3), reason: 'no island');
    final soft = [
      for (final y in [top + 1, top + 2])
        for (var x = left + 1; x < right; x++)
          if (p.alpha(x, y) < 192) Offset(x.toDouble(), y.toDouble()),
    ];
    expect(soft, isEmpty, reason: 'no faint island dash under the top edge');
  });

  testWidgets('DanaviewTileIcon.glyph keeps the tile metrics', (tester) async {
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: DanaviewTileIcon.glyph(DanaviewGlyphKind.device, color: DanaviewColors.cyan, size: 40)),
    ));
    expect(tester.getSize(find.byType(DanaviewTileIcon)), const Size.square(40));
    final glyph = tester.getSize(find.byType(DanaviewGlyph));
    expect(glyph.width, closeTo(40 * 0.56, 1e-9));
    expect(glyph.height, closeTo(40 * 0.56, 1e-9));
    expect(tester.getCenter(find.byType(DanaviewGlyph)), tester.getCenter(find.byType(DanaviewTileIcon)));
    final decoration = tester.widget<Container>(find.byType(Container)).decoration! as BoxDecoration;
    expect(decoration.color, DanaviewColors.cyan.withValues(alpha: 0.16));
  });

  for (final textScale in [1.0, 1.5, 2.0]) {
    testWidgets('glyph buttons, breadcrumbs and empty states fit at ${textScale}x text', (tester) async {
      final surface = Surface('narrow touch ${textScale}x', const Size(320, 640), textScale, TargetPlatform.iOS);
      await pumpKit(
        tester,
        surface,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Breadcrumb root: a 16 px glyph inline with its label, in a scrolling trail like the app's.
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: DanaviewButton.ghost(
                    key: const Key('crumb-glyph'),
                    label: 'On This Device',
                    glyph: DanaviewGlyphKind.device,
                    size: DanaviewButtonSize.sm,
                    onPressed: () {},
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, size: 16),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: DanaviewButton.ghost(
                    key: const Key('crumb-icon'),
                    label: 'On This Device',
                    icon: Icons.smartphone_rounded,
                    size: DanaviewButtonSize.sm,
                    onPressed: () {},
                  ),
                ),
              ]),
            ),
            DanaviewButton.tonal(label: 'Add folder', glyph: DanaviewGlyphKind.folderAdd, onPressed: () {}),
            DanaviewButton.primary(label: 'Add folder', icon: Icons.create_new_folder_rounded, onPressed: () {}),
            const Expanded(child: DanaviewEmptyState(glyph: DanaviewGlyphKind.folderOff, title: longText, message: longText)),
          ],
        ),
      );
      await tester.pump();
      expectNoErrors(tester);

      // The glyph sits exactly where an Icon would, centred on its label.
      for (final (glyphButton, iconButton) in [
        (find.byKey(const Key('crumb-glyph')), find.byKey(const Key('crumb-icon'))),
        (find.byType(DanaviewButton).at(2), find.byType(DanaviewButton).at(3)),
      ]) {
        final glyph = tester.getRect(find.descendant(of: glyphButton, matching: find.byType(DanaviewGlyph)));
        final icon = tester.getRect(find.descendant(of: iconButton, matching: find.byType(Icon)));
        final label = tester.getRect(find.descendant(of: glyphButton, matching: find.byType(Text)));
        expect(glyph.size, icon.size);
        expect(glyph.center.dy - tester.getRect(glyphButton).top,
            closeTo(icon.center.dy - tester.getRect(iconButton).top, 0.01));
        expect(glyph.center.dy, closeTo(label.center.dy, 0.5));
        expectInside(tester, glyphButton, surface.size);
      }
      expect(tester.getSize(find.descendant(of: find.byType(DanaviewEmptyState), matching: find.byType(DanaviewGlyph))),
          const Size.square(24));
    });
  }
}
