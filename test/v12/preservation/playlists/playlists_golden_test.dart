// OWNER: HOM-07
//
// BUILD_PLAN HOM-07 acceptance ("goldens as HOM-06"): the add-to-playlist sheet and the playlist
// screen are pixel-equal between DANAVIEW_FILES_HOME off and the flag on (the `Home` tab for the
// sheet), at three widths; the 1.1 Playlists section (header, rows) matches its goldens with the
// flag off.
//
// Since the Cinema B Home (DESIGN_SYSTEM §10.3) the Home hides an empty Playlists section and, on
// wide screens, puts the grouped lists in a right-hand column. Since the four-tab Home (§10.2–10.4)
// the flag-on Home tab has no Playlists section: the playlists live on the Playlists screen (the
// Videos tab's See all; full width, with the empty state), which has goldens of its own
// (`playlists_screen_*`: its top bar with New, the card grid and the empty state).
//
// The goldens in goldens/ are written with:
//   flutter test test/v12/preservation/playlists/playlists_golden_test.dart --update-goldens
// and then the whole file must pass without --update-goldens. The flag-on tests also compare the
// raw pixels with a flag-off capture made in the same test, so the equality holds even while the
// goldens are being refreshed.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:danaview_features/danaview_features.dart' show HomeMediaCard;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../library_test_utils.dart';
import 'playlists_support.dart';

const _widths = [320.0, 402.0, 1280.0];

TestSurface _surface(double width) => TestSurface(Size(width, 2400), 1.0, padding: const EdgeInsets.only(top: 20));

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

Future<Uint8List> _check(WidgetTester tester, Finder finder, String golden) async {
  expect(finder, findsOneWidget, reason: golden);
  final pixels = await _pixels(tester, finder);
  await expectLater(finder, matchesGoldenFile('goldens/$golden.png'));
  return pixels;
}

Finder get _sheet => find.byWidgetPredicate((w) => w.runtimeType.toString() == '_DanaviewAddToPlaylistSheet');

/// The Playlists section in [host]: header and rows over the seeded library; then, over an empty
/// one, the header and empty state on the Playlists tab (the Home hides the empty section).
Future<Map<String, Uint8List>> _captureSection(WidgetTester tester, Directory tree, double width, PlaylistsHost host) async {
  final w = width.toInt();
  final prefix = host == PlaylistsHost.playlistsScreen ? 'playlists_screen' : 'playlists';
  var env = await pumpPlaylistsHome(tester, host: host, tree: tree, surface: _surface(width));
  final pixels = <String, Uint8List>{
    'playlists_header': await _check(tester, playlistsHeader(host), '${prefix}_header_$w'),
    'playlists_rows': await _check(tester, playlistsGroup(host), '${prefix}_rows_$w'),
  };
  expect(tester.takeException(), isNull);
  await finishHome(tester, env);

  env = await pumpPlaylistsHome(tester, host: host, tree: tree, surface: _surface(width), seed: false);
  if (host == PlaylistsHost.playlistsScreen) {
    pixels['playlists_empty_header'] = await _check(tester, playlistsHeader(host), '${prefix}_empty_header_$w');
    pixels['playlists_empty'] = await _check(tester, playlistsEmpty(host), '${prefix}_empty_$w');
  } else {
    expect(inHost(host, find.text('No playlists yet')), findsNothing, reason: 'the Home hides an empty section');
  }
  expect(tester.takeException(), isNull);
  await finishHome(tester, env);
  return pixels;
}

/// The add-to-playlist sheet opened from the first Continue watching row in [host].
Future<Uint8List> _captureSheet(WidgetTester tester, Directory tree, double width, PlaylistsHost host) async {
  final env = await pumpPlaylistsHome(tester, host: host, tree: tree, surface: _surface(width));
  await tester.tap(inHost(
    host,
    find.descendant(
      of: find.ancestor(of: find.text('Day 1 - Leaving Town.mp4'), matching: find.byType(HomeMediaCard)).first,
      matching: find.byTooltip('More'),
    ),
  ));
  await pumpFrames(tester);
  await tester.tap(find.text('Add to playlist…'));
  await pumpFrames(tester, count: 10);
  final pixels = await _check(tester, _sheet, 'add_to_playlist_sheet_${width.toInt()}');
  expect(tester.takeException(), isNull);
  await finishHome(tester, env);
  return pixels;
}

/// The playlist screen of `Road Trip` with DANAVIEW_FILES_HOME = [filesHome].
Future<Uint8List> _captureScreen(WidgetTester tester, Directory tree, double width, {required bool filesHome}) async {
  final env = await pumpPlaylistScreen(tester, filesHome: filesHome, tree: tree, surface: _surface(width));
  final pixels = await _check(tester, find.byType(Scaffold), 'playlist_screen_${width.toInt()}');
  expect(tester.takeException(), isNull);
  await finishHome(tester, env);
  return pixels;
}

void main() {
  late Directory tree;

  setUpAll(() => tree = createPlaylistTree());
  tearDownAll(() => tree.deleteSync(recursive: true));

  for (final width in _widths) {
    final w = width.toInt();

    testWidgets('flag off: the Playlists section matches the 1.1 goldens at $w px', (tester) async {
      await _captureSection(tester, tree, width, PlaylistsHost.flagOff);
    });

    testWidgets('flag off: the add-to-playlist sheet matches the 1.1 golden at $w px', (tester) async {
      await _captureSheet(tester, tree, width, PlaylistsHost.flagOff);
    });

    testWidgets('flag off: the playlist screen matches the 1.1 golden at $w px', (tester) async {
      await _captureScreen(tester, tree, width, filesHome: false);
    });

    testWidgets('flag on: the Home tab has no Playlists section (they moved to the Playlists screen) at $w px',
        (tester) async {
      final env = await pumpPlaylistsHome(tester, host: PlaylistsHost.homeTab, tree: tree, surface: _surface(width));
      expect(inHost(PlaylistsHost.homeTab, find.text('Playlists')), findsNothing);
      expect(inHost(PlaylistsHost.homeTab, find.byKey(const ValueKey('home-playlists'))), findsNothing);
      await finishHome(tester, env);
    });

    testWidgets('flag on: the Playlists screen matches its goldens at $w px', (tester) async {
      await _captureSection(tester, tree, width, PlaylistsHost.playlistsScreen);
    });

    testWidgets('flag on: the add-to-playlist sheet is pixel-equal to flag off at $w px', (tester) async {
      final off = await _captureSheet(tester, tree, width, PlaylistsHost.flagOff);
      final on = await _captureSheet(tester, tree, width, PlaylistsHost.homeTab);
      expect(on, off);
    });

    testWidgets('flag on: the playlist screen is pixel-equal to flag off at $w px', (tester) async {
      final off = await _captureScreen(tester, tree, width, filesHome: false);
      final on = await _captureScreen(tester, tree, width, filesHome: true);
      expect(on, off);
    });
  }
}
