// OWNER: S2-Q
//
// Slice S2 E2E (BUILD_PLAN v1.2 §1A, S2-Q; the S2 share of the N1 exit criterion and of QA-101
// scenario 1): with DANAVIEW_FILES_HOME=true, on the real app router and the real S2 wiring
// (`filesHomeOverrides`: HOM-17 library under Application Support, HOM-04 thumbnails, HOM-20 import
// service, HOM-22 file actions) on the iOS Simulator:
//
//   1. the Home shows the S2 tabs (no Documents tab until S3);
//   2. nested Danaview folders are created in the Folders tab (Trips › Japan);
//   3. a photo (JPEG with EXIF) is imported "From Photos" into Japan and a video "From Files" into
//      Imported, then moved to Trips with the All tab's Move to…; the originals are unchanged and
//      the staged copies are gone;
//   4. the photo opens in the photo viewer with its EXIF (File info) and is shared from there; the
//      video opens in the player and plays;
//   5. save out (Save to Files) and Save to Photos from the selection bar;
//   6. both are deleted (All tab), Recently deleted lists them, the photo is restored to Japan;
//   7. the library is closed and reopened (an app restart of the store): folders, entries and the
//      still-deleted video persist; the video is restored to Trips; the store invariants hold.
//
// Local test media only: integration_test/v12/s2/tool/make_s2_media.sh writes them on the host and
// the simulator reads them in place (`--dart-define=DV_S2_MEDIA=<dir>`). System UI that a Flutter
// integration test can't drive (PHPicker, UIDocumentPicker, the share sheet) is replaced at the app's
// own seams: the picker override stages copies exactly as the native picker does (app-owned staging
// directory, `stagedCopy`), and the file-out port records what the app hands to the share sheet and
// Save to Files (and, with `DV_S2_REAL_PHOTOS=true` after `simctl privacy grant photos-add`, Save to
// Photos goes through the real NativeFileOut). Taps are 0.1 s (E2eApp.tap); waits poll with deadlines.
//
// Run: DV_E2E_EXTRA_DEFINES="DANAVIEW_FILES_HOME=true DV_S2_MEDIA=$PWD/build/e2e/s2_media" \
//        scripts/ci/editor/e2e_ios.sh --target integration_test/v12/s2/s2_files_home_test.dart iphone

// ignore_for_file: avoid_print, implementation_imports, depend_on_referenced_packages

import 'dart:io';

import 'package:danaview/app.dart';
import 'package:danaview/main.dart' show editorAppOverrides;
import 'package:danaview/wiring/files_home_wiring.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor_engine/danaview_editor_engine.dart';
import 'package:danaview_engine/danaview_engine.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_features/src/library/file_actions/file_actions.dart';
import 'package:danaview_features/src/library/import/import_pickers.dart';
import 'package:danaview_features/src/library/import/import_providers.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_platform/danaview_platform.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../editor/support/e2e.dart';

const String _mediaDir = String.fromEnvironment('DV_S2_MEDIA');
const bool _realPhotos = bool.fromEnvironment('DV_S2_REAL_PHOTOS');
const String _photoName = 's2_photo.jpg';
const String _videoName = 's2_clip.mp4';

void _report(String line) => print('DV_E2E_REPORT s2: $line');

/// Stages picks into the app's staging directory as the native pickers do (PHPicker and
/// UIDocumentPicker hand the app a copy there), so the import deletes only that copy.
final class _StagingPicker implements ImportPicker {
  _StagingPicker(this.staging);

  final String staging;
  final List<String> photos = [];
  final List<String> files = [];
  final List<String> staged = [];

  @override
  bool get canPickPhotos => true;

  @override
  Future<List<ImportSource>> pickPhotos() async => _stage(photos, SourceHint.photos);

  @override
  Future<List<ImportSource>> pickFiles() async => _stage(files, SourceHint.files);

