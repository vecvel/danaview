// OWNER: S2-W
// EXTENDED: S3-W (slice S3 "Documents: view and share-in": the Documents tab shown, documents and
// other files opened through HOM-23's viewer router with the native viewers, audio in the player,
// the S3 overrides of lib/wiring/documents_wiring.dart and the Share Extension inbox host. Still
// nothing with DANAVIEW_FILES_HOME off.)
//
// S2 wiring (BUILD_PLAN v1.2 §1A, slice S2 "Photos & Files Home"; the slice's share of INT-103):
// the Files & Media Home behind DANAVIEW_FILES_HOME. With the flag off (the default, never flipped
// in code) nothing here runs: [filesHomeOverrides] returns no override, [appHomeScreen] builds the
// 1.1 `DanaviewHomeScreen` exactly as before and [appSettingsSectionsFor] adds no section, so the
// app is the S1 app.
//
// With the flag on the app root:
//
// * opens the library (`library.db`, Danaview folders, Recently deleted; HOM-17) under the
//   application-support directory (ARCH v1.2 §5.2), with the native backup flag on `imports/`
//   (HOM-02), and runs the Recently deleted sweep daily while the app is in the foreground;
// * opens the thumbnail cache under the cache directory (HOM-04) and trims it on memory pressure;
// * installs the import picker and copier (HOM-20; `file_selector` on Windows and Linux), the
//   named-sort store (HOM-19), the file group of the selection bar (HOM-22), the photo viewer's
//   share hook (HOM-11 over HOM-22's port) and, on Windows and Linux, the save-dialog file-out port;
// * fills the Home's tab slots: All, Videos, Folders (HOM-18), Photos (HOM-10), the Overview's
//   Import and search row (HOM-20, HOM-19), Recent photos tray (HOM-09), favourites and recents
//   (HOM-19) and the selection bar (HOM-12, HOM-22); from S3 also the Documents tab (HOM-18,
//   [s3DocumentsShown]);
// * shows Settings › Library storage (HOM-17) after Settings › Privacy;
// * (S3) opens documents and other files in HOM-23's viewer router and adds the S3 overrides
//   (viewers, linked documents, Share Extension inbox; documents_wiring.dart).
//
// Not wired yet (later slices): Edit photo, Batch edit and Make video montage (INT-105, the
// editor bridges), Search with AI (S7), the PDF tools (S4).
//
// Nothing here logs a name or a path (ARCH v1.2 rule 30).

// The Files & Media Home surfaces are reached through their own entry files under lib/src/
// (INT-101 keeps the features barrel unchanged), as the S1 wiring test does for the flags.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:io';

import 'package:danaview_data/danaview_data.dart' show AppStorage, LibraryRepository;
import 'package:danaview_domain/danaview_domain.dart' show MediaRef;
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_features/src/library/file_actions/file_actions.dart';
import 'package:danaview_features/src/library/files/library_store_providers.dart';
import 'package:danaview_features/src/library/filters/entry_widgets.dart' show LibraryEntryActions;
import 'package:danaview_features/src/library/filters/library_filters.dart';
import 'package:danaview_features/src/library/home/recent_photos_tray.dart';
import 'package:danaview_features/src/library/import/import_pickers.dart';
import 'package:danaview_features/src/library/import/import_providers.dart';
import 'package:danaview_features/src/library/import/import_sheet.dart';
import 'package:danaview_features/src/library/organise/organise_providers.dart';
import 'package:danaview_features/src/library/organise/organise_widgets.dart';
import 'package:danaview_features/src/library/photo_viewer/photo_viewer_actions.dart';
import 'package:danaview_features/src/library/photo_viewer/photo_viewer_entry.dart' show PhotoViewerEntry, photoMimeTypeOf;
import 'package:danaview_features/src/library/photo_viewer/photo_viewer_screen.dart';
import 'package:danaview_features/src/library/desktop/desktop_sidebar.dart' show DesktopPhotoSidebarPane;
import 'package:danaview_features/src/library/photos/photos_tab_providers.dart' show readDanaviewPhotos;
import 'package:danaview_features/src/library/search/library_search_field.dart';
import 'package:danaview_features/src/library/sources/desktop_photos_source.dart' show desktopPlatformFor;
import 'package:danaview_features/src/library/selection/selection_bar.dart';
import 'package:danaview_features/src/library/tabs/all_tab.dart';
import 'package:danaview_features/src/library/tabs/documents_tab.dart';
import 'package:danaview_features/src/library/tabs/folders_tab.dart';
import 'package:danaview_features/src/library/tabs/photos_tab.dart';
import 'package:danaview_features/src/library/tabs/videos_tab.dart';
import 'package:danaview_features/src/library/thumbs/thumbnail_providers.dart';
import 'package:danaview_features/src/library/thumbs/thumbnail_service.dart' show ThumbnailService;
import 'package:danaview_features/src/more/settings_sections/library_storage_section.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart' show NativeBackupFlags;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart' show applyWorkaroundToOpenSqlite3OnOldAndroidVersions;

