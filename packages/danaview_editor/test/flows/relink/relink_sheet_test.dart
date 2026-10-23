// OWNER: UX-40
//
// The editor's missing media UI (ux.md §13.1, §13.2) with fakes: the banner (missing, needs
// attention, dismiss, Relink), the Missing media sheet for every availability state, every relink
// outcome's copy, "Use it anyway", Use updated file, Find in same folder, Relink several with the
// confirm list (10 Photos assets in one pick session), Remove clips and Replace, and that relinking
// is one history entry.


import 'package:flutter/material.dart' show Icons, Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/editor_scope.dart';
import 'package:danaview_editor/src/editor/flows/relink/editor_health_host.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show DeleteItems;
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_features/storage.dart' show formatDataSize;
import 'package:danaview_ui_kit/danaview_ui_kit.dart' show DanaviewButton, DanaviewColors, DanaviewSurface, DanaviewSwitch;

import '../../support/support.dart';
import 'relink_support.dart';

PickedMedia _pick(String name, {bool photo = false, String dir = '/picked'}) => PickedMedia(
      uri: photo ? 'file:///work/picks/$name' : 'file://$dir/$name',
      displayName: name,
      origin: photo ? MediaOrigin.photos : MediaOrigin.files,
      isTemporaryCopy: photo,
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpHost(WidgetTester tester, RelinkRig rig, {EditorSurface surface = SurfaceMatrix.phone}) async {
  await rig.harness.pumpApp(
    tester,
    EditorScope(projectId: rig.id, child: const Scaffold(body: SafeArea(child: Align(alignment: Alignment.topCenter, child: EditorHealthHost())))),
    surface: surface,
  );
  rig.useContainer(rig.harness.containerOf(tester));
  await tester.runAsync(rig.open);
  await _settle(tester);
}

Future<void> _report(WidgetTester tester, RelinkRig rig, Map<String, MediaAvailability> offline) async {
  await tester.runAsync(() => rig.report(offline));
  await _settle(tester);
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('missing-media-relink')));
  await _settle(tester);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _settle(tester);
}

Finder _key(String key) => find.byKey(ValueKey(key));

/// Locates [id] from Files with [pick] through the row's menu.
Future<void> _locate(WidgetTester tester, RelinkRig rig, String id, PickedMedia pick, {String source = 'From Gallery'}) async {
  rig.harness.engine.picker.nextPicks = [pick];
  await _tap(tester, _key('relink-locate-$id'));
  await _tap(tester, find.text(source));
}

RelinkRig _rig(List<MediaAsset> assets, {Map<String, int> extraUses = const {}}) => RelinkRig(assets, extraUses: extraUses);

List<MediaAsset> _three() => [videoAsset('md_1', name: 'IMG_0001.MOV'), videoAsset('md_2', name: 'beach.mp4'), videoAsset('md_3', name: 'drone.mp4')];

Map<String, MediaAvailability> _missing(Iterable<String> ids) => {for (final i in ids) i: MediaAvailability.missing};