  List<ImportSource> _stage(List<String> paths, SourceHint hint) {
    final out = <ImportSource>[];
    for (final p in paths) {
      final name = p.split('/').last;
      final dir = Directory('$staging/s2q-${DateTime.now().microsecondsSinceEpoch}')..createSync(recursive: true);
      final copy = File(p).copySync('${dir.path}/$name');
      staged.add(copy.path);
      out.add(ImportSource.file(copy.path,
          displayName: name, sizeBytes: copy.lengthSync(), modifiedAt: File(p).lastModifiedSync(), sourceHint: hint, stagedCopy: true));
    }
    paths.clear();
    return out;
  }
}

/// Records what the app hands to the share sheet and Save to Files (system UI); Save to Photos goes
/// through [real] when [_realPhotos].
final class _RecordingFileOut implements FileOutPort {
  _RecordingFileOut(this.real, this.outDir);

  final FileOutPort real;
  final String outDir;
  final List<OutFile> shared = [];
  final List<(OutFile, SaveOutTarget)> saved = [];

  @override
  FileOutCapabilities get capabilities => real.capabilities;

  void _keep(String sub, OutFile f) {
    final dir = Directory('$outDir/s2/$sub')..createSync(recursive: true);
    File(f.path).copySync('${dir.path}/${f.displayName}');
  }

  @override
  Future<SaveOutOutcome> saveOut(List<OutFile> files, SaveOutTarget target, {OutAnchor? anchor}) async {
    if (target == SaveOutTarget.photos && _realPhotos) {
      final r = await real.saveOut(files, target, anchor: anchor);
      for (final f in files) {
        saved.add((f, target));
      }
      return r;
    }
    for (final f in files) {
      saved.add((f, target));
      _keep('saved-${target.name}', f);
    }
    return SaveOutOutcome(cancelled: false, saved: files.length, failed: 0);
  }

  @override
  Future<ShareOutcome> share(List<OutFile> files, {String? subject, OutAnchor? anchor}) async {
    for (final f in files) {
      shared.add(f);
      _keep('shared', f);
    }
    return const ShareOutcome(completed: true);
  }

  @override
  Future<bool> openIn(OutFile file, {OutAnchor? anchor}) async => true;
}

final class _World {
  _World(this.prefs, this.player, this.editor, this.picker, this.out);

  final SharedPreferences prefs;
  final PlaybackEngine player;
  final List<Override> editor;
  final _StagingPicker picker;
  final _RecordingFileOut out;
  FilesHomeRuntime? runtime;

  LibraryStore get store => runtime!.store!;

  /// Opens the S2 wiring (as `lib/main.dart` does) and pumps the app at Home.
  Future<void> launch(WidgetTester tester) async {
    final r = runtime = await filesHomeOverrides(prefs: prefs);
    expect(r.store, isNotNull, reason: 'the library opened under Application Support');
    final dirs = await FilesHomeDirectories.resolve();
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        playbackEngineProvider.overrideWithValue(player),
        sessionRepositoryProvider.overrideWithValue(SessionRepository(prefs)),
        libraryRepositoryProvider.overrideWithValue(LibraryRepository(prefs)),
        ...editor,
        ...r.overrides,
        // The app's seams for system UI (see the file header); everything else is the real wiring.
        importPickerProvider.overrideWithValue(picker),
        importStagingDirectoryProvider.overrideWithValue(dirs.importStaging),
        fileOutPortProvider.overrideWithValue(out),
      ],
      child: const DanaviewApp(),
    ));
    await E2eApp.pumpUntil(tester, () => find.byType(DanaviewHomeScreen).evaluate().isNotEmpty, what: 'Home');
  }

  /// Closes the app and the library (the store's half of an app restart).
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await runtime?.dispose();
    runtime = null;
  }
}