import 'documents_wiring.dart';

/// Whether this build wires the Files & Media Home (`DANAVIEW_FILES_HOME`, default false).
bool get filesHomeWired => FeatureFlags.filesHomeEnabled;

// ---------------------------------------------------------------------------------------------
// Start-up: the library, thumbnails, import and the app-side ports.
// ---------------------------------------------------------------------------------------------

/// Opens the library store under [root] (tests pass an in-process store).
typedef LibraryStoreOpener = Future<LibraryStore> Function(String root, BackupFlagPort backup);

/// Opens the thumbnail cache under [cacheDir] (tests pass a fake).
typedef ThumbnailServiceOpener = Future<ThumbnailService> Function(String cacheDir);

/// The directories the S2 wiring uses (the app's support and cache directories).
@immutable
final class FilesHomeDirectories {
  /// [support] holds the library (ARCH v1.2 §5.2), [cache] the thumbnails and import staging.
  const FilesHomeDirectories({required this.support, required this.cache});

  /// The application-support directory (`Library/Application Support`, Android `filesDir`).
  final String support;

  /// The app's own cache directory: `Library/Caches` on iOS and Android `cacheDir` (what
  /// `getTemporaryDirectory` returns there); on macOS, Windows and Linux the per-app cache folder
  /// (`getApplicationCacheDirectory`), never the system temporary folder, which other users and
  /// apps can share (ARCH v1.2 §5.2 `<cache>/danaview/library/thumbs/`).
  final String cache;

  /// Where pickers stage photo and document picks before the import copies them.
  String get importStaging => '$cache${Platform.pathSeparator}danaview${Platform.pathSeparator}import_staging';

  /// The app's directories ([AppStorage]) on [platform] (default [defaultTargetPlatform]).
  ///
  /// iOS and Android take [AppStorage.cacheDirectory] (`getTemporaryDirectory`, the app's own
  /// cache there). macOS, Windows and Linux take the per-app cache folder that 1.1's Storage clear
  /// also empties ([AppStorage.appCacheDirectories]); without one the cache goes under the support
  /// directory, never the shared system temporary folder. Tests pass [appCacheDirectories].
  static Future<FilesHomeDirectories> resolve({
    TargetPlatform? platform,
    Future<List<Directory>> Function()? appCacheDirectories,
  }) async {
    await AppStorage.initialize();
    final support = AppStorage.appDataDirectory.path;
    return FilesHomeDirectories(
      support: support,
      cache: await cacheFor(
        platform: platform ?? defaultTargetPlatform,
        support: support,
        temporary: AppStorage.cacheDirectory.path,
        appCacheDirectories: appCacheDirectories ?? AppStorage.appCacheDirectories,
      ),
    );
  }

  /// The cache root on [platform]: [temporary] on iOS and Android; elsewhere the first of
  /// [appCacheDirectories], or `<support>/cache` when the platform gives none.
  @visibleForTesting
  static Future<String> cacheFor({
    required TargetPlatform platform,
    required String support,
    required String temporary,
    required Future<List<Directory>> Function() appCacheDirectories,
  }) async {
    if (platform == TargetPlatform.iOS || platform == TargetPlatform.android) return temporary;
    List<Directory> folders;
    try {
      folders = await appCacheDirectories();
    } on Object {
      folders = const [];
    }
    return folders.isNotEmpty ? folders.first.path : '$support${Platform.pathSeparator}cache';
  }
}

