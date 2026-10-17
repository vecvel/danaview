// OWNER: UX-40
//
// No-overflow matrix (ARCH §1.3 rule 5, §17.9) for the missing media banner, the Missing media sheet
// (rows in every state, long names, the confirm list of Relink several) and the read-only banner:
// no overflow, Figtree only, round buttons only for single icons, and the actions reachable.

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/editor_scope.dart';
import 'package:danaview_editor/src/editor/flows/relink/editor_health_host.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/store.dart';

import '../../support/support.dart';
import 'relink_support.dart';

const _long = 'a_very_long_file_name_that_keeps_going_and_going_IMG_0001_final_FINAL_version_three_edit.MOV';

PickedMedia _pick(String name, {bool photo = false}) => PickedMedia(
      uri: photo ? 'file:///work/picks/$name' : 'file:///picked/$name',
      displayName: name,
      origin: photo ? MediaOrigin.photos : MediaOrigin.files,
      isTemporaryCopy: photo,
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpHost(WidgetTester tester, RelinkRig rig, EditorSurface surface) async {
  await rig.harness.pumpApp(
    tester,
    EditorScope(projectId: rig.id, child: const Scaffold(body: SafeArea(child: Align(alignment: Alignment.topCenter, child: EditorHealthHost())))),
    surface: surface,
  );
  rig.useContainer(rig.harness.containerOf(tester));
  await tester.runAsync(rig.open);
  await _settle(tester);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _settle(tester);
}

RelinkRig _rig() {
  final assets = [
    videoAsset('md_1', name: _long, locator: const FileLocator('/Users/me/Movies/A_really_long_folder_name_for_the_trip_to_goa_2026/$_long')),
    videoAsset('md_2', name: 'beach.mp4', locator: BookmarkLocator('AQID', lastKnownPath: '/Users/me/Downloads/beach.mp4')),
    videoAsset('md_3', name: 'drone.mp4', locator: const FileLocator('/Users/me/Documents/drone.mp4')),
    videoAsset('md_4', name: 'song.mp3', kind: MediaKind.audio),
  ];
  return RelinkRig(assets, extraUses: {'md_1': 11});
}

void main() {
  testSurfaces('the banner and the sheet rows in every state', (tester, surface) async {
    final rig = _rig();
    await _pumpHost(tester, rig, surface);
    await tester.runAsync(() => rig.report({
          'md_1': MediaAvailability.missing,
          'md_2': MediaAvailability.accessLost,
          'md_3': MediaAvailability.changed,
          'md_4': MediaAvailability.missing,
        }));
    await _settle(tester);
    expectNoOverflow(tester);
    expectFitsFully(tester, find.byKey(const ValueKey('missing-media-banner')));
    expectOwnerUiRules(tester);

    await tester.tap(find.byKey(const ValueKey('missing-media-relink')));
    await _settle(tester);
    expectNoOverflow(tester);

    // Rows with staged files of every outcome.
    rig.pool.checks['short.mov'] = const RelinkDurationMismatch(expectedUs: 45000000, actualUs: 42000000);
    rig.pool.checks['song.mov'] = const RelinkDifferentKind();
    rig.harness.engine.picker.nextPicks = [_pick('IMG_0001_copy_with_a_rather_long_name_as_well.MOV')];
    await _tap(tester, find.byKey(const ValueKey('relink-locate-md_1')));
    await _tap(tester, find.textContaining('From ').first);
    rig.harness.engine.picker.nextPicks = [_pick('short.mov')];
    await _tap(tester, find.byKey(const ValueKey('relink-locate-md_2')));
    await _tap(tester, find.textContaining('From ').first);
    rig.harness.engine.picker.nextPicks = [_pick('song.mov')];
    await _tap(tester, find.byKey(const ValueKey('relink-locate-md_3')));
    await _tap(tester, find.textContaining('From ').first);
    expectNoOverflow(tester);
    expectOwnerUiRules(tester);
    for (final key in ['relink-apply', 'relink-close', 'relink-several-button', 'relink-more-md_1', 'relink-accept-md_2']) {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.pump();
      expectInside(tester, find.byKey(ValueKey(key)));
    }
    expectNoOverflow(tester);
  });

  testSurfaces('the confirm list of Relink several', (tester, surface) async {
    final rig = _rig();
    await _pumpHost(tester, rig, surface);
    await tester.runAsync(() => rig.report({for (final a in rig.assets) a.id.value: MediaAvailability.missing}));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('missing-media-relink')));
    await _settle(tester);
    final picks = [
      _pick('IMG_0001_copy_with_a_rather_long_name_as_well_to_check_wrapping.MOV', photo: true),
      _pick('copy_2.MOV', photo: true),
      _pick('copy_3.MOV', photo: true),
      _pick('copy_4.MOV', photo: true),
    ];
    rig.harness.engine.picker.nextPicks = picks;
    rig.pool.onAutoMatch = (p) => [
          RelinkProposal(pick: p[0], media: const MediaId('md_1'), check: const RelinkMatch(exactFingerprint: true)),
          RelinkProposal(pick: p[1], media: const MediaId('md_2'), check: const RelinkMatch(exactFingerprint: false)),
          RelinkProposal(pick: p[2], media: null, check: const RelinkUnsupported('ambiguous')),
          RelinkProposal(pick: p[3], media: null, check: const RelinkDifferentKind()),
        ];
    await _tap(tester, find.byKey(const ValueKey('relink-several-button')));
    await _tap(tester, find.textContaining('From ').last);
    expect(find.byKey(const ValueKey('relink-confirm')), findsOneWidget);
    expectNoOverflow(tester);
    expectOwnerUiRules(tester);
    for (final key in ['relink-confirm-apply', 'relink-confirm-back', 'relink-still-missing', 'relink-unmatched']) {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.pump();
      expectInside(tester, find.byKey(ValueKey(key)));
    }
    expectNoOverflow(tester);
  });

  testSurfaces('the read-only banner', (tester, surface) async {
    final rig = RelinkRig([videoAsset('md_1')]);
    rig.repo.openResults[rig.id] = (p) => LoadedProject(project: p, health: ProjectHealth.readOnlyNewer);
    await _pumpHost(tester, rig, surface);
    expect(find.byKey(const ValueKey('read-only-banner')), findsOneWidget);
    expect(find.text('Read-only: made with a newer Danaview'), findsOneWidget);
    expectNoOverflow(tester);
    expectFitsFully(tester, find.byKey(const ValueKey('read-only-banner')));
    expectOwnerUiRules(tester);
  });
}