Future<_World> _boot() async {
  if (!FeatureFlags.filesHomeEnabled) throw StateError('Build with --dart-define=DANAVIEW_FILES_HOME=true');
  if (_mediaDir.isEmpty) throw StateError('Pass --dart-define=DV_S2_MEDIA=<dir> (integration_test/v12/s2/tool/make_s2_media.sh)');
  IncomingMediaBridge.setLaunchArgs(const []);
  await PlatformBridge.initializeWindow();
  if (PlatformBridge.isMobile) await PlayerOrientation.applyAppDefault();
  final prefs = await SharedPreferences.getInstance();
  final player = MpvPlaybackEngine(subtitleFontAssets: DanaviewFonts.files);
  await player.initialize();
  var editor = EditorBootstrap.unavailable();
  if (EditorAvailability.platform is EditorSupported) {
    final roots = await EditorBootstrap.defaultRoots();
    final engine = MobileEditorEngine(config: EditorBootstrap.engineConfigOf(roots));
    final runtime = await EditorBootstrap.createRuntime(engine: engine, roots: roots, prefs: await EditorPrefs.load());
    editor = editorAppOverrides(runtime);
  }
  final dirs = await FilesHomeDirectories.resolve();
  final platform = Platform.isAndroid ? FileOutPlatform.android : FileOutPlatform.iOS;
  return _World(prefs, player, editor, _StagingPicker(dirs.importStaging), _RecordingFileOut(NativeFileOut(platform), E2eConfig.outDir));
}

Finder _key(String k) => find.byKey(ValueKey<String>(k));

Finder _folderRow(FolderId id) => _key('danaview-folder-${id.value}');

Finder _entryRow(EntryId id) => _key('library-entry-${id.value}');

Future<void> _tab(WidgetTester tester, HomeTab tab) async {
  await E2eApp.tap(tester, find.byKey(homeTabKey(tab)), what: '${tab.name} tab');
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _longPress(WidgetTester tester, Finder finder, {required String what}) async {
  final target = finder.first;
  await E2eApp.pumpUntil(tester, () => target.hitTestable().evaluate().isNotEmpty, what: what);
  final gesture = await tester.startGesture(tester.getCenter(target));
  await Future<void>.delayed(const Duration(milliseconds: 800));
  await tester.pump(const Duration(milliseconds: 800));
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 100));
}

/// Types [text] into the open prompt and confirms with [confirm].
Future<void> _prompt(WidgetTester tester, String text, String confirm) async {
  await E2eApp.pumpUntil(tester, () => find.byType(EditableText).hitTestable().evaluate().isNotEmpty, what: 'the name prompt');
  await tester.enterText(find.byType(EditableText).hitTestable().last, text);
  await tester.pump();
  await E2eApp.hideKeyboard(tester);
  await E2eApp.tap(tester, find.text(confirm).hitTestable().last, what: confirm);
}

/// Opens the More menu of [row] and picks [item].
Future<void> _menu(WidgetTester tester, Finder row, String item) async {
  await E2eApp.tap(tester, find.descendant(of: row, matching: find.byTooltip('More')).hitTestable(), what: 'More of $row');
  await E2eApp.tap(tester, find.text(item).hitTestable().last, what: 'menu $item');
}

Future<void> _dismissSheet(WidgetTester tester) async {
  final nav = tester.state<NavigatorState>(find.byType(Navigator).last);
  nav.maybePop();
  await tester.pump(const Duration(milliseconds: 500));
}