/// [NativeBackupFlags] as HOM-17's [BackupFlagPort] (Apple `isExcludedFromBackup`; a no-op
/// elsewhere, where Android's rules are backup XML, INT-104).
final class NativeBackupFlagPort implements BackupFlagPort {
  /// The port over [flags].
  NativeBackupFlagPort([NativeBackupFlags? flags]) : _flags = flags ?? NativeBackupFlags();

  final NativeBackupFlags _flags;

  @override
  Future<void> setExcludedFromBackup(String path, {required bool excluded}) async {
    try {
      await _flags.setExcludedFromBackup(path, excluded: excluded);
    } on Object {
      // Never fails the library: the path stays in its default backup class.
    }
  }
}

/// The library root layout of [platform] (ARCH v1.2 §5.2).
LibraryRootStyle libraryRootStyleOf(TargetPlatform platform) =>
    platform == TargetPlatform.android ? LibraryRootStyle.android : LibraryRootStyle.appSupport;

/// Whether [platform] has the native pickers, copier and getting-files-out (iOS, macOS, Android).
bool hasNativeLibraryPlugin(TargetPlatform platform) =>
    platform == TargetPlatform.iOS || platform == TargetPlatform.macOS || platform == TargetPlatform.android;

/// Opens the default app with [path] on Windows and Linux (the "Open in another app" of
/// [DesktopFileOut]); false when nothing took it.
Future<bool> openWithDesktopDefaultApp(String path) async {
  try {
    final result = Platform.isWindows
        ? await Process.run('explorer.exe', [path])
        : await Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [path]);
    // explorer.exe answers 1 even when it opened the file.
    return Platform.isWindows || result.exitCode == 0;
  } on Object {
    return false;
  }
}

/// The overrides of the library side of the app, and what has to stay alive with it.
final class FilesHomeRuntime {
  FilesHomeRuntime._(this.store, this.thumbnails, this.overrides, this._observers);

  /// No runtime: the flag is off (or the library could not be opened at all).
  static final FilesHomeRuntime off = FilesHomeRuntime._(null, null, const [], const []);

  /// The open library, or null.
  final LibraryStore? store;

  /// The open thumbnail cache, or null.
  final ThumbnailService? thumbnails;

  /// The provider overrides (empty when off).
  final List<Override> overrides;

  final List<WidgetsBindingObserver> _observers;

  /// Unregisters the lifecycle observers and closes the library (tests; the app keeps it open).
  Future<void> dispose() async {
    for (final o in _observers) {
      WidgetsBinding.instance.removeObserver(o);
    }
    await store?.close();
  }
}

/// Starts the daily Recently deleted sweep while the app is in the foreground and pauses it in
/// the background (HOM-17); a resume also sweeps once, so a long background stay still purges.
final class LibrarySweepLifecycle with WidgetsBindingObserver {
  /// The observer of [store].
  LibrarySweepLifecycle(this.store);

  /// The library.
  final LibraryStore store;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        store.startDailySweep();
        unawaited(store.sweepNow().then<void>((_) {}, onError: (Object _) {}));
      case AppLifecycleState.paused || AppLifecycleState.detached || AppLifecycleState.hidden:
        store.stopDailySweep();
      case AppLifecycleState.inactive:
        break;
    }
  }
}

