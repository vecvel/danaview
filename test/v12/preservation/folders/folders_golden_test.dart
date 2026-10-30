// OWNER: HOM-08
//
// BUILD_PLAN HOM-08 acceptance ("goldens as HOM-06"): the 1.1 Folders section (P-5: header, the
// device storage root and user-added folder rows) is pixel-equal between DANAVIEW_FILES_HOME off,
// the `Home` tab with it on (rows only: its header has "See all", DESIGN_SYSTEM §10.3), the Folders
// screen's 1.1 fallback, and HOM-18's real Folders body on that screen (rows only: it titles the
// group "Linked folders", HOM plan §5.2), and the folder screen (breadcrumbs, Play all, Shuffle,
// naturally sorted rows) is pixel-equal with the flag off and on, at three widths.
//
// The goldens in goldens/ are written from the flag-off runs only:
//   flutter test test/v12/preservation/folders/folders_golden_test.dart --update-goldens --plain-name "flag off:"
// and then the whole file must pass without --update-goldens. Each flag-on test also compares
// against the flag-off capture taken in the same test, so equality holds while goldens refresh.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:danaview_features/danaview_features.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../library_test_utils.dart';
import 'folders_support.dart';

const _widths = [320.0, 402.0, 1280.0];

/// Length of the size prefix [_pixels] writes.
const _sizeBytes = 16;

TestSurface _surface(double width) => TestSurface(Size(width, 2400), 1.0, padding: const EdgeInsets.only(top: 20));

/// The pixels of [finder]'s own box. [captureImage] draws the whole nearest repaint boundary,
/// and that boundary differs between hosts (the 1.1 list gives every row group its own; HOM-18's
/// Folders tab is one sliver list), so the capture is cropped to the widget's rect. Where the
/// boundary is the widget itself (the 1.1 Home) the crop is the identity.
Future<ui.Image> _capture(WidgetTester tester, Finder finder) async {
  final element = tester.element(finder);
  final target = element.renderObject! as RenderBox;
  var boundary = target as RenderObject;
  while (!boundary.isRepaintBoundary) {
    boundary = boundary.parent!;
  }
  final full = (await tester.runAsync(() => captureImage(element)))!;
  final scale = full.width / boundary.paintBounds.width;
  final origin =
      MatrixUtils.transformPoint(target.getTransformTo(boundary), Offset.zero) - boundary.paintBounds.topLeft;
  final left = (origin.dx * scale).round();
  final top = (origin.dy * scale).round();
  final w = (target.size.width * scale).round();
  final h = (target.size.height * scale).round();
  if (left == 0 && top == 0 && w == full.width && h == full.height) return full;
  // A byte copy at whole pixels: resampling would blur edges and break pixel equality.
  final cropped = (await tester.runAsync(() async {
    final bytes = (await full.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    final out = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      final from = ((top + y) * full.width + left) * 4;
      out.setRange(y * w * 4, (y + 1) * w * 4, bytes, from);
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(out, w, h, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }))!;
  full.dispose();
  return cropped;
}

/// [image]'s raw pixels after a [_sizeBytes]-byte size prefix, so different sizes never compare
/// equal.
Future<Uint8List> _pixels(WidgetTester tester, ui.Image image) async {
  final bytes = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
  return Uint8List.fromList(
      [...'${image.width}x${image.height}'.padRight(_sizeBytes).codeUnits, ...bytes.buffer.asUint8List()]);
}

/// [on] equals [off] (both from [_pixels]): same size, every opaque pixel identical, and a
/// partly transparent (antialiased edge) pixel off by at most 1 per channel. A widget drawn in a
/// shared layer rounds its edge blend once more than one drawn in its own layer; nothing else
/// may differ.
void _expectSameRows(Uint8List on, Uint8List off, {required String reason}) {
  expect(on.length, off.length, reason: '$reason (size)');
  const header = _sizeBytes;
  expect(on.sublist(0, header), off.sublist(0, header), reason: '$reason (size)');
  var edges = 0;
  for (var i = header; i < on.length; i += 4) {
    final same = on[i] == off[i] && on[i + 1] == off[i + 1] && on[i + 2] == off[i + 2] && on[i + 3] == off[i + 3];
    if (same) continue;
    final edge =
        on[i + 3] == off[i + 3] && off[i + 3] < 255 && [0, 1, 2].every((c) => (on[i + c] - off[i + c]).abs() <= 1);
    expect(edge, isTrue, reason: '$reason (pixel ${(i - header) ~/ 4})');
    edges++;
  }
  // A handful of corner pixels at most; a real change moves far more.
  expect(edges, lessThan(16), reason: '$reason (edge pixels)');
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
    // HOM-18's Folders tab titles the group "Linked folders" (HOM plan §5.2), and the Files Home's
    // `Home` tab puts "See all" (the Folders screen) in the header (DESIGN_SYSTEM §10.3), so only
    // their rows must match; the other hosts draw the 1.1 "Folders" header pixel-equal.
    if (host != FoldersHost.linkedFolders && host != FoldersHost.homeTab) 'folders_header': foldersHeader(host),
    'folders_rows': foldersGroup(host, '/Volumes/Media/Movies'),
  };
  await scrollToFolders(tester, host, foldersHeader(host));
  expect(
    find.descendant(of: foldersHeader(host), matching: find.text(host.headerTitle)),
    findsOneWidget,
    reason: host.label,
  );
  if (host == FoldersHost.homeTab) {
    expect(find.descendant(of: foldersHeader(host), matching: find.text('See all')), findsOneWidget);
  }
  final pixels = <String, Uint8List>{};
  for (final MapEntry(key: name, value: finder) in sections.entries) {
    await scrollToFolders(tester, host, finder);
    expect(finder, findsOneWidget, reason: name);
    final image = await _capture(tester, finder);
    pixels[name] = await _pixels(tester, image);
    // HOM-18's rows share the page's layer, so they are checked against the flag-off capture
    // (which matches the golden) with [_expectSameRows] instead of the golden file itself.
    if (host != FoldersHost.linkedFolders) {
      await expectLater(image, matchesGoldenFile('goldens/${name}_${width.toInt()}.png'));
    }
    image.dispose();
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
  final image = await _capture(tester, screen);
  final pixels = await _pixels(tester, image);
  await expectLater(image, matchesGoldenFile('goldens/folder_screen_${width.toInt()}.png'));
  image.dispose();
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

    for (final host in [FoldersHost.homeTab, FoldersHost.foldersScreen, FoldersHost.linkedFolders]) {
      testWidgets('${host.label}: the Folders section is pixel-equal to flag off at ${width.toInt()} px',
          (tester) async {
        final off = await _captureHome(tester, device, width, FoldersHost.flagOff);
        final on = await _captureHome(tester, device, width, host);
        for (final name in on.keys) {
          if (host == FoldersHost.linkedFolders) {
            _expectSameRows(on[name]!, off[name]!, reason: '$name differs between flag off and ${host.label}');
          } else {
            expect(on[name], off[name], reason: '$name differs between flag off and ${host.label}');
          }
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
