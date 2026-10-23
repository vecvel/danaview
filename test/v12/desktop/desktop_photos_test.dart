// OWNER: HOM-03
//
// The desktop photo source, sidebar shortcuts and drop target (ARCH v1.2 V2-109): discovery and
// scans over real temporary trees, a pulled drive disappearing, dropped folders becoming roots,
// and the sidebar's layout matrix (280–1280 px × text scale 0.85–1.35), targets and semantics.

import 'dart:io';

import 'package:danaview_features/src/library/desktop/desktop_drop_target.dart';
import 'package:danaview_features/src/library/desktop/desktop_sidebar.dart';
import 'package:danaview_features/src/library/sources/desktop_photos_source.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Joins path parts with the host separator (the root package has no `path` dependency).
String _join(String a, [String? b, String? c, String? d]) =>
    [a, b, c, d].whereType<String>().join(Platform.pathSeparator);

void main() {
  group('desktopPlatformFor', () {
    test('desktop platforms only', () {
      expect(desktopPlatformFor(TargetPlatform.macOS, isWeb: false), DesktopPlatform.macos);
      expect(desktopPlatformFor(TargetPlatform.windows, isWeb: false), DesktopPlatform.windows);
      expect(desktopPlatformFor(TargetPlatform.linux, isWeb: false), DesktopPlatform.linux);
      expect(desktopPlatformFor(TargetPlatform.iOS, isWeb: false), isNull);
      expect(desktopPlatformFor(TargetPlatform.android, isWeb: false), isNull);
      expect(desktopPlatformFor(TargetPlatform.macOS, isWeb: true), isNull);
    });
  });

  group('DesktopPhotosController', () {
    late Directory tmp;
    late String base;
    late DesktopRootResolver resolver;

    void write(String rel, DateTime modified) {
      final f = File(_join(base, rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('x');
      f.setLastModifiedSync(modified);
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('hom03_feat_');
      base = tmp.resolveSymbolicLinksSync();
      write('home/Pictures/old.jpg', DateTime(2024));
      write('home/Pictures/new.png', DateTime(2026));
      write('home/Pictures/notes.txt', DateTime(2026));
      write('Volumes/Card/DCIM/IMG_1.JPG', DateTime(2025));
      resolver = DesktopRootResolver(
        platform: DesktopPlatform.macos,
        environment: {'HOME': _join(base, 'home')},
        volumeMountDirs: [_join(base, 'Volumes')],
      );
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('discovers Pictures and drives, scans them, lists photos newest first', () async {
      final c = DesktopPhotosController(resolver: resolver);
      addTearDown(c.dispose);
      await c.refresh();
      final s = c.state;
      expect(s.scanning, isFalse);
      expect(s.roots.map((r) => (r.root.kind, r.root.label)), [
        (DesktopRootKind.pictures, 'Pictures'),
        (DesktopRootKind.volume, 'Card'),
      ]);
      expect(s.roots.every((r) => r.scanned && r.available), isTrue);
      expect(s.photos.map((i) => i.name), ['new.png', 'IMG_1.JPG', 'old.jpg']);
      c.select(s.roots.last.root.id);
      expect(c.state.photos.map((i) => i.name), ['IMG_1.JPG']);
    });

    test('a pulled drive disappears on refresh without errors and its selection is cleared', () async {
      final c = DesktopPhotosController(resolver: resolver);
      addTearDown(c.dispose);
      await c.refresh();
      c.select(c.state.rootsOf(DesktopRootKind.volume).single.root.id);
      Directory(_join(base, 'Volumes', 'Card')).deleteSync(recursive: true);
      await c.refresh();
      expect(c.state.rootsOf(DesktopRootKind.volume), isEmpty);
      expect(c.state.selectedRootId, isNull);
      expect(c.state.photos.map((i) => i.name), ['new.png', 'old.jpg']);
    });

    test('dropped folders become roots once; removing one drops its photos', () async {
      write('extra/a/shot.heic', DateTime(2023));
      final c = DesktopPhotosController(resolver: resolver);
      addTearDown(c.dispose);
      await c.refresh();
      expect(await c.addFolder(_join(base, 'extra')), isTrue);
      expect(await c.addFolder(_join(base, 'extra')), isFalse, reason: 'already a root');
      expect(await c.addFolder(_join(base, 'missing')), isFalse);
      expect(await c.addFolder(_join(base, 'home', 'Pictures', 'new.png')), isFalse, reason: 'a file is not a folder');
      final added = c.state.rootsOf(DesktopRootKind.custom).single;
      expect(added.root.label, 'extra');
      expect(added.photos.single.name, 'shot.heic');
      await c.refresh();
      expect(c.state.rootsOf(DesktopRootKind.custom), hasLength(1), reason: 'kept across refreshes');
      await c.removeFolder(added.root.id);
      expect(c.state.rootsOf(DesktopRootKind.custom), isEmpty);
      expect(c.state.photos.map((i) => i.name), isNot(contains('shot.heic')));
    });

    test('overlapping refreshes fold into one more run', () async {
      final c = DesktopPhotosController(resolver: resolver);
      addTearDown(c.dispose);
      await Future.wait([c.refresh(), c.refresh(), c.refresh()]);
      expect(c.state.roots, hasLength(2));
      expect(c.state.scanning, isFalse);
    });

    test('no resolver (iOS, Android): stays empty', () async {
      final c = DesktopPhotosController(resolver: null);
      addTearDown(c.dispose);
      await c.refresh();
      expect(c.state.roots, isEmpty);
      expect(await c.addFolder(base), isFalse);
    });
  });

  group('drop target', () {
    test('splitDroppedPaths separates folders from files; errors count as files', () async {
      final split = await splitDroppedPaths(
        ['/a', '/b.jpg', '/boom'],
        isDirectory: (path) async => path == '/boom' ? throw const FileSystemException('x') : path == '/a',
      );
      expect(split.folders, ['/a']);
      expect(split.files, ['/b.jpg', '/boom']);
    });

    testWidgets('a drop hands folders and files to their callbacks', (tester) async {
      final folders = <String>[];
      final files = <String>[];
      final key = GlobalKey<DesktopFolderDropTargetState>();
      await tester.pumpWidget(_app(DesktopFolderDropTarget(
        key: key,
        isDirectory: (path) async => !path.contains('.'),
        onDropFolders: (paths) async => folders.addAll(paths),
        onDropFiles: files.addAll,
        child: const SizedBox(width: 200, height: 200),
      )));
      await key.currentState!.handleDrop(['/x/folder', '/x/a.jpg']);
      expect(folders, ['/x/folder']);
      expect(files, ['/x/a.jpg']);
      expect(key.currentState!.dragging, isFalse);
    });
  });

  group('DesktopPhotoSidebar', () {
    testWidgets('shortcuts select roots, carry semantics labels and are at least 44 px tall', (tester) async {
      final semantics = tester.ensureSemantics();
      String? selected = 'none';
      final state = _state();
      await tester.pumpWidget(_app(DesktopPhotoSidebar(state: state, onSelect: (id) => selected = id)));
      expect(find.bySemanticsLabel('All photos\n3 photos'), findsOneWidget);
      expect(find.bySemanticsLabel('Pictures\n2 photos'), findsOneWidget);
      expect(find.bySemanticsLabel('A very long external drive name for layout checks\n1 photo'), findsOneWidget);
      expect(find.bySemanticsLabel('Gone\nNot available'), findsOneWidget);
      expect(find.bySemanticsLabel('Trips with a long folder name too\nScanning…'), findsOneWidget);
      expect(find.bySemanticsLabel('Photo locations'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('desktop-root-${state.roots.first.root.id}')));
      expect(selected, state.roots.first.root.id);
      await tester.tap(find.byKey(const ValueKey('desktop-root-all')));
      expect(selected, isNull);
      for (final tile in tester.widgetList(find.byType(DanaviewListTile))) {
        expect(tester.getSize(find.byWidget(tile)).height, greaterThanOrEqualTo(44));
      }
      semantics.dispose();
    });

    testWidgets('no drives: a hint; added folders offer Remove', (tester) async {
      String? removed;
      final custom = DesktopRoot.at(DesktopRootKind.custom, '/x/Trips', label: 'Trips');
      final state = DesktopPhotosState(roots: [DesktopRootStatus(root: custom, scanned: true)]);
      await tester.pumpWidget(_app(DesktopPhotoSidebar(state: state, onSelect: (_) {}, onRemove: (id) => removed = id)));
      expect(find.byKey(const ValueKey('desktop-no-drives')), findsOneWidget);
      final remove = find.byKey(ValueKey('desktop-remove-${custom.id}'));
      expect(tester.getSize(remove).height, greaterThanOrEqualTo(44));
      await tester.tap(remove);
      expect(removed, custom.id);
    });

    for (final width in const [280.0, 320.0, 375.0, 768.0, 1024.0, 1280.0]) {
      for (final scale in const [0.85, 1.0, 1.35]) {
        testWidgets('no overflow at ${width.toInt()} px × $scale', (tester) async {
          tester.view.physicalSize = Size(width, 700);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          // The sidebar is a column of its own width on desktop; at phone widths it fills the pane.
          final sidebarWidth = width >= 768 ? 260.0 : width;
          await tester.pumpWidget(_app(
            Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: sidebarWidth, height: 700, child: DesktopPhotoSidebar(state: _state(), onSelect: (_) {}, onRemove: (_) {})),
            ),
            textScale: scale,
          ));
          await tester.pump();
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}

DesktopPhotosState _state() {
  PhotoMediaItem photo(String root, String name, int year) => PhotoMediaItem(
        id: LinkedItemId.of(root, name),
        uri: '/x/$name',
        name: name,
        modifiedAt: DateTime(year),
        mimeType: 'image/jpeg',
      );
  final pictures = DesktopRoot.at(DesktopRootKind.pictures, '/Users/a/Pictures', label: 'Pictures');
  final drive = DesktopRoot.at(DesktopRootKind.volume, '/Volumes/Long', label: 'A very long external drive name for layout checks');
  final gone = DesktopRoot.at(DesktopRootKind.volume, '/Volumes/Gone', label: 'Gone');
  final added = DesktopRoot.at(DesktopRootKind.custom, '/x/Trips', label: 'Trips with a long folder name too');
  return DesktopPhotosState(roots: [
    DesktopRootStatus(root: pictures, scanned: true, items: [photo(pictures.id, 'a.jpg', 2024), photo(pictures.id, 'b.jpg', 2025)]),
    DesktopRootStatus(root: drive, scanned: true, items: [photo(drive.id, 'c.jpg', 2023)]),
    DesktopRootStatus(root: gone, scanned: true, available: false),
    DesktopRootStatus(root: added),
  ]);
}

Widget _app(Widget child, {double textScale = 1.0}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: DanaviewTheme.darkTheme.copyWith(platform: TargetPlatform.macOS),
      builder: (context, c) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: c!,
      ),
      home: ColoredBox(color: DanaviewColors.background, child: child),
    );