/// The Files & Media Home overrides of the app: nothing with DANAVIEW_FILES_HOME off.
///
/// With the flag on it opens the library and the thumbnail cache (failures leave each one out, so
/// the Home still shows its 1.1 sections and empty library tabs) and installs the import, organise,
/// selection, file-out and photo-viewer providers. [platform], [directories], [openStore] and
/// [openThumbnails] are test seams.
Future<FilesHomeRuntime> filesHomeOverrides({
  required SharedPreferences prefs,
  TargetPlatform? platform,
  FilesHomeDirectories? directories,
  LibraryStoreOpener? openStore,
  ThumbnailServiceOpener? openThumbnails,
  bool observeLifecycle = true,
}) async {
  if (!filesHomeWired) return FilesHomeRuntime.off;
  final target = platform ?? defaultTargetPlatform;
  final native = hasNativeLibraryPlugin(target);
  final dirs = directories ?? await FilesHomeDirectories.resolve(platform: target);
  final backup = native ? NativeBackupFlagPort() : const NoBackupFlagPort();

  LibraryStore? store;
  try {
    final root = libraryRootIn(dirs.support, libraryRootStyleOf(target));
    store = await (openStore ?? _openStore)(root, backup);
  } on Object catch (e) {
    debugPrint('[files-home] Library unavailable (${e.runtimeType})');
  }

  ThumbnailService? thumbnails;
  try {
    thumbnails = await (openThumbnails ?? (cache) => _openThumbnails(cache, native: native))(dirs.cache);
  } on Object catch (e) {
    debugPrint('[files-home] Thumbnails unavailable (${e.runtimeType})');
  }

  final observers = <WidgetsBindingObserver>[
    if (store != null) LibrarySweepLifecycle(store),
    if (thumbnails != null) ThumbnailMemoryPressureObserver(thumbnails),
  ];
  if (observeLifecycle) {
    for (final o in observers) {
      WidgetsBinding.instance.addObserver(o);
    }
    store?.startDailySweep();
  }

  final desktopOut = native
      ? null
      : DesktopFileOut(
          platform: fileOutPlatformOf(target),
          pickSaveFile: (name) async => (await file_selector.getSaveLocation(suggestedName: name))?.path,
          pickSaveDirectory: () => file_selector.getDirectoryPath(),
          openWithDefaultApp: openWithDesktopDefaultApp,
        );

  final overrides = <Override>[
    if (store != null) libraryStoreProvider.overrideWithValue(store),
    if (thumbnails != null) thumbnailServiceProvider.overrideWithValue(thumbnails),
    sortPreferenceStoreProvider.overrideWithValue(PrefsSortPreferenceStore(prefs)),
    importStagingDirectoryProvider.overrideWithValue(dirs.importStaging),
    importPickerProvider.overrideWithValue(native
        ? NativeImportPicker(stagingDirectory: dirs.importStaging)
        : CallbackImportPicker(() async => [for (final f in await file_selector.openFiles()) f.path])),
    if (native) importExtraCopiersProvider.overrideWithValue([NativeImportCopier()]),
    if (desktopOut != null) fileOutPortProvider.overrideWithValue(desktopOut),
    selectionActionGroupsProvider.overrideWithValue(const [mediaSelectionGroup, fileSelectionGroup]),
    photoViewerHooksProvider.overrideWith((ref) {
      final port = ref.watch(fileOutPortProvider);
      if (port == null || !port.capabilities.canShare) return PhotoViewerHooks.none;
      return PhotoViewerHooks(share: (context, entry) => sharePhoto(context, port, entry));
    }),
    // S3: viewers, linked documents, the Share Extension inbox (iOS). Test runs (no lifecycle)
    // don't create the inbox staging folder.
    ...documentsOverrides(platform: target, support: dirs.support, excludeStagingFromBackup: observeLifecycle),
  ];
  return FilesHomeRuntime._(store, thumbnails, overrides, observers);
}

/// Opens `library.db` with the SQLite that sqlite3_flutter_libs bundles (D-7, ARCH v1.2 V-S21).
/// On Android the library is first loaded from Java where old versions can't dlopen it from Dart;
/// this runs here, on the main isolate, before the store spawns its writer isolate, and does
/// nothing on the other platforms.
Future<LibraryStore> _openStore(String root, BackupFlagPort backup) async {
  await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();
  return LibraryStore.open(root: root, backup: backup);
}

Future<ThumbnailService> _openThumbnails(String cache, {required bool native}) {
  if (!native) return openThumbnailService(cacheDir: cache);
  final flags = NativeBackupFlags();
  return openThumbnailService(
    cacheDir: cache,
    excludeFromBackup: (path) async {
      try {
        await flags.setExcludedFromBackup(path, excluded: true);
      } on Object {
        // Caches are outside backups on every platform already.
      }
    },
  );
}

/// The photo viewer's Share (HOM-11): a temporary read-only copy through the share sheet.
Future<void> sharePhoto(BuildContext context, FileOutPort port, PhotoViewerEntry entry) async {
  final path = entry.filePath;
  if (path == null) {
    _toast(context, "This photo can't be shared from here.", error: true);
    return;
  }
  try {
    await port.share(
      [OutFile(path: path, displayName: entry.item.name, mime: entry.mimeType)],
      anchor: anchorOf(context),
    );
  } on FileOutException catch (e) {
    if (context.mounted) _toast(context, fileOutErrorMessage(e.error, FileAction.share), error: true);
  }
}

