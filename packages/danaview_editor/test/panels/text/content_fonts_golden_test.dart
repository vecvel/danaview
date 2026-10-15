// OWNER: UX-30
//
// The content fonts load (ARCH §17.8, D-30): every bundled family's files and OFL text are in the
// asset bundle of package:danaview_editor_fonts, load into the engine under their
// package-qualified family (the name FontCatalog resolves), render as real glyphs (not the test
// font's boxes), and appear in the licence registry. The golden shows each bundled family in
// regular, bold and italic as the preview overlay and export sprites will draw it.
//
// FIX-FONTS-BUNDLE (2026-10-15): all ten §17.8 families are bundled (Figtree from the UI kit, the
// other nine fetched from google/fonts by tool/fetch_fonts.dart, provenance in
// danaview_editor_fonts/fonts/SOURCES.json). Bold is checked by ink, not width (JetBrains Mono is
// monospaced): a family with a bold face draws clearly heavier at w700, and for the variable
// files w700 draws exactly as `FontVariation('wght', 700)` (Flutter maps fontWeight onto the wght
// axis). The bundle size is guarded against ARCH §17.8.
//
// Regenerate (after reviewing the change, e.g. after tool/fetch_fonts.dart added families) with:
//   flutter test --update-goldens test/panels/text/content_fonts_golden_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/text/font_catalog.dart';
import 'package:danaview_editor_fonts/danaview_editor_fonts.dart'
    show bundledContentFontFamilies, contentFontFamilies, contentFontsPackage, registerContentFontLicenses;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';

class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile, {required this.tolerance});

  final double tolerance;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(imageBytes, await getGoldenBytes(golden));
    if (result.passed || result.diffPercent <= tolerance) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}

/// The font files of the bundle, read from the FontManifest of the test asset bundle.
Future<Map<String, List<String>>> bundledFontFiles() async {
  final manifest = await rootBundle.loadStructuredData<List<Object?>>(
    'FontManifest.json',
    (s) async => json.decode(s) as List<Object?>,
  );
  final out = <String, List<String>>{};
  for (final entry in manifest.cast<Map<String, Object?>>()) {
    final family = entry['family']! as String;
    if (!family.startsWith('packages/$contentFontsPackage/')) continue;
    out[family] = [for (final f in (entry['fonts']! as List<Object?>).cast<Map<String, Object?>>()) f['asset']! as String];
  }
  return out;
}

/// Loads every bundled content family into the engine.
Future<void> loadContentFonts() async {
  final files = await bundledFontFiles();
  for (final MapEntry(key: family, value: assets) in files.entries) {
    final loader = FontLoader(family);
    for (final a in assets) {
      loader.addFont(rootBundle.load(a));
    }
    await loader.load();
  }
}

double widthOf(String text, String family, {FontWeight weight = FontWeight.w400}) {
  final p = TextPainter(
    text: TextSpan(text: text, style: TextStyle(fontFamily: family, fontSize: 40, fontWeight: weight)),
    textDirection: TextDirection.ltr,
  )..layout();
  final w = p.width;
  p.dispose();
  return w;
}

/// Total alpha ("ink") of [text] drawn in white at 40 px; a heavier face draws more ink.
Future<int> inkOf(String text, String family, {FontWeight weight = FontWeight.w400, List<ui.FontVariation>? variations}) async {
  final p = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: family,
        fontSize: 40,
        fontWeight: weight,
        fontVariations: variations,
        color: const Color(0xFFFFFFFF),
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final recorder = ui.PictureRecorder();
  p.paint(Canvas(recorder), Offset.zero);
  final picture = recorder.endRecording();
  final image = await picture.toImage(p.width.ceil(), p.height.ceil());
  final bytes = (await image.toByteData())!;
  picture.dispose();
  image.dispose();
  p.dispose();
  var sum = 0;
  for (var i = 3; i < bytes.lengthInBytes; i += 4) {
    sum += bytes.getUint8(i);
  }
  return sum;
}

/// The package directory of danaview_editor_fonts (tests run with the package as cwd).
Directory get _fontsDir => Directory('${Directory.current.path}/../danaview_editor_fonts/fonts');

