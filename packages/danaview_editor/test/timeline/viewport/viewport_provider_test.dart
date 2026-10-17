// OWNER: UX-09
//
// viewportProvider (createViewportController): one controller per project in the device default
// mode, kept in step with the Editor setting, flushed when the last listener leaves and disposed
// with the provider.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_prefs.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor_core/model.dart';

import '../../support/support.dart';

void main() {
  const a = ProjectId('pr_aaaaaaaaaaaa'), b = ProjectId('pr_bbbbbbbbbbbb');

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('one controller per project; touch platforms default to centre-locked', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final c = EditorTestHarness().container();
    final sa = c.listen(viewportProvider(a), (_, __) {});
    final sb = c.listen(viewportProvider(b), (_, __) {});
    addTearDown(sa.close);
    addTearDown(sb.close);
    expect(sa.read(), same(c.read(viewportProvider(a))));
    expect(sa.read(), isNot(same(sb.read())));
    expect(sa.read().mode, PlayheadFollowMode.centreLocked);
    expect(sa.read().modeIsExplicit, isFalse);
  });

  test('pointer platforms default to free mode', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final c = EditorTestHarness().container();
    final s = c.listen(viewportProvider(a), (_, __) {});
    addTearDown(s.close);
    expect(s.read().mode, PlayheadFollowMode.free);
  });

  test('the "Center playhead" setting changes the default until a mode is chosen', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final prefs = EditorPrefs.memory();
    final c = EditorTestHarness(prefs: prefs).container();
    final s = c.listen(viewportProvider(a), (_, __) {});
    addTearDown(s.close);
    final viewport = s.read();
    expect(viewport.mode, PlayheadFollowMode.centreLocked);
    await prefs.setCenterPlayheadOnTouch(false);
    expect(viewport.mode, PlayheadFollowMode.free);
    viewport.setMode(PlayheadFollowMode.centreLocked);
    await prefs.setCenterPlayheadOnTouch(true);
    await prefs.setCenterPlayheadOnTouch(false);
    expect(viewport.mode, PlayheadFollowMode.centreLocked, reason: 'an explicit mode wins');
  });

  test('a setting stored before opening applies at creation', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final prefs = EditorPrefs.memory({EditorPrefKeys.centerPlayheadOnTouch: false});
    final c = EditorTestHarness(prefs: prefs).container();
    final s = c.listen(viewportProvider(a), (_, __) {});
    addTearDown(s.close);
    expect(s.read().mode, PlayheadFollowMode.free);
  });

  test('the view is written when the last listener leaves, then the controller is disposed', () async {
    final prefs = EditorPrefs.memory();
    final c = EditorTestHarness(prefs: prefs).container();
    final s = c.listen(viewportProvider(a), (_, __) {});
    final viewport = s.read();
    var view = ViewState.initial;
    var writes = 0;
    viewport
      ..setContent(duration: 60 * microsPerSecond, contentHeight: 300)
      ..setViewport(const Size(444, 224), 44, rulerHeight: 24)
      ..attachViewSink((update) {
        writes++;
        view = update(view);
      });
    // A pan in progress has not settled yet.
    viewport
      ..beginGesture()
      ..scrollByPx(0, 40);
    expect(writes, 0);
    s.close();
    expect(writes, 1);
    expect(view.scrollLanePx, 40);
    await Future<void>.delayed(Duration.zero);
    var listened = false;
    expect(() => viewport.addListener(() => listened = true), throwsFlutterError, reason: 'disposed');
    expect(listened, isFalse);
    // The settings listener went with it: changing the setting no longer touches the old controller.
    await prefs.setCenterPlayheadOnTouch(false);
    expect(c.read(viewportProvider(a)), isNot(same(viewport)), reason: 'a new controller after disposal');
  });
}
