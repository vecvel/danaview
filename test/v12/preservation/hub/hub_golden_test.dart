// OWNER: HOM-06
//
// BUILD_PLAN HOM-06 acceptance: the hub sections (P-1 Now Playing card, P-3 quick actions, P-2
// Continue watching header, rows collapsed and expanded, Show all / Show less) are pixel-equal
// between DANAVIEW_FILES_HOME off and the `Home` tab with it on, at three widths.
//
// Both flag values match the same golden file per section and width. The goldens in goldens/
// are written from the flag-off run only:
//   flutter test test/v12/preservation/hub/hub_golden_test.dart --update-goldens --plain-name "flag off"
// and then the whole file must pass without --update-goldens. Each test also compares the two
// layouts directly (captured in the same test), so the equality holds even while goldens are
// being refreshed.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../library_test_utils.dart';
import 'hub_support.dart';

const _widths = [320.0, 402.0, 1280.0];

TestSurface _surface(double width) => TestSurface(Size(width, 2400), 1.0, padding: const EdgeInsets.only(top: 20));

/// The hub sections in capture order, each with its golden name.
Map<String, Finder> _sections({required bool expanded}) => expanded
    ? {'continue_watching_expanded': continueWatchingRows, 'show_less': showAllButton}
    : {
        'now_playing': nowPlayingCard,
        'quick_actions': quickActions,
        'continue_watching_header': continueWatchingHeader,
        'continue_watching_rows': continueWatchingRows,
        'show_all': showAllButton,
      };

Future<Uint8List> _pixels(WidgetTester tester, Finder finder) async {
  final image = await tester.runAsync(() async {
    final image = await captureImage(tester.element(finder));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final size = '${image.width}x${image.height}';
    image.dispose();
    return (size, bytes!.buffer.asUint8List());
  });
  // Prefix the size so different sizes never compare equal by accident.
  return Uint8List.fromList([...image!.$1.codeUnits, ...image.$2]);
}

/// Pumps the Home with [filesHome], captures every section (collapsed, then expanded) and checks
/// each against its golden; returns the raw pixels per section.
Future<Map<String, Uint8List>> _capture(WidgetTester tester, Directory tree, double width, {required bool filesHome}) async {
  final env = await pumpHub(tester, filesHome: filesHome, tree: tree, surface: _surface(width));
  await startPlaying(tester, hubStream);
  final pixels = <String, Uint8List>{};
  for (final expanded in [false, true]) {
    if (expanded) {
      await tester.tap(find.text('Show all 10'));
      await pumpFrames(tester);
    }
    for (final MapEntry(key: name, value: finder) in _sections(expanded: expanded).entries) {
      expect(finder, findsOneWidget, reason: name);
      pixels[name] = await _pixels(tester, finder);
      await expectLater(finder, matchesGoldenFile('goldens/${name}_${width.toInt()}.png'));
    }
  }
  expect(tester.takeException(), isNull);
  await finishHome(tester, env);
  return pixels;
}

void main() {
  late Directory tree;

  setUpAll(() => tree = createHubTree());
  tearDownAll(() => tree.deleteSync(recursive: true));

  for (final width in _widths) {
    testWidgets('flag off: hub sections match the 1.1 goldens at ${width.toInt()} px', (tester) async {
      await _capture(tester, tree, width, filesHome: false);
    });

    testWidgets('flag on: the Home tab hub is pixel-equal to flag off at ${width.toInt()} px', (tester) async {
      final off = await _capture(tester, tree, width, filesHome: false);
      final on = await _capture(tester, tree, width, filesHome: true);
      expect(on.keys, off.keys);
      for (final name in off.keys) {
        expect(on[name], off[name], reason: '$name differs between flag off and the Home tab');
      }
    });
  }
}
