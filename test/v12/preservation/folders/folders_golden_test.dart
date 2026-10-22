// OWNER: HOM-08
//
// BUILD_PLAN HOM-08 acceptance ("goldens as HOM-06"): the 1.1 Folders section (P-5: header, the
// device storage root and user-added folder rows) is pixel-equal between DANAVIEW_FILES_HOME off,
// the `Home` tab with it on and the `Folders` tab with it on (rows only: that tab titles the group
// "Linked folders", HOM plan §5.2), and the folder screen (breadcrumbs, Play all, Shuffle,
// naturally sorted rows) is pixel-equal with the flag off and on, at three widths.
//
// The goldens in goldens/ are written from the flag-off runs only:
//   flutter test test/v12/preservation/folders/folders_golden_test.dart --update-goldens --plain-name "flag off:"
// and then the whole file must pass without --update-goldens. Each flag-on test also compares
// against the flag-off capture taken in the same test, so equality holds while goldens refresh.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:danaview_features/danaview_features.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../library_test_utils.dart';
import 'folders_support.dart';

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

/// The Home's Folders section for [host] at [width]; returns its raw pixels per section.
Future<Map<String, Uint8List>> _captureHome(
  WidgetTester tester,
  Directory device,
  double width,
  FoldersHost host,
) async {
  final env = await createFoldersEnv(device: device);
  await seedGoldenRoots(env);
  await pumpFoldersHome(tester, env, host: host, surface: _surface(width));
  final sections = <String, Finder>{
    // The Folders tab titles the group "Linked folders" (HOM-18), so only its rows must match.
    if (host != FoldersHost.foldersTab) 'folders_header': foldersHeader(host),
    'folders_rows': foldersGroup(host, '/Volumes/Media/Movies'),
  };
  final pixels = <String, Uint8List>{};
  for (final MapEntry(key: name, value: finder) in sections.entries) {
    await scrollToFolders(tester, host, finder);
    expect(finder, findsOneWidget, reason: name);
    pixels[name] = await _pixels(tester, finder);
    await expectLater(finder, matchesGoldenFile('goldens/${name}_${width.toInt()}.png'));
  }
  expect(tester.takeException(), isNull);
  await finishHome(tester, env);
  return pixels;
}

/// The folder screen on `Disc 2` at [width]; returns its raw pixels.
Future<Uint8List> _captureFolder(WidgetTester tester, Directory tree, double width, {required bool filesHome}) async {
  final env = await createFoldersEnv();
  await seedFolderRoots(env, tree);
  await pumpFolderScreen(
    tester,
    env,
    filesHome: filesHome,
    path: joinPath([tree.path, 'Disc 2']),
    log: FolderScreenLog(),
    surface: _surface(width),
    platform: width >= 1000 ? TargetPlatform.macOS : TargetPlatform.iOS,
  );
  final screen = find.byType(DanaviewFolderScreen);
  final pixels = await _pixels(tester, screen);
  await expectLater(screen, matchesGoldenFile('goldens/folder_screen_${width.toInt()}.png'));
  expect(tester.takeException(), isNull);
  await finishHome(tester, env);
  return pixels;
}

void main() {
  late Directory tree;
  late Directory device;

  setUpAll(() {
    tree = createFolderTree();
    device = createDeviceFolder();
  });
  tearDownAll(() {
    tree.deleteSync(recursive: true);
    device.deleteSync(recursive: true);
  });

  for (final width in _widths) {
    testWidgets('flag off: the Folders section matches the 1.1 goldens at ${width.toInt()} px', (tester) async {
      await _captureHome(tester, device, width, FoldersHost.flagOff);
    });

    testWidgets('flag off: the folder screen matches the 1.1 golden at ${width.toInt()} px', (tester) async {
      await _captureFolder(tester, tree, width, filesHome: false);
    });

    for (final host in [FoldersHost.homeTab, FoldersHost.foldersTab]) {
      testWidgets('${host.label}: the Folders section is pixel-equal to flag off at ${width.toInt()} px', (tester) async {
        final off = await _captureHome(tester, device, width, FoldersHost.flagOff);
        final on = await _captureHome(tester, device, width, host);
        for (final name in on.keys) {
          expect(on[name], off[name], reason: '$name differs between flag off and ${host.label}');
        }
      });
    }

    testWidgets('flag on: the folder screen is pixel-equal to flag off at ${width.toInt()} px', (tester) async {
      final off = await _captureFolder(tester, tree, width, filesHome: false);
      final on = await _captureFolder(tester, tree, width, filesHome: true);
      expect(on, off, reason: 'the folder screen differs between flag off and on');
    });
  }
}