void _toast(BuildContext context, String message, {bool error = false}) {
  if (!context.mounted) return;
  DanaviewToast.show(
    context,
    message,
    kind: error ? DanaviewToastKind.error : DanaviewToastKind.info,
    icon: error ? Icons.error_outline_rounded : null,
  );
}

// ---------------------------------------------------------------------------------------------
// Settings.
// ---------------------------------------------------------------------------------------------

/// The 1.2.0 Settings sections of this build: [base] (S1's Settings › Privacy) plus Settings ›
/// Library storage (HOM-17) with DANAVIEW_FILES_HOME on.
SettingsSections appSettingsSectionsFor(SettingsSections base) {
  if (!filesHomeWired) return base;
  return SettingsSections(
    privacy: base.privacy,
    libraryStorage: base.libraryStorage ?? buildLibraryStorageSettingsSection,
    searchIndex: base.searchIndex,
  );
}

// ---------------------------------------------------------------------------------------------
// Opening library items.
// ---------------------------------------------------------------------------------------------

/// [entry] as the [MediaItem] the selection, the file menu and the viewer take; [path] is its
/// library file.
MediaItem mediaItemOfEntry(FileEntry entry, String path) => switch (entry.kind) {
      FileKind.photo => PhotoMediaItem(
          id: entry.id,
          uri: path,
          name: entry.displayName,
          modifiedAt: entry.modifiedAt,
          mimeType: photoMimeTypeOf(entry.displayName),
          sizeBytes: entry.sizeBytes,
        ),
      FileKind.video => VideoMediaItem(
          id: entry.id,
          uri: path,
          name: entry.displayName,
          modifiedAt: entry.modifiedAt,
          mimeType: MediaRefBridge.videoMimeTypeFor(path),
          sizeBytes: entry.sizeBytes,
        ),
      _ => DocumentItem(
          id: entry.id,
          uri: path,
          name: entry.displayName,
          modifiedAt: entry.modifiedAt,
          mimeType: 'application/octet-stream',
          sizeBytes: entry.sizeBytes,
          docKind: entry.docKind ?? DocumentKind.other,
        ),
    };

MediaRef _fileRef(String path) => LibraryRepository.mediaRefForFile(path);

/// Opens a Danaview library [entry]: a photo in the photo viewer among the library's photos, a
/// video or audio file in the player, anything else through the viewer router (HOM-23, S3: PDF,
/// Quick Look, text and CSV, or the file card). Records the open in Recents (HOM-19).
Future<void> openLibraryEntry(BuildContext context, WidgetRef ref, FileEntry entry, {required VoidCallback onOpenPlayer}) =>
    openLibraryEntryWith(context, ref.read, entry, onOpenPlayer: onOpenPlayer);

/// [openLibraryEntry] with any provider reader (the incoming-file path has no [WidgetRef]).
Future<void> openLibraryEntryWith(BuildContext context, ProviderRead read, FileEntry entry, {required VoidCallback onOpenPlayer}) async {
  final store = read(libraryStoreProvider);
  if (store == null) return;
  final path = store.paths.entryFile(entry.id, entry.displayName);
  switch (entry.kind) {
    case FileKind.photo:
      // The viewer records the open itself.
      final photos = readDanaviewPhotos(store);
      final index = photos.indexWhere((p) => p.id == entry.id);
      if (index < 0) return;
      await openPhotoViewer(context, photos, index);
    case FileKind.video || FileKind.audio:
      unawaited(read(recordLibraryOpenProvider)(entry.id).catchError((Object _) {}));
      await read(queueControllerProvider.notifier).playFrom([_fileRef(path)]);
      onOpenPlayer();
    case FileKind.document || FileKind.other:
      // The viewer host records the open (Recents).
      if (!context.mounted) return;
      await openDocumentViewer(context, read, viewerFileOfEntry(entry, path));
  }
}

/// Shows HOM-22's single-file menu for a Danaview library [entry] (Share, Open in another app,
/// Save out, Copy to, Move to, Rename, Favourite, File info, Delete, as its kind and the file-out
/// port allow) and runs the chosen action. From S3 a document or other-file row tap opens the
/// viewer, so this is how those rows reach the file actions S2 gave them (FIX-S3Q-1); the row
/// menu's "More actions…" item calls it once HOM-18's `LibraryEntryActions` carries that hook.
Future<void> showLibraryEntryFileMenu(BuildContext context, WidgetRef ref, FileEntry entry) async {
  final store = ref.read(libraryStoreProvider);
  if (store == null) return;
  final item = mediaItemOfEntry(entry, store.paths.entryFile(entry.id, entry.displayName));
  await showFileActionsMenu(context, ref, item, anchor: anchorOf(context));
}

