// OWNER: UX-39
//
// The default export environment end to end without fakes for the pre-pass: API-04's real
// SpritePrepass writes `.vsprite` files for the project's text and burned captions into the
// environment's sprites folder (an in-memory file system), the same request list goes to
// `compileExport`, and the plan carries the sprite assets. Also the capability mapping.

import 'package:flutter/painting.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/flows/export/export_environment.dart';
import 'package:vwish_editor_core/plan.dart';
import 'package:vwish_editor_core/store.dart';
import 'package:vwish_editor_core/testing.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

import '../../state/state_support.dart' show resolverFor;
import '../../support/support.dart';
import 'export_rig.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the default environment rasterizes text and captions with SpritePrepass and the plan references the files', () async {
    final repo = FakeProjectRepository();
    final project = exportProject(repo);
    final mem = MemoryStoreFs();
    for (final d in [rigRoots.support, rigRoots.cache, rigRoots.documents, rigRoots.workDir]) {
      mem.mkdirs(d);
    }
    final env = ExportEnvironment.local(rigRoots, fs: mem);
    final caps = exportCapabilitiesOf(rigCaps);
    final runner = env.spriteRunner(rigCaps);
    final settings = ExportSettings();
    final requests = exportSpriteRequests(project, settings, capabilities: caps, metrics: runner.metrics);
    expect(requests.length, greaterThanOrEqualTo(3), reason: 'a text item and two cues');

    final fractions = <double>[];
    final manifest = await runner.run(requests, cacheDir: env.spritesDir, onProgress: fractions.add);
    expect(fractions.last, 1.0);
    expect(manifest.files.keys.toSet(), {for (final r in requests) r.key});
    for (final r in requests) {
      expect(mem.peek('${env.spritesDir}/${r.key}.vsprite'), isNotNull, reason: 'a .vsprite per request');
    }

    final result = await defaultExportCompile(ExportCompileInput(
      project: project,
      settings: settings,
      manifest: manifest,
      resolver: resolverFor(project),
      capabilities: caps,
      spriteRequests: requests,
    ));
    final ready = result as ExportReady;
    expect(ready.plan.assets.keys.where((k) => k.startsWith('sp_')).length, requests.length);

    // A second run reuses the cache and writes nothing new.
    final again = await runner.run(requests, cacheDir: env.spritesDir);
    expect(again.files.keys, manifest.files.keys);
  });

  test('a cancelled pre-pass throws SpritePrepassCancelled and keeps nothing half-written', () async {
    final repo = FakeProjectRepository();
    final project = exportProject(repo);
    final mem = MemoryStoreFs()..mkdirs(rigRoots.cache);
    final env = ExportEnvironment.local(rigRoots, fs: mem);
    final runner = env.spriteRunner(rigCaps);
    final requests = exportSpriteRequests(project, ExportSettings(), capabilities: exportCapabilitiesOf(rigCaps), metrics: runner.metrics);
    await expectLater(runner.run(requests, cacheDir: env.spritesDir, isCancelled: () => true), throwsA(isA<SpritePrepassCancelled>()));
    expect(mem.filePaths.where((p) => p.contains('.tmp-')), isEmpty);
  });

  group('exportCapabilitiesOf', () {
    test('maps the encoders, container, size, frame rates, textures and audio speed', () {
      const caps = EditorCapabilities(
        supported: true,
        hevcEncode: true,
        movContainer: true,
        maxExportSize: Size(2160, 3840),
        maxFpsByHeight: {1080: 60, 2160: 30},
        maxTextureSize: 8192,
        maxAudioSpeed: 2,
        holdFrame: false,
      );
      final e = exportCapabilitiesOf(caps);
      expect((e.h264Encode, e.hevcEncode, e.movContainer), (true, true, true));
      expect((e.maxExportLongSide, e.maxExportShortSide), (3840, 2160), reason: 'long and short side regardless of orientation');
      expect(e.maxFpsFor(1080), 60);
      expect(e.maxFpsFor(2160), 30);
      expect((e.maxTextureSize, e.maxAudioSpeed, e.holdFrame), (8192, 2, false));
    });
  });
}
