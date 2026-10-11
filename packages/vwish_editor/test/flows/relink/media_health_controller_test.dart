// OWNER: UX-40
//
// MediaHealthController (ux.md §13.1) with the scripted pool: every availability state, what counts
// (offline media the timeline uses), publishing to the editor state, re-checks on refresh, the
// banner's dismissal and the stop when the editor closes.

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/state/editor_state.dart';
import 'package:vwish_editor/src/editor/state/media_health_controller.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart' show DeleteItems;
import 'package:vwish_editor_core/store.dart';

import 'relink_support.dart';

void main() {
  late RelinkRig rig;

  Future<RelinkRig> start({int count = 3}) async {
    rig = RelinkRig([for (var i = 1; i <= count; i++) videoAsset('md_$i')]);
    rig.useContainer(rig.harness.container());
    await rig.open();
    // Reading the provider starts it (the editor's banner host does).
    rig.container.listen(mediaHealthControllerProvider(rig.id), (_, __) {});
    await Future<void>.delayed(Duration.zero);
    return rig;
  }

  MediaHealthState state() => rig.container.read(mediaHealthControllerProvider(rig.id));

  test('a clean project: everything available, nothing published', () async {
    await start();
    await rig.report({});
    expect(state().checked, isTrue);
    expect(state().count, 0);
    expect(state().bannerVisible, isFalse);
    expect(rig.editor.state.media, MediaHealth.ok);
    expect(rig.pool.calls, contains('watchAvailability'));
  });

  test('missing, accessLost and changed media are offline and published; derivedMissing is silent', () async {
    await start(count: 4);
    await rig.report({
      'md_1': MediaAvailability.missing,
      'md_2': MediaAvailability.accessLost,
      'md_3': MediaAvailability.changed,
      'md_4': MediaAvailability.derivedMissing,
    });
    final s = state();
    expect(s.offlineUsed, {const MediaId('md_1'), const MediaId('md_2'), const MediaId('md_3')});
    expect(s.count, 3);
    expect(s.missingCount, 1);
    expect(s.onlyMissing, isFalse, reason: 'access lost and changed files need attention, not "missing"');
    expect(s.of(const MediaId('md_4')), MediaAvailability.derivedMissing);
    final published = rig.editor.state.media;
    expect(published.missing, s.offlineUsed);
    expect(published.relinkRequired, isTrue);
  });

  test('only plainly missing files read as missing', () async {
    await start(count: 2);
    await rig.report({'md_1': MediaAvailability.missing, 'md_2': MediaAvailability.missing});
    expect(state().onlyMissing, isTrue);
    expect(state().count, 2);
  });

  test('media the timeline does not use never nags, and a clip that leaves the timeline stops counting', () async {
    await start(count: 2);
    await rig.report({'md_1': MediaAvailability.missing, 'md_2': MediaAvailability.missing});
    expect(rig.editor.state.media.missing, hasLength(2));
    final clip = rig.editor.state.project!.tracks.expand((t) => t.items).firstWhere((i) => i is MediaClip && i.media.value == 'md_2');
    rig.editor.apply(DeleteItems({clip.id}));
    await Future<void>.delayed(Duration.zero);
    expect(state().offline, hasLength(2), reason: 'the sheet still lists it');
    expect(state().offlineUsed, {const MediaId('md_1')});
    expect(rig.editor.state.media.missing, {const MediaId('md_1')});
  });

  test('the files coming back clear the published health', () async {
    await start();
    await rig.report({'md_1': MediaAvailability.missing});
    expect(rig.editor.state.media.isOk, isFalse);
    await rig.report({});
    expect(rig.editor.state.media, MediaHealth.ok);
    expect(state().bannerVisible, isFalse);
  });

  test('refresh listens again so the pool service checks again (app resume, after a relink)', () async {
    await start();
    await rig.report({'md_1': MediaAvailability.missing});
    final before = rig.pool.calls.where((c) => c == 'watchAvailability').length;
    rig.container.read(mediaHealthControllerProvider(rig.id).notifier).refresh();
    await Future<void>.delayed(Duration.zero);
    expect(rig.pool.calls.where((c) => c == 'watchAvailability').length, before + 1);
    // The fake replays its current report on listen.
    expect(state().offlineUsed, {const MediaId('md_1')});
  });

  test('the banner can be dismissed, returns when more files go missing, and on resurface', () async {
    await start();
    await rig.report({'md_1': MediaAvailability.missing});
    final controller = rig.container.read(mediaHealthControllerProvider(rig.id).notifier);
    expect(state().bannerVisible, isTrue);
    controller.dismissBanner();
    expect(state().bannerVisible, isFalse);
    expect(state().count, 1, reason: 'the health itself is unchanged');
    expect(rig.editor.state.media.isOk, isFalse, reason: 'the preview card and export block still apply');

    await rig.report({'md_1': MediaAvailability.missing, 'md_2': MediaAvailability.missing});
    expect(state().bannerVisible, isTrue, reason: 'one more file went missing');
    controller.dismissBanner();
    controller.resurfaceBanner();
    expect(state().bannerVisible, isTrue, reason: 'the export pre-check brings it back');
    controller.resurfaceBanner();
    expect(state().dismissedCount, 0);
  });

  test('a loss after everything came back shows the banner again', () async {
    await start();
    await rig.report({'md_1': MediaAvailability.missing});
    rig.container.read(mediaHealthControllerProvider(rig.id).notifier).dismissBanner();
    await rig.report({});
    await rig.report({'md_1': MediaAvailability.missing});
    expect(state().bannerVisible, isTrue);
  });

  test('closing the editor stops watching', () async {
    await start();
    await rig.report({'md_1': MediaAvailability.missing});
    final controller = rig.container.read(mediaHealthControllerProvider(rig.id).notifier);
    expect(controller.isWatching, isTrue);
    await rig.editor.close();
    expect(controller.isWatching, isFalse);
  });

  test('state equality and copyWith', () {
    final a = MediaHealthState(byMedia: {const MediaId('md_1'): MediaAvailability.missing}, used: {const MediaId('md_1')}, checked: true);
    final b = MediaHealthState(byMedia: {const MediaId('md_1'): MediaAvailability.missing}, used: {const MediaId('md_1')}, checked: true);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a.copyWith(dismissedCount: 1), isNot(a));
    expect(a.health.missing, {const MediaId('md_1')});
    expect(MediaHealthState.unknown.health, MediaHealth.ok);
    expect(a.toString(), contains('offline: 1'));
  });
}