FileEntry? _entryNamed(LibraryStore store, String name) =>
    store.reader.allEntries(includeTrashed: true).where((e) => e.displayName == name).firstOrNull;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('S2: import, organise in nested folders, view, share and save out, delete and restore, reopen', (tester) async {
    final world = await _boot();
    final photoSrc = File('$_mediaDir/$_photoName');
    final videoSrc = File('$_mediaDir/$_videoName');
    expect(photoSrc.existsSync() && videoSrc.existsSync(), isTrue, reason: 'make_s2_media.sh output in $_mediaDir');
    final photoBytes = photoSrc.readAsBytesSync();
    final videoBytes = videoSrc.readAsBytesSync();
    final photoMtime = photoSrc.lastModifiedSync();
    final videoMtime = videoSrc.lastModifiedSync();

    // ---- 1. Home with the S2 tabs ----
    await world.launch(tester);
    final store = world.store;
    for (final tab in [HomeTab.home, HomeTab.all, HomeTab.videos, HomeTab.photos, HomeTab.folders]) {
      expect(find.byKey(homeTabKey(tab)), findsOneWidget, reason: '${tab.name} tab');
    }
    expect(find.byKey(homeTabKey(HomeTab.documents)), findsNothing, reason: 'Documents waits for S3');
    expect(_key('s2-import'), findsOneWidget);
    _report('library at ${store.paths.root.split('/').reversed.take(2).toList().reversed.join('/')}; tabs ok');
    await E2eApp.screenshot(tester, 's2-01-home');

    // ---- 2. Nested Danaview folders ----
    await _tab(tester, HomeTab.folders);
    await E2eApp.tapKey(tester, 'folders-new-root');
    await _prompt(tester, 'Trips', 'Create');
    await E2eApp.pumpUntil(tester, () => store.reader.childFolders(null).any((f) => f.name == 'Trips'), what: 'folder Trips');
    final trips = store.reader.childFolders(null).singleWhere((f) => f.name == 'Trips').id;
    await E2eApp.tap(tester, _folderRow(trips), what: 'Trips row');
    await E2eApp.tapKey(tester, 'folders-new-here');
    await _prompt(tester, 'Japan', 'Create');
    await E2eApp.pumpUntil(tester, () => store.reader.childFolders(trips).any((f) => f.name == 'Japan'), what: 'folder Japan');
    final japan = store.reader.childFolders(trips).single.id;
    expect(store.reader.pathOf(japan).map((f) => f.name), ['Trips', 'Japan']);
    await E2eApp.screenshot(tester, 's2-02-nested-folders');
    await E2eApp.tapKey(tester, 'folders-up');

    // ---- 3. Import: the photo into Japan, the video into Imported ----
    await _tab(tester, HomeTab.home);
    await E2eApp.tapKey(tester, 's2-import');
    await E2eApp.waitKey(tester, 'import-sheet');
    await E2eApp.tapKey(tester, 'import-target');
    await E2eApp.tapKey(tester, 'import-folder-${japan.value}');
    world.picker.photos.add(photoSrc.path);
    await E2eApp.tapKey(tester, 'import-from-photos');
    await E2eApp.pumpUntil(tester, () => _entryNamed(store, _photoName) != null, what: 'the photo import', timeout: const Duration(seconds: 60));
    await E2eApp.tapKey(tester, 'import-target');
    await E2eApp.tapKey(tester, 'import-folder-imported');
    world.picker.files.add(videoSrc.path);
    await E2eApp.tapKey(tester, 'import-from-files');
    await E2eApp.pumpUntil(tester, () => _entryNamed(store, _videoName) != null, what: 'the video import', timeout: const Duration(seconds: 60));
    final c = ProviderScope.containerOf(tester.element(find.byType(DanaviewApp)), listen: false);
    await E2eApp.pumpUntil(tester, () => c.read(importServiceProvider)!.items.every((i) => i.state.isFinal), what: 'imports to finish');
    await E2eApp.screenshot(tester, 's2-03-import-sheet');
    await _dismissSheet(tester);

    final photo = _entryNamed(store, _photoName)!;
    var video = _entryNamed(store, _videoName)!;
    final imported = store.reader.systemFolder(FolderSystemRole.imported)!.id;
    expect(photo.folderId, japan);
    expect(photo.kind, FileKind.photo);
    expect(video.folderId, imported);
    expect(video.kind, FileKind.video);
    final photoFile = File(store.paths.entryFile(photo.id, photo.displayName));
    final videoFile = File(store.paths.entryFile(video.id, video.displayName));
    expect(photoFile.readAsBytesSync(), photoBytes, reason: 'the library copy equals the original');
    expect(videoFile.readAsBytesSync(), videoBytes, reason: 'the library copy equals the original');
    for (final s in world.picker.staged) {
      expect(File(s).existsSync(), isFalse, reason: 'staged copy removed after import');
    }
    _report('imported photo ${photoBytes.length} B into Trips/Japan, video ${videoBytes.length} B into Imported; copies byte-equal; staged copies removed');

    // Move the video to Trips from the All tab.
    await _tab(tester, HomeTab.all);
    await _menu(tester, _entryRow(video.id), 'Move to…');
    await E2eApp.tapKey(tester, 'folder-pick-${trips.value}');
    await E2eApp.pumpUntil(tester, () => store.reader.entry(video.id)!.folderId == trips, what: 'the video in Trips');
    video = store.reader.entry(video.id)!;
    expect(File(store.paths.entryFile(video.id, video.displayName)).readAsBytesSync(), videoBytes);
    await E2eApp.screenshot(tester, 's2-04-all-tab');

    // ---- 4. Viewer with EXIF; share from the viewer; the video plays ----
    await _tab(tester, HomeTab.photos);
    await E2eApp.tap(tester, find.byKey(ValueKey<String>(photo.id.value)).hitTestable(), what: 'photo cell');
    await E2eApp.waitKey(tester, 'photo-viewer-pages');
    expect(find.descendant(of: _key('photo-viewer-name'), matching: find.text(_photoName)), findsOneWidget);
    await E2eApp.tapKey(tester, 'photo-viewer-info');
    await E2eApp.waitKey(tester, 'photo-info-rows', timeout: const Duration(seconds: 20));
    final camera = find.descendant(of: _key('photo-info-camera'), matching: find.textContaining('S2 Test Cam'));
    expect(camera, findsOneWidget, reason: 'EXIF camera line');
    expect(find.descendant(of: _key('photo-info-taken'), matching: find.textContaining('21 October 2026')), findsOneWidget, reason: 'EXIF date taken');
    await E2eApp.screenshot(tester, 's2-05-photo-info');
    await _dismissSheet(tester);
    await E2eApp.tapKey(tester, 'photo-viewer-share');
    await E2eApp.pumpUntil(tester, () => world.out.shared.isNotEmpty, what: 'the share hand-off');
    final sharedPhoto = world.out.shared.single;
    expect(sharedPhoto.displayName, _photoName);
    expect(File(sharedPhoto.path).readAsBytesSync(), photoBytes);
    _report('viewer: EXIF camera and date shown; Share handed over $_photoName (${sharedPhoto.mime})');
    await E2eApp.tapKey(tester, 'photo-viewer-close');

    await _tab(tester, HomeTab.all);
    await E2eApp.tap(tester, _entryRow(video.id), what: 'video row');
    await E2eApp.pumpUntil(tester, () => find.byType(DanaviewPlayerScreen).evaluate().isNotEmpty, what: 'the player');
    await E2eApp.pumpUntil(tester, () => c.read(playerControllerProvider).duration > Duration.zero, what: 'the player to open the video');
    await E2eApp.pumpUntil(tester, () => c.read(playerControllerProvider).position > const Duration(milliseconds: 300),
        what: 'playback to advance', timeout: const Duration(seconds: 20));
    _report('player: duration ${c.read(playerControllerProvider).duration.inMilliseconds} ms, playing');
    await E2eApp.screenshot(tester, 's2-06-player');
    await c.read(playerControllerProvider.notifier).pause();
    final router = tester.state<NavigatorState>(find.byType(Navigator).first);
    router.maybePop();
    await E2eApp.pumpUntil(tester, () => find.byType(DanaviewPlayerScreen).evaluate().isEmpty, what: 'back to Home');
    expect(store.reader.recents().map((e) => e.id), containsAll([photo.id, video.id]), reason: 'Recents record both opens');

    // ---- 5. Save out and Save to Photos from the selection bar ----
    await _tab(tester, HomeTab.photos);
    await _longPress(tester, find.byKey(ValueKey<String>(photo.id.value)), what: 'photo cell');
    await E2eApp.waitKey(tester, 'home-selection-bar');
    await E2eApp.screenshot(tester, 's2-07-selection');
    await E2eApp.tapKey(tester, 'selection-action-file-save-out');
    await E2eApp.pumpUntil(tester, () => world.out.saved.any((s) => s.$2 == SaveOutTarget.files), what: 'Save to Files');
    await E2eApp.pumpUntil(tester, () => find.textContaining('Saved a copy').evaluate().isNotEmpty, what: 'the saved toast');
    await _longPress(tester, find.byKey(ValueKey<String>(photo.id.value)), what: 'photo cell');
    await E2eApp.waitKey(tester, 'home-selection-bar');
    await E2eApp.tapKey(tester, 'selection-action-file-save-photos');
    await E2eApp.pumpUntil(tester, () => world.out.saved.any((s) => s.$2 == SaveOutTarget.photos), what: 'Save to Photos',
        timeout: const Duration(seconds: 45));
    await E2eApp.pumpUntil(tester, () => find.textContaining('to Photos').evaluate().isNotEmpty, what: 'the Photos toast',
        timeout: const Duration(seconds: 45));
    expect(photoFile.readAsBytesSync(), photoBytes, reason: 'getting a copy out never changes the library file');
    _report('save out: Save to Files ${world.out.saved.where((s) => s.$2 == SaveOutTarget.files).length}, '
        'Save to Photos ${_realPhotos ? 'real NativeFileOut' : 'recorded'}');
    if (find.byKey(const ValueKey('selection-clear')).hitTestable().evaluate().isNotEmpty) {
      await E2eApp.tapKey(tester, 'selection-clear', ifStillThere: true);
    }

    // ---- 6. Delete both, restore the photo ----
    await _tab(tester, HomeTab.all);
    for (final id in [photo.id, video.id]) {
      await _menu(tester, _entryRow(id), 'Delete');
      await E2eApp.tap(tester, find.text('Delete').hitTestable().last, what: 'confirm Delete');
      await E2eApp.pumpUntil(tester, () => store.reader.entry(id)!.isTrashed, what: 'entry trashed');
    }
    expect(store.reader.recentlyDeleted().map((t) => t.name), containsAll([_photoName, _videoName]));
    await _tab(tester, HomeTab.folders);
    await E2eApp.tapKey(tester, 'recently-deleted-row');
    await E2eApp.pumpUntil(tester, () => find.text(_photoName).hitTestable().evaluate().isNotEmpty, what: 'Recently deleted list');
    await E2eApp.screenshot(tester, 's2-08-recently-deleted');
    final photoTrashRow = find.ancestor(
        of: find.text(_photoName), matching: find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('trashed-')));
    await E2eApp.tap(tester, find.descendant(of: photoTrashRow.first, matching: find.text('Restore')), what: 'Restore photo');
    await E2eApp.pumpUntil(tester, () => !store.reader.entry(photo.id)!.isTrashed, what: 'photo restored');
    expect(store.reader.entry(photo.id)!.folderId, japan, reason: 'restored into its folder');
    expect(photoFile.readAsBytesSync(), photoBytes);
    _report('delete: both in Recently deleted; photo restored to Trips/Japan');

    // ---- 7. Reopen the library (store half of an app restart) ----
    await world.close(tester);
    await world.launch(tester);
    final reopened = world.store;
    expect(reopened.reader.pathOf(japan).map((f) => f.name), ['Trips', 'Japan'], reason: 'folders persist');
    expect(reopened.reader.entry(photo.id)!.folderId, japan, reason: 'entries persist');
    expect(reopened.reader.entry(video.id)!.isTrashed, isTrue, reason: 'Recently deleted persists');
    expect(reopened.reader.recentlyDeleted().map((t) => t.name), contains(_videoName));
    expect(reopened.reader.recents().map((e) => e.id), contains(video.id), reason: 'Recents persist');
    await _tab(tester, HomeTab.folders);
    await E2eApp.tapKey(tester, 'recently-deleted-row');
    final videoTrashRow = find.ancestor(
        of: find.text(_videoName), matching: find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('trashed-')));
    await E2eApp.tap(tester, find.descendant(of: videoTrashRow.first, matching: find.text('Restore')), what: 'Restore video');
    await E2eApp.pumpUntil(tester, () => !reopened.reader.entry(video.id)!.isTrashed, what: 'video restored');
    expect(reopened.reader.entry(video.id)!.folderId, trips);
    expect(File(reopened.paths.entryFile(video.id, _videoName)).readAsBytesSync(), videoBytes);
    expect(await reopened.checkInvariants(), isEmpty, reason: 'library invariants');
    await E2eApp.screenshot(tester, 's2-09-after-reopen');

    // Originals: bytes and timestamps unchanged.
    expect(photoSrc.readAsBytesSync(), photoBytes);
    expect(videoSrc.readAsBytesSync(), videoBytes);
    expect(photoSrc.lastModifiedSync(), photoMtime);
    expect(videoSrc.lastModifiedSync(), videoMtime);
    _report('reopen: folders, entries, Recents and Recently deleted persisted; video restored to Trips; invariants ok; originals unchanged');

    await world.close(tester);
  });
}