// ---------------------------------------------------------------------------------------------
// The Home.
// ---------------------------------------------------------------------------------------------

/// The app's Home: the 1.1 [DanaviewHomeScreen] with DANAVIEW_FILES_HOME off (the same widget and
/// arguments as before S2), the Files & Media Home with it on.
Widget appHomeScreen({
  required VoidCallback onOpenPlayer,
  required ValueChanged<String> onOpenFolder,
  required ValueChanged<String> onOpenPlaylist,
  VoidCallback? onOpenSettings,
  VoidCallback? onOpenEditor,
  VoidCallback? onOpenProjects,
}) {
  if (!filesHomeWired) {
    return DanaviewHomeScreen(
      onOpenPlayer: onOpenPlayer,
      onOpenFolder: onOpenFolder,
      onOpenPlaylist: onOpenPlaylist,
      onOpenSettings: onOpenSettings,
      onOpenEditor: onOpenEditor,
    );
  }
  return FilesHome(
    onOpenPlayer: onOpenPlayer,
    onOpenFolder: onOpenFolder,
    onOpenPlaylist: onOpenPlaylist,
    onOpenSettings: onOpenSettings,
    onOpenEditor: onOpenEditor,
    onOpenProjects: onOpenProjects,
  );
}

/// The Files & Media Home with the S2 slots filled.
///
/// The shell (HOM-05) keeps its selected tab to itself, so a request for another tab (the Recent
/// photos tray's See all, a folder hit in search) re-opens the shell on that tab.
class FilesHome extends StatefulWidget {
  /// The Home; the callbacks are the router's, as for [DanaviewHomeScreen].
  const FilesHome({
    super.key,
    required this.onOpenPlayer,
    required this.onOpenFolder,
    required this.onOpenPlaylist,
    this.onOpenSettings,
    this.onOpenEditor,
    this.onOpenProjects,
  });

  /// Shows the player.
  final VoidCallback onOpenPlayer;

  /// Opens the 1.1 folder browser at a path.
  final ValueChanged<String> onOpenFolder;

  /// Opens a playlist.
  final ValueChanged<String> onOpenPlaylist;

  /// Opens Settings.
  final VoidCallback? onOpenSettings;

  /// The header's editor button (null hides it).
  final VoidCallback? onOpenEditor;

  /// The Projects tab (null hides it; the editor's platforms only).
  final VoidCallback? onOpenProjects;

  @override
  State<FilesHome> createState() => FilesHomeState();
}

/// The state of [FilesHome] (public for tests).
class FilesHomeState extends State<FilesHome> {
  /// Asks the Home shell for [tab] from [context], which sits inside the shell's tab pages: the
  /// shell selects the tab itself (HOM-05 listens for [HomeTabRequestNotification]), so the other
  /// tabs keep their scroll and folder positions.
  static void showTab(BuildContext context, HomeTab tab) => HomeTabRequestNotification(tab).dispatch(context);

  void _openEntry(BuildContext context, WidgetRef ref, FileEntry entry) =>
      unawaited(openLibraryEntry(context, ref, entry, onOpenPlayer: widget.onOpenPlayer));

  void _openLinkedDocument(BuildContext context, WidgetRef ref, DocumentItem document) =>
      unawaited(openDocumentViewer(context, ref.read, viewerFileOfLinked(document)));

  void _openPhotos(BuildContext context, List<PhotoGridItem> photos, int index) =>
      unawaited(openPhotoViewer(context, photos, index));

  void _openFavourite(BuildContext context, WidgetRef ref, FavouriteItem item) => switch (item) {
        FavouriteEntry(:final entry) => _openEntry(context, ref, entry),
        FavouriteFolder() => showTab(context, HomeTab.folders),
      };

