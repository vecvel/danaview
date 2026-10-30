// OWNER: HOM-06
//
// BUILD_PLAN HOM-06 acceptance: the hub sections (P-1 Now Playing card, P-2 Continue watching
// header, cards collapsed and expanded, Show all / Show less, and P-3 the quick actions of the
// empty Home's empty state) are pixel-equal between DANAVIEW_FILES_HOME off and the `Home` tab
// with it on, at three widths.
//
// The flag-off run matches the golden file per section and width (each golden is the section's
// whole paint layer, so it also holds the 1.1 Playlists section below the hub). Since the
// four-tab Home (DESIGN_SYSTEM §10.3) the flag-on Home tab has no Playlists section, so the two
// layouts are compared section by section: each section's own rectangle, cropped from its layer.
// The flag-on Home gets a stand-in Documents section so that, as with the 1.1 Playlists, the
// grouped-lists column exists and the hub keeps the same column width at 1280 px. The goldens in
// goldens/ are written from the flag-off run only:
//   flutter test test/v12/preservation/hub/hub_golden_test.dart --update-goldens
// and then the whole file must pass without --update-goldens. Each test also compares the two
// layouts directly (captured in the same test), so the equality holds even while goldens are
// being refreshed.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:danaview_features/danaview_features.dart' show HomeTabSlots;
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
        'continue_watching_header': continueWatchingHeader,
        'continue_watching_rows': continueWatchingRows,
        'show_all': showAllButton,
      };

/// The raw pixels of [finder]'s own rectangle, cropped from the layer `captureImage` renders.
Future<Uint8List> _pixels(WidgetTester tester, Finder finder) async {
  final element = tester.element(finder);
  final box = element.renderObject! as RenderBox;
  RenderObject boundary = box;
  while (!boundary.isRepaintBoundary) {
    boundary = boundary.parent!;
  }
  final bounds = boundary.paintBounds;
  final topLeft = MatrixUtils.transformPoint(box.getTransformTo(boundary), Offset.zero) - bounds.topLeft;
  final image = await tester.runAsync(() async {
    final image = await captureImage(element);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final scale = image.width / bounds.width;
    final result = (image.width, image.height, scale, bytes!.buffer.asUint8List());
    image.dispose();
    return result;
  });
  final (width, height, scale, bytes) = image!;
  final left = (topLeft.dx * scale).round();
  final top = (topLeft.dy * scale).round();
  final w = (box.size.width * scale).round();
  final h = (box.size.height * scale).round();
  expect(left >= 0 && top >= 0 && left + w <= width && top + h <= height, isTrue, reason: 'crop inside the layer');
  final out = BytesBuilder(copy: false);
  for (var y = top; y < top + h; y++) {
    out.add(bytes.sublist((y * width + left) * 4, (y * width + left + w) * 4));
  }
  // Prefix the size so different sizes never compare equal by accident.
  return Uint8List.fromList([...'${w}x$h'.codeUnits, ...out.takeBytes()]);
}

/// The flag-on Home's stand-in Documents section (the grouped-lists column's content).
final HomeTabSlots _filesHomeSlots =
    HomeTabSlots(documentsOverview: (_) => const SizedBox(key: ValueKey('documents-probe'), height: 120));

/// Pumps the Home with [filesHome], captures every section (collapsed, then expanded) and, with
/// the flag off, checks each against its golden; returns the raw pixels per section.
Future<Map<String, Uint8List>> _capture(WidgetTester tester, Directory tree, double width, {required bool filesHome}) async {
  final env = await pumpHub(
    tester,
    filesHome: filesHome,
    tree: tree,
    surface: _surface(width),
    tabSlots: filesHome ? _filesHomeSlots : HomeTabSlots.none,
  );
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
      if (!filesHome) await expectLater(finder, matchesGoldenFile('goldens/${name}_${width.toInt()}.png'));
    }
  }
  expect(tester.takeException(), isNull);
  await finishHome(tester, env);

  // P-3: the quick actions in the empty Home's one empty state.
  // (No stand-in here: the 1.1 empty Home has no lists column either.)
  final empty = await pumpHub(tester, filesHome: filesHome, tree: tree, surface: _surface(width), seed: false);
  expect(homeEmptyState, findsOneWidget);
  expect(find.descendant(of: homeEmptyState, matching: quickActions), findsOneWidget);
  pixels['empty_state'] = await _pixels(tester, homeEmptyState);
  if (!filesHome) await expectLater(homeEmptyState, matchesGoldenFile('goldens/empty_state_${width.toInt()}.png'));
  expect(tester.takeException(), isNull);
  await finishHome(tester, empty);
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
