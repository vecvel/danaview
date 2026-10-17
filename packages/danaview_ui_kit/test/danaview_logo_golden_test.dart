// DanaviewLogo goldens: the 6B mark (page-fold Dv) at 48 and 180 px, with and without its tile,
// the product accents on the flap, and a preview of the in-app uses (home header, About identity,
// Settings row) set in Figtree. The geometry is a port of assets/branding/generate_brand.py.
//
// Regenerate (after reviewing the change) with:
//   flutter test --update-goldens test/danaview_logo_golden_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

/// Tolerates a small share of differing pixels (anti-aliasing differs between test hosts).
class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile);

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(imageBytes, await getGoldenBytes(golden));
    if (result.passed || result.diffPercent <= 0.005) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}

Future<void> _loadFigtree() async {
  final loader = FontLoader(DanaviewFonts.family);
  for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    final bytes = File('fonts/Figtree-$w.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

Future<void> _pump(WidgetTester tester, Size size, Widget child) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: DanaviewTheme.darkTheme,
      home: Material(
        color: DanaviewColors.background,
        child: Center(
            child: RepaintBoundary(
          key: const ValueKey('shot'),
          child: ColoredBox(color: DanaviewColors.background, child: child),
        )),
      ),
    ),
  );
}

Widget _glyphOnly(double size) => SizedBox.square(
      dimension: size,
      child: const CustomPaint(painter: DanaviewLogoPainter(tile: false)),
    );

void main() {
  setUpAll(() async {
    goldenFileComparator = _TolerantComparator(Uri.parse('test/danaview_logo_golden_test.dart'));
    await _loadFigtree();
  });

  for (final size in [48.0, 180.0]) {
    final n = size.toInt();
    testWidgets('logo $n with tile', (tester) async {
      await _pump(
          tester,
          Size(size + 32, size + 32),
          ColoredBox(
              color: DanaviewColors.background,
              child: Padding(padding: const EdgeInsets.all(8), child: DanaviewLogo(size: size))));
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('goldens/logo_${n}_tile.png'));
    });
    testWidgets('logo $n glyph only', (tester) async {
      await _pump(
          tester,
          Size(size + 32, size + 32),
          ColoredBox(
              color: DanaviewColors.background,
              child: Padding(padding: const EdgeInsets.all(8), child: _glyphOnly(size))));
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('goldens/logo_${n}_glyph.png'));
    });
  }

  testWidgets('product accents paint the flap only', (tester) async {
    const accents = [
      null,
      DanaviewLogoPainter.editorAccent,
      DanaviewLogoPainter.cameraAccent,
      DanaviewLogoPainter.photosAccent,
      DanaviewLogoPainter.docsAccent,
    ];
    await _pump(
      tester,
      const Size(560, 260),
      ColoredBox(
        color: DanaviewColors.background,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                for (final a in accents)
                  Padding(padding: const EdgeInsets.all(4), child: DanaviewLogo(size: 96, accent: a)),
              ]),
              Row(mainAxisSize: MainAxisSize.min, children: [
                for (final a in accents)
                  Padding(padding: const EdgeInsets.all(4), child: DanaviewLogo(size: 48, accent: a)),
              ]),
            ],
          ),
        ),
      ),
    );
    await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('goldens/logo_accents.png'));
  });

  testWidgets('glyph paths keep the 6B construction', (tester) async {
    const rect = Rect.fromLTWH(0, 0, 1024, 1024);
    final page = DanaviewLogoPainter.glyphPagePath(rect);
    final flap = DanaviewLogoPainter.glyphFlapPath(rect);
    final mark = DanaviewLogoPainter.glyphPath(rect);
    // Page box 288 to 736 on the 1024 grid.
    expect(page.getBounds().left, closeTo(288, 0.01));
    expect(page.getBounds().right, closeTo(736, 0.01));
    expect(page.getBounds().bottom, closeTo(736, 0.01));
    expect(mark.getBounds().top, closeTo(288, 0.01));
    // Spine, bowl and the knockout gap: inside the page, on the flap, and in the 40 gap between.
    expect(page.contains(const Offset(320, 512)), isTrue);
    expect(page.contains(const Offset(700, 700)), isFalse, reason: 'outside the bowl');
    expect(flap.contains(const Offset(610, 420)), isTrue);
    expect(page.contains(const Offset(610, 420)), isFalse, reason: 'flap area is knocked out of the page');
    // A point 22 off the flap's AC edge, halfway along it, lies in the gap: on neither shape.
    expect(page.contains(const Offset(532.9, 398.9)), isFalse);
    expect(flap.contains(const Offset(532.9, 398.9)), isFalse);
    // The folded corner itself is gone.
    expect(mark.contains(const Offset(730, 294)), isFalse);
  });

  testWidgets('in-app uses: home header, About identity, Settings row', (tester) async {
    await _pump(
      tester,
      const Size(420, 360),
      SizedBox(
        width: 390,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Mirrors _HomeHeader in danaview_features (logo 36, title 26).
              Row(children: [
                const DanaviewLogo(size: 36),
                const SizedBox(width: DanaviewSpacing.md),
                Expanded(
                  child: Text('Danaview',
                      maxLines: 1, style: DanaviewTextStyles.largeTitle.copyWith(fontSize: 26, height: 1.15)),
                ),
              ]),
              const SizedBox(height: 24),
              // Mirrors the About screen identity (logo 76, title 24).
              const DanaviewLogo(size: 76, semanticLabel: 'Danaview logo'),
              const SizedBox(height: DanaviewSpacing.lg),
              Text('Danaview', style: DanaviewTextStyles.largeTitle.copyWith(fontSize: 24)),
              const SizedBox(height: 24),
              // Mirrors the Settings "About Danaview" row (logo 40).
              Row(children: [
                const DanaviewLogo(size: 40, semanticLabel: null),
                const SizedBox(width: DanaviewSpacing.md),
                Text('About Danaview', style: DanaviewTextStyles.body.copyWith(fontWeight: FontWeight.w600)),
              ]),
            ],
          ),
        ),
      ),
    );
    await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('goldens/logo_in_app.png'));
  });
}
