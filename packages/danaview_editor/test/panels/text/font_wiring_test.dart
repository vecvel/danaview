// OWNER: FIX-FONTS
//
// A chosen content font reaches the preview and the export (FIX-FONTS, from UX-30; ARCH §17.8,
// D-30, D-05): UX-19's `previewTextEngineProvider` and UX-39's export sprite engine resolve
// `TextStyleSpec.fontFamily` ids through UX-30's `FontCatalog` (`fontCatalogProvider`), so
//
// * the preview overlay draws a text item in the chosen family (pixels equal a layout made
//   directly in that family, and differ from Figtree);
// * the export sprite of the same item (API-04 `TextSpriteRasterizer` of the export environment)
//   uses the same family and matches the overlay within 1 px;
// * `exportEnvironmentProvider` (wired from INT-02's runtime) uses the catalog the app provides;
// * unknown and unbundled ids stay Figtree in both.
//
// flutter_tester has no content fonts, so the test registers stand-ins under the package-qualified
// family names the catalog resolves: content Figtree = Figtree Regular and Bold, and a "Playfair
// Display" stand-in = Figtree Bold only (any weight draws the bold glyphs, which are wider).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_availability.dart';
import 'package:danaview_editor/src/app/editor_bootstrap.dart';
import 'package:danaview_editor/src/app/editor_prefs.dart';
import 'package:danaview_editor/src/editor/flows/export/export_environment.dart';
import 'package:danaview_editor/src/editor/preview/text_overlay_layer.dart';
import 'package:danaview_editor/src/editor/text/font_catalog.dart';
import 'package:danaview_editor_core/eval.dart' show textLayoutSpecOf;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_core/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_api/testing.dart';

import '../../flows/export/export_rig.dart' show rigCaps, rigRoots;
import '../../preview/text_overlay/text_overlay_support.dart';

const String _figtree = 'packages/danaview_editor_fonts/Figtree';
const String _playfair = 'packages/danaview_editor_fonts/Playfair Display';

/// The catalog of these tests: Figtree and Playfair Display "bundled".
final FontCatalog _catalog = FontCatalog(bundled: {'figtree', 'playfair'});

bool _loaded = false;

Future<void> _loadStandIns() async {
  if (_loaded) return;
  Uint8List bytes(String f) {
    final file = File('../danaview_ui_kit/fonts/$f');
    expect(file.existsSync(), isTrue, reason: 'Figtree is bundled in danaview_ui_kit');
    return file.readAsBytesSync();
  }

  await ui.loadFontFromList(bytes('Figtree-Regular.ttf'), fontFamily: _figtree);
  await ui.loadFontFromList(bytes('Figtree-Bold.ttf'), fontFamily: _figtree);
  await ui.loadFontFromList(bytes('Figtree-Bold.ttf'), fontFamily: _playfair);
  _loaded = true;
}

(EditProject, ItemId) _project(String fontId) =>
    textProject('Hamburgefonstiv', style: TextStyleSpec(fontFamily: fontId, fontSizePt: 72, color: 0xFFFFFFFF));

ProviderContainer _container([List<Override> overrides = const []]) {
  final c = ProviderContainer(overrides: overrides);
  addTearDown(c.dispose);
  return c;
}

/// Width of the overlay's ink of [project]'s text at 1 s with [engine].
Future<(Uint8List, ui.Rect)> _overlay(TextLayoutEngine engine, EditProject project) async {
  final c = project.settings.canvas;
  final image = await overlayImage(TextOverlayScene(engine), project, 1 * us);
  final rgba = await rgbaOf(image);
  image.dispose();
  return (rgba, inkBounds(rgba, c.widthPx, c.heightPx)!);
}