  void _openHit(BuildContext context, WidgetRef ref, SearchHit hit) {
    final item = hit.item;
    switch (item.origin) {
      case SearchOrigin.danaview:
        if (item.isFolder) return showTab(context, HomeTab.folders);
        final id = EntryId.tryParse(item.id.value);
        final entry = id == null ? null : ref.read(libraryStoreProvider)?.reader.entry(id);
        if (entry != null) _openEntry(context, ref, entry);
      case SearchOrigin.linked:
        final path = item.path;
        if (path == null) return;
        if (item.isFolder) return widget.onOpenFolder(path);
        if (item.kind == FileKind.video) {
          unawaited(ref.read(queueControllerProvider.notifier).playFrom([_fileRef(path)]).then((_) => widget.onOpenPlayer()));
        } else {
          widget.onOpenFolder(File(path).parent.path);
        }
      case SearchOrigin.system:
        showTab(context, HomeTab.photos);
    }
  }

  MediaItem? _itemOf(WidgetRef ref, FileEntry e) {
    final store = ref.read(libraryStoreProvider);
    return store == null ? null : mediaItemOfEntry(e, store.paths.entryFile(e.id, e.displayName));
  }

  LibraryEntryActions _rowActions(BuildContext context, WidgetRef ref) {
    void run(FileAction action, FileEntry e) {
      final item = _itemOf(ref, e);
      if (item != null) unawaited(runFileAction(context, ref, action, [item], anchor: anchorOf(context)));
    }

    return LibraryEntryActions(
      onOpen: (e) => _openEntry(context, ref, e),
      onRename: (e) => run(FileAction.rename, e),
      onMove: (e) => run(FileAction.moveTo, e),
      onDelete: (e) => run(FileAction.delete, e),
    );
  }

  MediaItem? _danaviewPhotoMedia(WidgetRef ref, PhotoGridItem photo) {
    final id = EntryId.tryParse(photo.id.value);
    final entry = id == null ? null : ref.read(libraryStoreProvider)?.reader.entry(id);
    return entry == null ? null : _itemOf(ref, entry);
  }

  static HomeSlotBuilder _consumer(Widget Function(BuildContext context, WidgetRef ref) build) =>
      (context) => Consumer(builder: (context, ref, _) => build(context, ref));

  /// The slots of the Home: S2's, plus the Documents tab of S3 (BUILD_PLAN §1A).
  HomeTabSlots get slots => libraryFilterTabSlots(
        showDocuments: s3DocumentsShown,
        documents: _consumer((context, ref) => DocumentsTab(
              onOpenEntry: (e) => _openEntry(context, ref, e),
              onOpenLinked: (d) => _openLinkedDocument(context, ref, d),
              actions: _rowActions(context, ref),
            )),
        base: HomeTabSlots(
          photos: _consumer((context, ref) => FilesHomePhotosPane(
                photos: PhotosTab(
                onOpenPhoto: (photos, index) {
                  final photo = photos[index];
                  final media = photo.media ?? _danaviewPhotoMedia(ref, photo);
                  if (ref.read(homeSelectionProvider).isActive && media != null) {
                    ref.read(homeSelectionProvider.notifier).toggle(media);
                    return;
                  }
                  _openPhotos(context, photos, index);
                },
                onLongPressPhoto: (photo) {
                  final media = photo.media ?? _danaviewPhotoMedia(ref, photo);
                  if (media != null) ref.read(homeSelectionProvider.notifier).toggle(media);
                },
              ),
              )),
          recentPhotos: _consumer((context, ref) => Column(
                key: const ValueKey('s2-overview-library'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilesHomeToolsRow(onOpenHit: (hit) => _openHit(context, ref, hit)),
                  // See all bubbles a tab request up to the shell (HOM-09, HOM-05).
                  RecentPhotosTray(onOpenPhoto: (photos, index) => _openPhotos(context, photos, index)),
                ],
              )),
          favourites: _consumer((context, ref) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FavouritesRow(onOpen: (item) => _openFavourite(context, ref, item)),
                  RecentFilesSection(onOpen: (e) => _openEntry(context, ref, e)),
                ],
              )),
          selectionBar: (context) => HomeSelectionBar(onOpenPlayer: widget.onOpenPlayer),
        ),
        all: _consumer((context, ref) => AllTab(onOpenEntry: (e) => _openEntry(context, ref, e), actions: _rowActions(context, ref))),
        videos: _consumer((context, ref) => VideosTab(
              onOpenPlayer: widget.onOpenPlayer,
              onOpenPlaylist: widget.onOpenPlaylist,
              onOpenFolder: widget.onOpenFolder,
              onOpenEntry: (e) => _openEntry(context, ref, e),
            )),
        folders: _consumer((context, ref) => FoldersTab(
              onOpenFolder: widget.onOpenFolder,
              onOpenEntry: (e) => _openEntry(context, ref, e),
              onOpenPlayer: widget.onOpenPlayer,
            )),
      );

  @override
  Widget build(BuildContext context) {
    // The Share Extension inbox runs while the Home is mounted (it stays under every route).
    return InboxImportHost(
      child: DanaviewHomeScreen(
        onOpenPlayer: widget.onOpenPlayer,
        onOpenFolder: widget.onOpenFolder,
        onOpenPlaylist: widget.onOpenPlaylist,
        onOpenSettings: widget.onOpenSettings,
        onOpenEditor: widget.onOpenEditor,
        callbacks: HomeCallbacks(onOpenProjects: widget.onOpenProjects),
        tabSlots: slots,
      ),
    );
  }
}