void main() {
  setUp(() {
    final base = goldenFileComparator as LocalFileComparator;
    goldenFileComparator = _TolerantComparator(base.basedir.resolve('content_fonts_golden_test.dart'), tolerance: 0.002);
  });

  test('all ten ARCH §17.8 families are bundled', () {
    expect(contentFontFamilies, hasLength(10));
    expect([for (final f in bundledContentFontFamilies) f.id], [for (final f in contentFontFamilies) f.id]);
  });

  test('the bundle has its provenance record and fits the size guard (ARCH §17.8)', () {
    final record = json.decode(File('${_fontsDir.path}/SOURCES.json').readAsStringSync()) as Map<String, Object?>;
    final files = (record['files']! as List<Object?>).cast<Map<String, Object?>>();
    final onDisk = [
      for (final e in _fontsDir.listSync(recursive: true).whereType<File>())
        if (!e.path.endsWith('SOURCES.json')) e,
    ];
    expect(files.map((f) => f['path']).toSet(), {for (final e in onDisk) e.path.substring(_fontsDir.path.length + 1)},
        reason: 'every file in fonts/ is recorded');
    for (final f in files) {
      expect(f['sha256'], matches(RegExp(r'^[0-9a-f]{64}$')), reason: '${f['path']}');
      expect(File('${_fontsDir.path}/${f['path']}').lengthSync(), f['bytes'], reason: '${f['path']} unchanged since recorded');
      if (!(f['path']! as String).startsWith('figtree/')) {
        expect(f['source'], startsWith('https://raw.githubusercontent.com/google/fonts/'), reason: '${f['path']}');
        expect(f['commit'], matches(RegExp(r'^[0-9a-f]{40}$')), reason: '${f['path']}');
      }
    }
    final total = onDisk.fold<int>(0, (a, e) => a + e.lengthSync());
    expect(total, record['totalBytes']);
    // ARCH §17.8 estimates ≈ 3–4 MB; google/fonts ships these families as variable fonts, which
    // brings the bundle to ≈ 5.8 MB (reported to the owner). The guard stops further growth.
    expect(total, lessThanOrEqualTo(6 * 1024 * 1024));
  });

  test('every bundled family is in the font manifest with its OFL text', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final files = await bundledFontFiles();
    for (final f in bundledContentFontFamilies) {
      expect(files.keys, contains(f.packagedFamily), reason: '${f.family} is declared by danaview_editor_fonts');
      expect(f.packagedFamily, FontCatalog.instance.resolve(f.id));
      for (final asset in files[f.packagedFamily]!) {
        expect((await rootBundle.load(asset)).lengthInBytes, greaterThan(10000), reason: asset);
      }
      final ofl = await rootBundle.loadString(f.licenseAsset);
      expect(ofl, contains('SIL Open Font License'));
    }
  });

  test('the OFL texts reach the licence registry', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerContentFontLicenses();
    registerContentFontLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    for (final f in bundledContentFontFamilies) {
      final mine = entries.where((e) => e.packages.contains('${f.family} (video editor content font)')).toList();
      expect(mine, hasLength(1), reason: 'registered once');
      expect(mine.single.paragraphs.map((p) => p.text).join('\n'), contains('SIL Open Font License'));
    }
  });

  testWidgets('content fonts load and render real glyphs (golden)', (tester) async {
    await tester.runAsync(loadContentFonts);
    for (final f in bundledContentFontFamilies) {
      // The test font draws every glyph as a 1 em box: 5 em for "Hello". Real glyphs are narrower.
      final regular = widthOf('Hello', f.packagedFamily);
      expect(regular, lessThan(5 * 40 * 0.8), reason: '${f.family} rendered with real glyphs');
    }
    await tester.runAsync(() async {
      final files = await bundledFontFiles();
      for (final f in bundledContentFontFamilies) {
        final regular = await inkOf('Hello Bold', f.packagedFamily);
        final bold = await inkOf('Hello Bold', f.packagedFamily, weight: FontWeight.w700);
        if (f.hasBold) {
          expect(bold / regular, greaterThan(1.2), reason: '${f.family} bold renders bold');
        }
        if (files[f.packagedFamily]!.any((a) => a.contains('-VF.'))) {
          final axis = await inkOf('Hello Bold', f.packagedFamily, variations: const [ui.FontVariation('wght', 700)]);
          expect(bold, axis, reason: '${f.family}: w700 sets the variable wght axis to 700');
        }
      }
    });

    const surface = EditorSurface(Size(480, 120));
    applySurface(tester, surface);
    final families = bundledContentFontFamilies;
    tester.view.physicalSize = Size(480, 24.0 + 64 * families.length);
    await tester.pumpWidget(surfaceApp(
      surface,
      RepaintBoundary(
        key: const ValueKey<String>('golden'),
        child: ColoredBox(
          color: DanaviewColors.surfaceElevated,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final f in families)
                  SizedBox(
                    height: 64,
                    child: Row(children: [
                      for (final (w, i) in [(FontWeight.w400, false), (FontWeight.w700, false), (FontWeight.w400, true)])
                        Expanded(
                          child: Text(
                            f.family,
                            maxLines: 1,
                            style: TextStyle(
                              fontFamily: f.packagedFamily,
                              fontSize: 28,
                              fontWeight: w,
                              fontStyle: i ? FontStyle.italic : FontStyle.normal,
                              color: const Color(0xFFFFFFFF),
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                    ]),
                  ),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await expectLater(find.byKey(const ValueKey<String>('golden')), matchesGoldenFile('goldens/content_fonts.png'));
  });
}