class _IdleTimer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => false;

  @override
  int get tick => 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('preview (previewTextEngineProvider)', () {
    test('defaults to the app catalog: bundled ids resolve to their family, others to Figtree', () {
      final engine = _container().read(previewTextEngineProvider);
      for (final f in contentFontFamilies) {
        expect(engine.fontResolver(f.id), FontCatalog.instance.resolve(f.id), reason: f.id);
      }
      expect(engine.fontResolver('figtree'), _figtree);
      expect(engine.fontResolver('noSuchFont'), _figtree);
      expect(engine.fontResolver(''), _figtree);
    });

    test('follows fontCatalogProvider (tests and INT-02 may supply another catalog)', () {
      final engine = _container([fontCatalogProvider.overrideWithValue(_catalog)]).read(previewTextEngineProvider);
      expect(engine.fontResolver('playfair'), _playfair);
      expect(engine.fontResolver('lora'), _figtree, reason: 'not bundled in this catalog');
    });

    test('the overlay draws a text item in its chosen font', () async {
      await _loadStandIns();
      final engine = _container([fontCatalogProvider.overrideWithValue(_catalog)]).read(previewTextEngineProvider);
      final (playfairProject, _) = _project('playfair');
      final (figtreeProject, _) = _project('figtree');
      final (unknownProject, _) = _project('noSuchFont');

      final (chosen, chosenInk) = await _overlay(engine, playfairProject);
      final (_, figtreeInk) = await _overlay(engine, figtreeProject);
      final (_, unknownInk) = await _overlay(engine, unknownProject);
      // The same item laid out directly in the stand-in family.
      final (direct, directInk) = await _overlay(TextLayoutEngine(fontResolver: (_) => _playfair), playfairProject);

      final c = playfairProject.settings.canvas;
      expect(chosenInk, directInk, reason: 'the overlay used the chosen family');
      expect(mismatchesBeyond1px(chosen, direct, c.widthPx, c.heightPx), 0);
      expect(chosenInk.width, greaterThan(figtreeInk.width + 10), reason: 'not Figtree');
      expect(unknownInk, figtreeInk, reason: 'unknown id -> Figtree');
      // Real glyphs, not the test font's 1 em boxes (15 glyphs x 72 pt).
      expect(figtreeInk.width, lessThan(15 * 72 * 0.8));
    });
  });

  group('export (ExportEnvironment)', () {
    TextSpriteRasterizer rasterizerOf(ExportEnvironment env) => (env.spriteRunner(rigCaps) as PrepassSpriteRunner).prepass.rasterizer;

    test('the default local environment resolves ids with the app catalog', () {
      final engine = rasterizerOf(ExportEnvironment.local(rigRoots, fs: MemoryStoreFs())).engine;
      for (final f in contentFontFamilies) {
        expect(engine.fontResolver(f.id), FontCatalog.instance.resolve(f.id), reason: f.id);
      }
      expect(engine.fontResolver('noSuchFont'), _figtree);
    });

    test('the export sprite uses the chosen font and matches the preview overlay within 1 px', () async {
      await _loadStandIns();
      final env = ExportEnvironment.local(rigRoots, fs: MemoryStoreFs(), fontResolver: _catalog.resolve);
      final rasterizer = rasterizerOf(env);
      final preview = _container([fontCatalogProvider.overrideWithValue(_catalog)]).read(previewTextEngineProvider);

      final (project, item) = _project('playfair');
      final (figProject, figItem) = _project('figtree');
      final c = project.settings.canvas;

      final exported = await exportLikeRgba(rasterizer, project, item, 1 * us);
      final exportedFigtree = await exportLikeRgba(rasterizer, figProject, figItem, 1 * us);
      final (overlay, _) = await _overlay(preview, project);

      expect(mismatchesBeyond1px(exported, overlay, c.widthPx, c.heightPx), 0, reason: 'export == preview');
      final ink = inkBounds(exported, c.widthPx, c.heightPx)!;
      final figInk = inkBounds(exportedFigtree, c.widthPx, c.heightPx)!;
      expect(ink.width, greaterThan(figInk.width + 10), reason: 'the sprite is not Figtree');

      // Metrics used for sprite sizing (exportSpriteRequests) come from the same engine.
      final spec = textLayoutSpecOf(project.index.locate(item)!.item as TextItem, c);
      expect(env.spriteRunner(rigCaps).metrics!.measure(spec), preview.measure(spec));
    });

    test('exportEnvironmentProvider (INT-02 runtime) uses fontCatalogProvider', () async {
      final overrides = await EditorBootstrap.create(
        engine: FakeEditorEngine(),
        roots: const StoreRoots(support: '/fake/support', cache: '/fake/cache', documents: '/fake/documents'),
        prefs: EditorPrefs.memory(),
        platform: const EditorSupported(),
        fs: MemoryStoreFs(),
        timer: (_, __) => _IdleTimer(),
        listenToLifecycle: false,
      );
      final c = ProviderContainer(overrides: [...overrides, fontCatalogProvider.overrideWithValue(_catalog)]);
      addTearDown(() async {
        await c.read(editorRuntimeProvider)?.dispose();
        c.dispose();
      });
      final engine = rasterizerOf(c.read(exportEnvironmentProvider)).engine;
      expect(engine.fontResolver('playfair'), _playfair);
      expect(engine.fontResolver('lora'), _figtree);
      expect(engine.fontResolver('noSuchFont'), _figtree);
    });
  });
}