/// The Photos tab with, on macOS, Windows and Linux, HOM-03's photo-location sidebar: shortcuts to
/// every photo root and the drop target that adds dropped folders as roots (V2-109). Picking a
/// shortcut filters the tab (`desktopPhotosControllerProvider`). Two panes from
/// [twoPaneMinWidth]; narrower, the sidebar sits above the grid in a short scrolling band. iOS and
/// Android show the tab alone.
class FilesHomePhotosPane extends StatelessWidget {
  /// The pane around [photos]; [platform] defaults to [defaultTargetPlatform].
  const FilesHomePhotosPane({super.key, required this.photos, this.platform});

  /// The Photos tab.
  final Widget photos;

  /// The platform deciding whether the sidebar shows (tests).
  final TargetPlatform? platform;

  /// The narrowest width with the sidebar beside the grid.
  static const double twoPaneMinWidth = DanaviewBreakpoints.compact;

  /// The sidebar's width in two panes.
  static const double sidebarWidth = 260;

  /// The sidebar band's share of the height when stacked (narrow windows).
  static const double stackedHeightFraction = 0.34;

  @override
  Widget build(BuildContext context) {
    if (desktopPlatformFor(platform ?? defaultTargetPlatform) == null) return photos;
    return LayoutBuilder(
      builder: (context, constraints) {
        const sidebar = DesktopPhotoSidebarPane(key: ValueKey('s2-desktop-sidebar'));
        const divider = ColoredBox(color: DanaviewColors.hairline);
        if (constraints.maxWidth >= twoPaneMinWidth) {
          return Row(
            key: const ValueKey('s2-photos-two-pane'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(width: sidebarWidth, child: sidebar),
              const SizedBox(width: 1, child: divider),
              Expanded(child: photos),
            ],
          );
        }
        final height = constraints.hasBoundedHeight ? constraints.maxHeight * stackedHeightFraction : 200.0;
        return Column(
          key: const ValueKey('s2-photos-stacked'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: height, child: sidebar),
            const SizedBox(height: 1, child: divider),
            Expanded(child: photos),
          ],
        );
      },
    );
  }
}

/// The Overview's library row: Import (HOM-20) and the name search (HOM-19) with its hits.
class FilesHomeToolsRow extends ConsumerWidget {
  /// The row; [onOpenHit] opens a search hit.
  const FilesHomeToolsRow({super.key, required this.onOpenHit});

  /// Opens a search hit.
  final ValueChanged<SearchHit> onOpenHit;

  /// The Import button's label.
  static const String importLabel = 'Import';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canImport = ref.watch(importServiceProvider) != null;
    return Padding(
      padding: const EdgeInsets.only(top: DanaviewSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canImport)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: DanaviewButton.secondary(
                key: const ValueKey('s2-import'),
                label: importLabel,
                icon: Icons.add_rounded,
                onPressed: () => unawaited(showImportSheet(context)),
              ),
            ),
          if (canImport) const SizedBox(height: DanaviewSpacing.md),
          LibrarySearchField(key: const ValueKey('s2-search'), onOpen: onOpenHit),
        ],
      ),
    );
  }
}

/// HOM-18's package default for the Documents tab (false); the app shows it from S3 on through
/// [s3DocumentsShown].
const bool s2DocumentsShown = documentsFilterShown;
