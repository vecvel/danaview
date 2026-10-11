// OWNER: UX-20
//
// thumbnailCacheProvider over a real editing session and the engine API fake: strips are
// requested from `engine.thumbnails` for the files the session's compiler resolves, the engine's
// memory warning trims the cache, and disposing the provider disposes the cache.

import 'dart:typed_data';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/editor_providers.dart';
import 'package:vwish_editor/src/editor/caches/thumbnail_cache.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

import '../../state/state_support.dart';
import '../../support/support.dart';
import '../../timeline/canvas/canvas_fixtures.dart';
import 'thumbnail_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('requests strips for the files the session resolves; memory warning trims; dispose disposes', () async {
    final project = projectOf(
      [Track(id: const TrackId('tr_main'), kind: TrackKind.video, isMain: true, items: [clip('it_1', 'm_a', 0, 60 * s)])],
      assets: [asset('m_a')],
    );
    final repo = FakeProjectRepository();
    final id = repo.seed(project);
    final rig = ControllerRig(repository: repo, id: id);
    await rig.open();
    final container = ProviderContainer(overrides: [
      editorEngineProvider.overrideWithValue(rig.engine),
      editorSessionProvider.overrideWith((ref, id) => rig.session),
    ]);
    addTearDown(container.dispose);

    // The timeline holds the provider while it is open; hold it here too (it is autoDispose).
    final sub = container.listen(thumbnailCacheProvider(id), (_, __) {});
    final cache = sub.read();
    expect(cache.budgetBytes, ThumbnailCache.standardBudgetBytes);
    final snap = snapshotOf([clip('it_1', 'm_a', 0, 60 * s)], assets: [asset('m_a')]);
    cache.beginPaint(const TimeRange(0, 20 * s));
    await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(snap)));
    cache.endPaint();
    final requests = rig.engine.thumbnails.requests;
    expect(requests, isNotEmpty);
    expect(requests.first.media.fingerprint, 'fp-m_a', reason: 'the file the session compiler resolved');
    expect(rig.engine.thumbnails.priorities, contains(ThumbPriority.visible));

    // Decode what arrived with a stand-in so the cache holds something, then a memory warning.
    await settle();
    rig.engine.emitSignal(const MemoryWarningSignal());
    await settle();
    expect(cache.cachedBytes, lessThanOrEqualTo(cache.budgetBytes ~/ 4));

    sub.close();
    await settle();
    late bool painted;
    await render(360, 60, (c) => painted = cache.paintThumbnails(c, paintContext(snap)));
    expect(painted, isFalse, reason: 'a disposed cache paints nothing');
    await rig.controller.close();
  });

  test('without a resolvable file nothing is requested', () async {
    final repo = FakeProjectRepository();
    final id = repo.seedEmpty('Empty').id;
    final rig = ControllerRig(repository: repo, id: id);
    await rig.open();
    final container = ProviderContainer(overrides: [
      editorEngineProvider.overrideWithValue(rig.engine),
      editorSessionProvider.overrideWith((ref, id) => rig.session),
    ]);
    addTearDown(container.dispose);
    final sub = container.listen(thumbnailCacheProvider(id), (_, __) {});
    final cache = sub.read();
    final snap = snapshotOf([clip('it_1', 'm_gone', 0, 10 * s)], assets: [asset('m_gone')]);
    cache.beginPaint(const TimeRange(0, 10 * s));
    await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(snap)));
    expect(rig.engine.thumbnails.requests, isEmpty, reason: 'the project does not know the media');
    await rig.controller.close();
  });

  test('the default decoder decodes encoded images (the engine sends JPEG strips)', () async {
    final data = await render(32, 18, (c) {});
    expect(data.lengthInBytes, 32 * 18 * 4);
    // Encode a tiny PNG with the engine and decode it through the cache's default decoder.
    final image = await decodeScripted(Uint8List.fromList([0, 20, 8]));
    final png = (await image.toByteData(format: ImageByteFormat.png))!.buffer.asUint8List();
    image.dispose();
    final decoded = await ThumbnailCache.decodeJpeg(png);
    expect((decoded.width, decoded.height), (128, 9));
    decoded.dispose();
  });
}
