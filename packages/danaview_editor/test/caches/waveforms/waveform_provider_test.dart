// OWNER: UX-21
//
// waveformCacheProvider over a real editing session and the engine API fake: peaks are requested
// from `engine.waveforms` for the files the session's compiler resolves, the engine's memory
// warning trims the cache, and disposing the provider disposes the cache.

import 'package:flutter/painting.dart' show Color, Rect;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/caches/waveform_cache.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show MemoryWarningSignal;

import '../../state/state_support.dart';
import '../../support/support.dart';
import '../../timeline/canvas/canvas_fixtures.dart';
import '../thumbnails/thumbnail_fixtures.dart' show paintContext, render, settle, snapshotOf;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads peaks for the resolved file (flat fake peaks), paints, trims on memory warning, disposes', () async {
    final project = projectOf(
      [Track(id: const TrackId('tr_a'), kind: TrackKind.audio, items: [clip('it_a', 'm_snd', 0, 10 * s)])],
      assets: [asset('m_snd', kind: MediaKind.audio), asset('m_v')],
    );
    // A project needs a main lane to validate: add one.
    final withMain = EditProject(
      id: project.id,
      meta: project.meta,
      timeline: project.timeline.copyWith(tracks: [Track(id: const TrackId('tr_main'), kind: TrackKind.video, isMain: true, items: const []), ...project.tracks]),
      pool: project.pool,
    );
    final repo = FakeProjectRepository();
    final id = repo.seed(withMain);
    final rig = ControllerRig(repository: repo, id: id);
    await rig.open();
    final container = ProviderContainer(overrides: [
      editorEngineProvider.overrideWithValue(rig.engine),
      editorSessionProvider.overrideWith((ref, id) => rig.session),
    ]);
    addTearDown(container.dispose);

    // The timeline holds the provider while it is open; hold it here too (it is autoDispose).
    final sub = container.listen(waveformCacheProvider(id), (_, __) {});
    final cache = sub.read();
    expect(cache.budgetBytes, 24 * 1024 * 1024);
    final snap = snapshotOf([clip('it_a', 'm_snd', 0, 10 * s)], assets: [asset('m_snd', kind: MediaKind.audio)], kind: TrackKind.audio);
    late bool first;
    await render(360, 40, (c) => first = cache.paintWaveform(c, paintContext(snap, height: 40), const Rect.fromLTWH(0, 0, 360, 40), const Color(0xFFFFFFFF)));
    expect(first, isFalse);
    expect(rig.engine.log.calls, contains('waveforms.peaks'));
    // The pyramid is built in Isolate.run: wait for it in real time.
    for (var i = 0; i < 100 && cache.cachedCount == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(cache.cachedCount, 1, reason: 'the fake engine returns flat peaks; the isolate built the pyramid');
    late bool second;
    await render(360, 40, (c) => second = cache.paintWaveform(c, paintContext(snap, height: 40), const Rect.fromLTWH(0, 0, 360, 40), const Color(0xFFFFFFFF)));
    expect(second, isTrue);

    rig.engine.emitSignal(const MemoryWarningSignal());
    await settle();
    expect(cache.cachedBytes, lessThanOrEqualTo(cache.budgetBytes ~/ 4));

    sub.close();
    await settle();
    late bool after;
    await render(360, 40, (c) => after = cache.paintWaveform(c, paintContext(snap, height: 40), const Rect.fromLTWH(0, 0, 360, 40), const Color(0xFFFFFFFF)));
    expect(after, isFalse);
    await rig.controller.close();
  });
}