void main() {
  group('MissingMediaBanner', () {
    testWidgets('shows nothing while everything is available', (tester) async {
      final rig = _rig(_three());
      await _pumpHost(tester, rig);
      await _report(tester, rig, {});
      expect(_key('missing-media-banner'), findsNothing);
      expect(find.textContaining('missing'), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('"2 files are missing" with Relink; "needs attention" when files changed or lost access', (tester) async {
      final rig = _rig(_three());
      await _pumpHost(tester, rig);
      await _report(tester, rig, _missing(['md_1', 'md_2']));
      expect(find.text('2 files are missing'), findsOneWidget);
      expect(find.text('Relink'), findsOneWidget);
      expectNeutralBorders(tester, of: _key('missing-media-banner'));
      await _report(tester, rig, {'md_1': MediaAvailability.missing, 'md_2': MediaAvailability.accessLost, 'md_3': MediaAvailability.changed});
      expect(find.text('3 files need attention'), findsOneWidget);
      expect(
        tester.widget<DanaviewSurface>(find.descendant(of: _key('missing-media-banner'), matching: find.byType(DanaviewSurface)).first).borderColor,
        DanaviewColors.hairline,
        reason: 'no warning-coloured outline around the banner',
      );
      expectNeutralBorders(tester, of: _key('missing-media-banner'));
      await _report(tester, rig, _missing(['md_1']));
      expect(find.text('1 file is missing'), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });

    testWidgets('dismiss hides it for this session; one more missing file brings it back', (tester) async {
      final rig = _rig(_three());
      await _pumpHost(tester, rig);
      await _report(tester, rig, _missing(['md_1']));
      await _tap(tester, _key('missing-media-dismiss'));
      expect(_key('missing-media-banner'), findsNothing);
      expect(rig.editor.state.media.isOk, isFalse, reason: 'the health itself is not dismissed');
      await _report(tester, rig, _missing(['md_1', 'md_2']));
      expect(find.text('2 files are missing'), findsOneWidget);
    });

    testWidgets('Relink opens the Missing media sheet through the relink action', (tester) async {
      final rig = _rig(_three());
      await _pumpHost(tester, rig);
      await _report(tester, rig, _missing(['md_1']));
      await _openSheet(tester);
      expect(find.text('Missing media'), findsOneWidget);
      expect(_key('relink-sheet'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });

  group('the sheet: every availability state', () {
    testWidgets('missing, access lost and changed rows say what is wrong, with usage, kind, length, size and folder', (tester) async {
      final assets = [
        videoAsset('md_1', name: 'lost.mov', locator: const FileLocator('/Users/me/Movies/Trip/lost.mov'), seconds: 65),
        videoAsset('md_2', name: 'revoked.mov', locator: BookmarkLocator('AQID', lastKnownPath: '/Users/me/Downloads/revoked.mov')),
        videoAsset('md_3', name: 'edited.mov', locator: const FileLocator('/Users/me/Documents/edited.mov')),
        videoAsset('md_4', name: 'fine.mov'),
      ];
      final rig = _rig(assets, extraUses: {'md_1': 2});
      await _pumpHost(tester, rig);
      await _report(tester, rig, {
        'md_1': MediaAvailability.missing,
        'md_2': MediaAvailability.accessLost,
        'md_3': MediaAvailability.changed,
        'md_4': MediaAvailability.derivedMissing,
      });
      await _openSheet(tester);
      expect(find.text('3 files need attention'), findsWidgets);
      expect(find.text('Missing'), findsOneWidget);
      expect(find.text("Danaview can't open it any more"), findsOneWidget);
      expect(find.text('Changed since you added it'), findsOneWidget);
      expect(find.text('Used in 3 clips'), findsOneWidget);
      expect(find.text('Used in 1 clip'), findsNWidgets(2));
      expect(find.text('Video · 1:05 · ${formatDataSize(4000000)}'), findsOneWidget);
      expect(find.text('Last seen in Trip'), findsOneWidget);
      expect(find.text('Last seen in Downloads'), findsOneWidget);
      expect(find.text('fine.mov'), findsNothing, reason: 'rebuilt silently, never listed');
      expect(find.text('Use updated file'), findsOneWidget, reason: 'only the changed file');
      expect(find.text('Relink several'), findsWidgets);
      expect(find.text('Relink 3 files'), findsOneWidget);
      expect(tester.widget<DanaviewButton>(_key('relink-apply')).onPressed, isNull);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });

    testWidgets('files that come back leave the sheet; nothing missing says everything is back', (tester) async {
      final rig = _rig(_three());
      await _pumpHost(tester, rig);
      await _report(tester, rig, _missing(['md_1']));
      await _openSheet(tester);
      expect(find.text('IMG_0001.MOV'), findsOneWidget);
      await _report(tester, rig, {});
      expect(_key('relink-all-good'), findsOneWidget);
      expect(find.text('Everything is back'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      await _tap(tester, _key('relink-close'));
      expect(_key('relink-sheet'), findsNothing);
    });
  });

  group('the sheet: relink outcomes', () {
    Future<RelinkRig> open(WidgetTester tester, {List<MediaAsset>? assets}) async {
      final rig = _rig(assets ?? _three());
      await _pumpHost(tester, rig);
      await _report(tester, rig, _missing(rig.assets.map((a) => a.id.value)));
      await _openSheet(tester);
      return rig;
    }

    testWidgets('match: a check mark and "ready to relink"; the primary button counts it', (tester) async {
      final rig = await open(tester);
      await _locate(tester, rig, 'md_1', _pick('IMG_0001_copy.MOV'));
      expect(find.text('Matches · ready to relink'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded), findsWidgets);
      expect(find.text('IMG_0001_copy.MOV'), findsOneWidget);
      expect(find.text('Relink 1 file'), findsOneWidget);
      expect(rig.harness.engine.picker.requests.single.multiple, isFalse);
      expectNoOverflow(tester);
    });

    testWidgets('durationMismatch asks "Use it anyway?" with both lengths and the clamp warning', (tester) async {
      final rig = await open(tester);
      rig.pool.checks['short.mov'] = const RelinkDurationMismatch(expectedUs: 45000000, actualUs: 42000000);
      await _locate(tester, rig, 'md_1', _pick('short.mov'));
      expect(find.text('This file is 0:42 but the original was 0:45. Clips past 0:42 will be shortened. Use it anyway?'), findsOneWidget);
      expect(find.text('Use it anyway'), findsOneWidget);
      expect(find.text('Relink 3 files'), findsOneWidget, reason: 'nothing is ready, the button names all missing files and is disabled');
      await _tap(tester, _key('relink-accept-md_1'));
      expect(find.text('Different length · will be used anyway'), findsOneWidget);
      expect(find.text('Relink 1 file'), findsOneWidget);

      rig.pool.checks['long.mov'] = const RelinkDurationMismatch(expectedUs: 5000000, actualUs: 7000000);
      await _locate(tester, rig, 'md_2', _pick('long.mov'));
      expect(find.text('This file is 0:07 but the original was 0:05. Your clips keep their length. Use it anyway?'), findsOneWidget);
    });

    testWidgets('differentKind and unsupported name the reason in plain words', (tester) async {
      final rig = await open(tester);
      rig.pool.checks['song.mp3'] = const RelinkDifferentKind();
      rig.pool.checks['holiday.mkv'] = const RelinkUnsupported('containerUnsupportedIos');
      rig.pool.checks['big.mov'] = const RelinkUnsupported('dimensionsDiffer');
      await _locate(tester, rig, 'md_1', _pick('song.mp3'));
      expect(find.text('Pick a video file to replace a video.'), findsOneWidget);
      await _locate(tester, rig, 'md_2', _pick('holiday.mkv'));
      expect(find.text("MKV, WebM and AVI videos can't be edited on iPhone and iPad. Convert it to MP4 or MOV first."), findsOneWidget);
      await _locate(tester, rig, 'md_3', _pick('big.mov'));
      expect(find.textContaining('different picture size'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsNWidgets(3));
      expect(find.text('Relink 3 files'), findsOneWidget);
      expect(tester.widget<DanaviewButton>(_key('relink-apply')).onPressed, isNull);
      expectNoOverflow(tester);
    });

    testWidgets('the clear button drops a staged file', (tester) async {
      final rig = await open(tester);
      await _locate(tester, rig, 'md_1', _pick('a.mov'));
      await _tap(tester, _key('relink-clear-md_1'));
      expect(find.text('Matches · ready to relink'), findsNothing);
      expect(find.text('Missing'), findsNWidgets(3));
    });

    testWidgets('audio files are picked from Files only', (tester) async {
      final audio = videoAsset('md_a', name: 'song.mp3', kind: MediaKind.audio);
      final rig = _rig([audio]);
      await _pumpHost(tester, rig);
      await _report(tester, rig, _missing(['md_a']));
      await _openSheet(tester);
      rig.harness.engine.picker.nextPicks = [_pick('song2.mp3')];
      await _tap(tester, _key('relink-locate-md_a'));
      expect(find.text('From Files'), findsNothing, reason: 'no menu: audio has one source');
      expect(find.text('Matches · ready to relink'), findsOneWidget);
    });
  });

  group('the sheet: updated file and same folder', () {
    testWidgets('Use updated file stages the file a changed asset points at', (tester) async {
      final asset = videoAsset('md_1', name: 'edited.mov', locator: const FileLocator('/Users/me/Movies/edited.mov'));
      final rig = _rig([asset]);
      await _pumpHost(tester, rig);
      await _report(tester, rig, {'md_1': MediaAvailability.changed});
      await _openSheet(tester);
      await _tap(tester, _key('relink-updated-md_1'));
      expect(find.text('Matches · ready to relink'), findsOneWidget);
      expect(find.text('Use updated file'), findsNothing, reason: 'staged now');
      expect(rig.pool.calls, contains('checkRelink'));
    });

    testWidgets('Find in same folder appears after a path pick and reports "Found 2 of 2"', (tester) async {
      final rig = _rig(_three());
      await _pumpHost(tester, rig);
      await _report(tester, rig, _missing(['md_1', 'md_2', 'md_3']));
      await _openSheet(tester);
      expect(find.text('Find in same folder'), findsNothing);
      rig.pool.onFindInSameFolder = (anchor) => [
            RelinkCandidate(media: const MediaId('md_2'), pick: _pick('beach.mp4', dir: '/Movies/Trip'), check: const RelinkMatch(exactFingerprint: true)),
            RelinkCandidate(media: const MediaId('md_3'), pick: _pick('drone.mp4', dir: '/Movies/Trip'), check: const RelinkMatch(exactFingerprint: false)),
          ];
      await _locate(tester, rig, 'md_1', _pick('IMG_0001.MOV', dir: '/Movies/Trip'), source: 'From Files');
      await _tap(tester, _key('relink-folder-md_1'));
      expect(find.text('Found 2 of 2 in the same folder'), findsOneWidget);
      expect(find.text('Matches · ready to relink'), findsNWidgets(2));
      expect(find.text('Same file · ready to relink'), findsOneWidget, reason: 'beach.mp4 matched by its fingerprint');
      expect(find.text('Relink 3 files'), findsOneWidget);
    });

    testWidgets('a Photos pick offers no folder search', (tester) async {
      final rig = _rig(_three());
      await _pumpHost(tester, rig);
      await _report(tester, rig, _missing(['md_1']));
      await _openSheet(tester);
      await _locate(tester, rig, 'md_1', _pick('IMG_0001.MOV', photo: true));
      expect(find.text('Find in same folder'), findsNothing);
    });
  });

  group('the sheet: apply', () {
    testWidgets('Relink N files relinks everything staged as ONE history entry and toasts', (tester) async {
      final rig = _rig(_three());
      await _pumpHost(tester, rig);
      await _report(tester, rig, _missing(['md_1', 'md_2', 'md_3']));
      await _openSheet(tester);
      await _locate(tester, rig, 'md_1', _pick('a.mov'));
      await _locate(tester, rig, 'md_2', _pick('b.mov'));
      expect(rig.editor.state.history.canUndo, isFalse);
      await _tap(tester, _key('relink-apply'));
      expect(rig.pool.lastRelink!.keys.map((k) => k.value).toSet(), {'md_1', 'md_2'});
      expect(rig.editor.session.historyEntries, hasLength(1));
      expect(rig.editor.state.history.undoLabel, 'Relink media');
      expect(find.text('Relinked 2 files'), findsOneWidget);
      // The availability report after the relink: md_3 is still missing.
      await _report(tester, rig, _missing(['md_3']));
      expect(find.text('drone.mp4'), findsOneWidget);
      expect(find.text('IMG_0001.MOV'), findsNothing);
      expect(find.text('a.mov'), findsNothing);
      expect(rig.editor.state.media.missing, {const MediaId('md_3')});
    });

    testWidgets('a failed relink says nothing was changed', (tester) async {
      final rig = _rig(_three());
      await _pumpHost(tester, rig);
      await _report(tester, rig, _missing(['md_1']));
      await _openSheet(tester);
      await _locate(tester, rig, 'md_1', _pick('a.mov'));
      rig.pool.rejectRelink = true;
      await _tap(tester, _key('relink-apply'));
      expect(find.text("Couldn't relink these files"), findsOneWidget);
      expect(find.textContaining('Nothing was changed'), findsOneWidget);
      expect(rig.editor.state.history.canUndo, isFalse);
      expect(find.text('Relink 1 file'), findsOneWidget, reason: 'the staged file is still there to try again');
    });

    testWidgets('the failure message is outlined by the neutral hairline; the error reads from icon and text', (tester) async {
      final rig = _rig(_three());
      await _pumpHost(tester, rig);
      await _report(tester, rig, _missing(['md_1']));
      await _openSheet(tester);
      await _locate(tester, rig, 'md_1', _pick('a.mov'));
      rig.pool.rejectRelink = true;
      await _tap(tester, _key('relink-apply'));
      final message = find.ancestor(of: find.text("Couldn't relink these files"), matching: find.byType(DanaviewSurface)).first;
      expect(tester.widget<DanaviewSurface>(message).borderColor, DanaviewColors.hairline);
      expect(tester.widget<Icon>(find.descendant(of: message, matching: find.byIcon(Icons.error_outline_rounded))).color, DanaviewColors.errorLight);
      expectNeutralBorders(tester, of: _key('relink-sheet'));
    });
  });

  group('the sheet: Relink several', () {
    List<MediaAsset> ten() => [for (var i = 1; i <= 10; i++) videoAsset('md_$i', name: 'IMG_${i.toString().padLeft(4, '0')}.MOV', seconds: 3 + i)];

    testWidgets('10 missing Photos assets: one pick session, a confirm list, one relink, one history entry', (tester) async {
      final assets = ten();
      final rig = _rig(assets);
      await _pumpHost(tester, rig);
      await _report(tester, rig, _missing(assets.map((a) => a.id.value)));
      await _openSheet(tester);
      final picks = [for (var i = 1; i <= 10; i++) _pick('copy_$i.MOV', photo: true)];
      rig.harness.engine.picker.nextPicks = picks;
      rig.pool.onAutoMatch = (p) => [
            for (var i = 0; i < p.length; i++) RelinkProposal(pick: p[i], media: assets[i].id, check: const RelinkMatch(exactFingerprint: true)),
          ];
      await _tap(tester, _key('relink-several-button'));
      await _tap(tester, find.text('From Gallery').last);
      expect(rig.harness.engine.picker.requests, hasLength(1));
      expect(_key('relink-confirm'), findsOneWidget);
      expect(find.text('Matched 10 of 10 picked files'), findsOneWidget);
      expect(find.text('Will be relinked'), findsOneWidget);
      expect(find.text('copy_1.MOV'), findsOneWidget);
      expect(find.text('Replaces IMG_0001.MOV'), findsOneWidget);
      expect(find.text('Relink 10 files'), findsOneWidget);
      expectNoOverflow(tester);
      await _tap(tester, _key('relink-confirm-apply'));
      expect(rig.pool.calls.where((c) => c == 'relink'), hasLength(1));
      expect(rig.pool.lastRelink!.keys, hasLength(10));
      expect(rig.editor.session.historyEntries, hasLength(1));
      expect(find.text('Relinked 10 files'), findsOneWidget);
      await _report(tester, rig, {});
      expect(find.text('Everything is back'), findsOneWidget);
    });

    testWidgets('unassigned picks and files that stay missing are listed; a pair can be switched off', (tester) async {
      final assets = ten();
      final rig = _rig(assets);
      await _pumpHost(tester, rig);
      await _report(tester, rig, _missing(assets.map((a) => a.id.value)));
      await _openSheet(tester);
      rig.harness.engine.picker.nextPicks = [for (var i = 1; i <= 10; i++) _pick('copy_$i.MOV', photo: true)];
      rig.pool.onAutoMatch = (p) => [
            for (var i = 0; i < 7; i++) RelinkProposal(pick: p[i], media: assets[i].id, check: const RelinkMatch(exactFingerprint: false)),
            RelinkProposal(pick: p[7], media: null, check: const RelinkUnsupported('ambiguous')),
            RelinkProposal(pick: p[8], media: null, check: const RelinkUnsupported('noMatch')),
            RelinkProposal(pick: p[9], media: null, check: const RelinkDifferentKind()),
          ];
      await _tap(tester, _key('relink-several-button'));
      await _tap(tester, find.text('From Gallery').last);
      expect(find.text('Matched 7 of 10 picked files'), findsOneWidget);
      expect(find.text('Not matched'), findsOneWidget);
      expect(find.text('Several files could replace this one. Pick it yourself.'), findsOneWidget);
      expect(find.text('No missing file matches this one.'), findsOneWidget);
      expect(find.text("Didn't match a missing file"), findsOneWidget);
      expect(find.text('Still missing'), findsOneWidget);
      expect(find.text('IMG_0008.MOV'), findsOneWidget);
      expect(find.text('Relink 7 files'), findsOneWidget);
      await _tap(tester, find.descendant(of: _key('relink-match-0'), matching: find.byType(DanaviewSwitch)));
      expect(find.text('Relink 6 files'), findsOneWidget);
      await _tap(tester, _key('relink-confirm-back'));
      expect(_key('relink-sheet'), findsOneWidget);
      expect(rig.pool.calls, isNot(contains('relink')));
    });

    testWidgets('UX-40: a file located first is listed as located and counted: "Relink 3 files"', (tester) async {
      final rig = _rig(_three());
      await _pumpHost(tester, rig);
      await _report(tester, rig, _missing(['md_1', 'md_2', 'md_3']));
      await _openSheet(tester);
      await _locate(tester, rig, 'md_1', _pick('IMG_0001.MOV'));
      final picks = [_pick('beach.mp4'), _pick('drone.mp4')];
      rig.harness.engine.picker.nextPicks = picks;
      rig.pool.onAutoMatch = (p) => [
            RelinkProposal(pick: p[0], media: const MediaId('md_2'), check: const RelinkMatch(exactFingerprint: true)),
            RelinkProposal(pick: p[1], media: const MediaId('md_3'), check: const RelinkMatch(exactFingerprint: true)),
          ];
      await _tap(tester, _key('relink-several-button'));
      await _tap(tester, find.text('From Files').last);
      expect(_key('relink-confirm'), findsOneWidget);
      expect(find.text('Still missing'), findsNothing, reason: 'IMG_0001.MOV was located');
      expect(find.text('Already located'), findsOneWidget);
      expect(find.descendant(of: _key('relink-already-located'), matching: find.text('IMG_0001.MOV')), findsOneWidget);
      expect(find.text('Relink 3 files'), findsOneWidget);
      expectNoOverflow(tester);
      await _tap(tester, _key('relink-confirm-apply'));
      expect(rig.pool.lastRelink!.keys.map((k) => k.value).toSet(), {'md_1', 'md_2', 'md_3'});
      expect(rig.editor.session.historyEntries, hasLength(1));
      expect(find.text('Relinked 3 files'), findsOneWidget);
    });

    testWidgets('no match at all: the list says so and offers only Back', (tester) async {
      final rig = _rig(_three());
      await _pumpHost(tester, rig);
      await _report(tester, rig, _missing(['md_1', 'md_2', 'md_3']));
      await _openSheet(tester);
      rig.harness.engine.picker.nextPicks = [_pick('x.mov')];
      await _tap(tester, _key('relink-several-button'));
      await _tap(tester, find.text('From Gallery').last);
      expect(find.textContaining('None of the picked files matched'), findsOneWidget);
      expect(_key('relink-confirm-apply'), findsNothing);
      expect(_key('relink-confirm-back'), findsOneWidget);
    });
  });

  group('the sheet: remove clips and replace', () {
    Future<RelinkRig> open(WidgetTester tester) async {
      final rig = _rig(_three(), extraUses: {'md_1': 1});
      await _pumpHost(tester, rig);
      await _report(tester, rig, _missing(['md_1']));
      await _openSheet(tester);
      return rig;
    }

    testWidgets('Remove clips that use it asks first, then removes them as one history entry', (tester) async {
      final rig = await open(tester);
      await _tap(tester, _key('relink-more-md_1'));
      expect(find.text('Replace with other media…'), findsOneWidget);
      await _tap(tester, find.text('Remove clips that use it'));
      expect(find.text('Remove 2 clips?'), findsOneWidget);
      await _tap(tester, find.text('Cancel'));
      expect(rig.editor.state.history.canUndo, isFalse);
      await _tap(tester, _key('relink-more-md_1'));
      await _tap(tester, find.text('Remove clips that use it'));
      await _tap(tester, find.text('Remove clips'));
      expect(rig.editor.session.historyEntries, hasLength(1));
      expect(find.text('Removed 2 clips'), findsOneWidget);
    });

    testWidgets('Replace with other media imports the pick and swaps the clips', (tester) async {
      final rig = await open(tester);
      rig.pool.importAssets['new.mov'] = videoAsset('md_new', name: 'new.mov', seconds: 10);
      rig.harness.engine.picker.nextPicks = [_pick('new.mov')];
      await _tap(tester, _key('relink-more-md_1'));
      await _tap(tester, find.text('From Gallery'));
      expect(rig.editor.state.history.undoLabel, 'Replace media');
      expect(find.text('Replaced 2 clips'), findsOneWidget);
    });

    testWidgets('a row without clips has no menu', (tester) async {
      final rig = _rig(_three());
      await _pumpHost(tester, rig);
      // md_1 is used once; drop its clip so it only sits in the pool.
      await tester.runAsync(() async {
        final clip = rig.editor.state.project!.tracks.expand((t) => t.items).whereType<MediaClip>().firstWhere((c) => c.media.value == 'md_1');
        rig.editor.apply(DeleteItems({clip.id}));
      });
      await _report(tester, rig, _missing(['md_1', 'md_2']));
      await _openSheet(tester);
      expect(find.text('Not used on the timeline'), findsOneWidget);
      expect(_key('relink-more-md_1'), findsNothing);
      expect(_key('relink-more-md_2'), findsOneWidget);
    });
  });
}
