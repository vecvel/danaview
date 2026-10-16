// OWNER: QA-04
//
// V-D7 (ARCH §24.2, §14.1 step 4): the export sprite pre-pass for a project with 3,000 burned-in
// cues, first export (empty sprite cache), ≤ 15 s on the mid tier; the UI slices stay near the
// 4 ms budget of API-04 (recorded). A second run must reuse every sprite from the cache.
//
// The requests are core's `exportSpriteRequests` (CORE-31/33) for a 1080p export, rasterized by
// API-04's `SpritePrepass` with UX-30's content fonts — the same wiring as the export flow
// (`ExportEnvironment.local`).
//
//   cd packages/danaview_editor
//   flutter test integration_test/perf/sprite_prepass_perf_test.dart -d flutter-tester

import 'dart:io';

import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor/src/editor/text/font_catalog.dart' show FontCatalog;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'perf_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sprite pre-pass: 3,000 cues, first export and cached re-run', (tester) async {
    final project = perfProject(items: 20, cues: 3000);
    final requests = exportSpriteRequests(project, ExportSettings());
    expect(requests.length, greaterThanOrEqualTo(3000), reason: 'one sprite per burned cue (plus texts)');
    final dir = Directory.systemTemp.createTempSync('danaview_qa04_sprites');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    SpritePrepass prepass() => SpritePrepass(
          rasterizer: TextSpriteRasterizer(engine: TextLayoutEngine(fontResolver: FontCatalog.instance.resolve)),
        );

    final first = prepass();
    late SpriteManifest manifest;
    await tester.runAsync(() async {
      manifest = await first.run(requests, cacheDir: dir.path);
    });
    final st = first.stats;
    expect(st.rasterized, st.unique);
    expect(manifest, isNotNull);
    final slices = st.sliceMicros.map((us) => us / 1000).toList();
    UiBudgets.spritePrepass.check(st.elapsed.inMicroseconds / 1000, {
      'requests': st.requested,
      'unique': st.unique,
      'rasterized': st.rasterized,
      'sliceP90Ms': percentile(slices, 90).toStringAsFixed(2),
      'sliceMaxMs': (st.maxSliceMicros / 1000).toStringAsFixed(2),
      'slices': slices.length,
    });

    final second = prepass();
    await tester.runAsync(() async {
      await second.run(requests, cacheDir: dir.path);
    });
    expect(second.stats.reused, second.stats.unique, reason: 'the second export reuses every cached sprite');
    qa04('ui.spritePrepass3000.cached', {
      'value': (second.stats.elapsed.inMicroseconds / 1000).toStringAsFixed(1),
      'unit': 'ms',
      'reused': second.stats.reused,
      'run': runKind,
    });
  }, timeout: const Timeout(Duration(minutes: 10)));
}
