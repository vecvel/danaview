// OWNER: INT-02
//
// Wires the editor into the app (ARCH §4.1, §8, §9, §17.3). Only the app root constructs the
// platform engine (`MobileEditorEngine`) and hands it to [EditorBootstrap.create], which returns the
// `ProviderScope` overrides:
//
// * `StoreRoots` from danaview_data `AppStorage` (Application Support, Caches/temporary) and the
//   "On This Device" Documents folder (ARCH §8.1); editor files never go into Documents.
// * The engine's Documents root (`MobileMediaAccess.documentsRoot`) from `StoreRoots.documents`, so
//   `AppRelativeLocator(documents, …)` resolves: Files imports kept by reference (ARCH §9.1) and the
//   "Keep a copy in Danaview" exports (D-44). The engine plugin is out of reach here (ARCH §4.2
//   rule 7), so [EditorBootstrap.bindDocumentsRoot] sets it through the access's `documentsRoot`
//   setter when the engine's access has one (FIX-INT-02-1).
// * `FileMediaPoolService` over `engine.access`/`engine.probe` with the free-space preflight
//   (`engine.freeBytes`) and CORE-28's `MediaRelinkService` (availability re-checked on app resume);
//   both copy non-persistable picks through `engine.access.materializePick` (INT-07).
// * `EditorEngineConfig` carries `ExportStrings.notificationTexts` (INT-07).
// * `FileProjectRepository` with the pool, the engine's access, `allow2160` from the capabilities,
//   the poster capture (UX-08) and the GC hook; autosave runs with the repository's default policy.
// * `MediaGarbageCollector` + `GcScheduler`: the first run starts after 30 s idle; every run first
//   refreshes the export gate (an export that is running or resumable skips the sweep), and a
//   project delete runs it again.
// * `DefaultPlanCompiler` for `planCompilerPortProvider`, the editor prefs, the capabilities, and the
//   Settings › Storage contributors (`EditorStorageContributor.all`) when the router supplies the
//   Projects navigation.
// * The render-preview cache (D-45): `IndexRenderPreviewStore` over CORE-37's `RenderCacheIndex`
//   in `<cache>/danaview/editor/renders/`, LRU-bounded by the device tier
//   (`RenderCacheIndex.limitForTier`), for `renderPreviewStoreProvider`.
//
// On desktop, web, with `DANAVIEW_EDITOR` off or without an engine, [EditorBootstrap.create] returns
// [EditorBootstrap.unavailable]: no contributors, no root providers, the router hides every entry
// point and redirects the editor routes (D-17, D-31).

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:danaview_data/danaview_data.dart' show AppStorage, LibraryStorage;
import 'package:danaview_editor_core/model.dart' show ProjectId;
import 'package:danaview_editor_core/render_cache.dart' show RenderCacheIndex;
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_features/storage.dart' show StorageContributor, storageContributorsProvider;

import '../editor/state/default_plan_compiler.dart';
import '../editor/state/editor_session.dart' show EditorPosterCapture;
import '../editor/state/plan_compiler_port.dart';
import '../editor/state/render_preview_controller.dart' show IndexRenderPreviewStore, renderPreviewStoreProvider;
import 'editor_availability.dart';
import 'editor_prefs.dart';
import 'editor_providers.dart';
import 'editor_storage_contributor.dart';
import 'editor_tier_defaults.dart';
import 'strings/export_strings.dart';

/// Whether the GC may sweep now: false while an export runs or waits to be resumed (ARCH §9.4).
/// Unknown (never refreshed, or the engine could not answer) counts as "export in progress", so a
/// broken probe can never let the GC delete media an export still reads.
///
/// See ARCH §9.4, §14.1.
final class EditorExportGate {
  /// Creates the gate over [exporter].
  EditorExportGate(this.exporter, {this.timeout = const Duration(seconds: 5)});

  /// The engine's export service.
  final ExportService exporter;

  /// How long [refresh] waits for the engine.
  final Duration timeout;

  bool _inProgress = true;

  /// Whether an export is running or resumable (as of the last [refresh]).
  bool get inProgress => _inProgress;

  /// Asks the engine for its active jobs.
  Future<bool> refresh() async {
    try {
      final jobs = await exporter.activeJobs().timeout(timeout);
      _inProgress = jobs.any((job) => job is ExportRunning || job is ExportResumable);
    } on Object catch (e) {
      debugPrint('[EditorBootstrap] Export gate check failed: ${e.runtimeType}');
      _inProgress = true;
    }
    return _inProgress;
  }
}

/// What [EditorBootstrap.create] built (the app keeps it for the process lifetime).
///
/// See ARCH §4.1, §17.3.
final class EditorRuntime {
  EditorRuntime._({
    required this.engine,
    required this.roots,
    required this.prefs,
    required this.capabilities,
    required this.pool,
    required this.relinker,
    required this.repository,
    required this.compiler,
    required this.gc,
    required this.gcScheduler,
    required this.exportGate,
    required this.renderPreview,
  });

  /// The platform engine.
  final EditorEngine engine;

  /// App roots.
  final StoreRoots roots;

  /// Editor preferences.
  final EditorPrefs prefs;

  /// Capabilities read at start, or null when the engine did not answer in time.
  final EditorCapabilities? capabilities;

  /// The media pool service.
  final FileMediaPoolService pool;

  /// CORE-28's availability and relink service.
  final MediaRelinkService relinker;

  /// The project store.
  final FileProjectRepository repository;

  /// The plan compiler port.
  final DefaultPlanCompiler compiler;

  /// The media garbage collector.
  final MediaGarbageCollector gc;

  /// Its scheduler (`runNow` for Settings › Storage).
  final GcScheduler gcScheduler;

  /// The GC's export gate.
  final EditorExportGate exportGate;

  /// The render-preview cache (D-45), bounded by the device tier.
  final IndexRenderPreviewStore renderPreview;

  AppLifecycleListener? _lifecycle;
  bool _disposed = false;

  /// Runs the GC now (after refreshing the export gate).
  Future<GcReport> collectGarbage() async {
    await exportGate.refresh();
    return gcScheduler.runNow();
  }

  /// Re-checks media availability of every open session (app resume, ARCH §9.3).
  Future<void> resumed() async {
    try {
      await relinker.resumed();
    } on Object catch (e) {
      debugPrint('[EditorBootstrap] Availability re-check failed: ${e.runtimeType}');
    }
  }

  void _listenToLifecycle() {
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(resumed()));
  }

  /// Stops the GC timer and the lifecycle listener and closes the repository.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _lifecycle?.dispose();
    gcScheduler.dispose();
    await repository.dispose();
  }
}

/// The wired runtime, or null when the editor is unavailable (overridden by [EditorBootstrap]).
///
/// See ARCH §17.3.
final editorRuntimeProvider = Provider<EditorRuntime?>((ref) => null, name: 'editorRuntimeProvider');

/// Builds the provider overrides that wire the editor into the app (ARCH §4.1, §17.3).
///
/// See ARCH §4.1, §8.1, §17.3.
abstract final class EditorBootstrap {
  /// How long [create] waits for `engine.capabilities()` before wiring without them.
  static const Duration capabilitiesTimeout = Duration(seconds: 3);

  /// The app roots on this device: Application Support and Caches (danaview_data `AppStorage`) and the
  /// "On This Device" Documents folder (ARCH §8.1).
  static Future<StoreRoots> defaultRoots() async {
    await AppStorage.initialize();
    final support = AppStorage.appDataDirectory.path;
    final cache = AppStorage.cacheDirectory.path;
    String? documents;
    try {
      documents = (await LibraryStorage().deviceDirectory())?.path;
    } on Object catch (e) {
      debugPrint('[EditorBootstrap] Documents folder unavailable: ${e.runtimeType}');
    }
    return StoreRoots(support: support, cache: cache, documents: documents ?? p.join(support, 'Documents'));
  }

  /// The engine's directories under [roots] (ARCH §12.1).
  static EditorEngineConfig engineConfigOf(StoreRoots roots) => EditorEngineConfig(
        cacheRoot: roots.editorCache,
        supportRoot: roots.editorSupport,
        exportNotificationTexts: ExportStrings.notificationTexts,
      );

  /// Gives [access] the Documents directory [documents] (`StoreRoots.documents`) when it takes one
  /// (the platform engine's `MobileMediaAccess.documentsRoot`, reached without importing the
  /// plugin, ARCH §4.2 rule 7). Returns whether it was set; an access without the setter (a fake,
  /// a desktop stub) is left alone. Without it every `AppRelativeLocator(documents, …)` resolves
  /// as access-lost (FIX-INT-02-1).
  static bool bindDocumentsRoot(MediaAccess access, String documents) {
    try {
      (access as dynamic).documentsRoot = documents;
      return true;
    } on NoSuchMethodError {
      return false;
    } on TypeError {
      return false;
    }
  }

  /// The overrides of a build where the editor is hidden (desktop, web, `DANAVIEW_EDITOR` off, no
  /// engine): no storage contributors and no runtime. The root providers stay unconfigured; the
  /// router never reaches the editor screens (D-17).
  static List<Override> unavailable() => [
        storageContributorsProvider.overrideWithValue(const <StorageContributor>[]),
        editorRuntimeProvider.overrideWithValue(null),
      ];

  /// The overrides for the app's `ProviderScope`.
  ///
  /// Without an [engine], or when [platform] (default `EditorAvailability.platform`) is not
  /// supported, returns [unavailable]. Otherwise wires the store, pool, relink, GC, plan compiler,
  /// prefs and capabilities. [roots] default to [defaultRoots], [prefs] to `EditorPrefs.load()`.
  /// [onOpenProjects] is the router's navigation to the Projects screen; with it the Settings ›
  /// Storage contributors are listed. [fs], [timer], [useIsolates] and [listenToLifecycle] are for
  /// tests. Never throws: a failure while wiring logs and returns [unavailable].
  static Future<List<Override>> create({
    EditorEngine? engine,
    StoreRoots? roots,
    EditorPrefs? prefs,
    void Function(BuildContext context)? onOpenProjects,
    EditorSupport? platform,
    StoreFs fs = const LocalStoreFs(),
    StoreTimerFactory? timer,
    bool? useIsolates,
    bool startGc = true,
    bool listenToLifecycle = true,
    Duration gcStartDelay = const Duration(seconds: 30),
  }) async {
    final gate = platform ?? EditorAvailability.platform;
    if (engine == null || gate is! EditorSupported) return unavailable();
    try {
      final runtime = await createRuntime(
        engine: engine,
        roots: roots ?? await defaultRoots(),
        prefs: prefs ?? await EditorPrefs.load(),
        fs: fs,
        timer: timer,
        useIsolates: useIsolates,
        startGc: startGc,
        listenToLifecycle: listenToLifecycle,
        gcStartDelay: gcStartDelay,
      );
      return overridesFor(runtime, onOpenProjects: onOpenProjects);
    } on Object catch (e, st) {
      debugPrint('[EditorBootstrap] Editor wiring failed: $e\n$st');
      return unavailable();
    }
  }

  /// Builds the runtime (store, pool, relink, GC, compiler) for [engine].
  static Future<EditorRuntime> createRuntime({
    required EditorEngine engine,
    required StoreRoots roots,
    required EditorPrefs prefs,
    StoreFs fs = const LocalStoreFs(),
    StoreTimerFactory? timer,
    bool? useIsolates,
    bool startGc = true,
    bool listenToLifecycle = true,
    Duration gcStartDelay = const Duration(seconds: 30),
  }) async {
    if (!bindDocumentsRoot(engine.access, roots.documents)) {
      debugPrint('[EditorBootstrap] The engine access takes no Documents root');
    }
    final capabilities = await _capabilitiesOf(engine);
    await prepareWorkFolders(roots, fs: fs, access: engine.access);
    final deleter = OwnedFileDeleter(roots, fs: fs);
    final relinker = MediaRelinkService(
      access: engine.access,
      probe: engine.probe,
      roots: roots,
      fs: fs,
      deleter: deleter,
      materialize: engine.access.materializePick,
    );
    final pool = FileMediaPoolService(
      access: engine.access,
      probe: engine.probe,
      roots: roots,
      fs: fs,
      deleter: deleter,
      freeSpace: engine.freeBytes,
      relinker: relinker,
      materialize: engine.access.materializePick,
    );
    final exportGate = EditorExportGate(engine.exporter);
    late final GcScheduler gcScheduler;
    late final FileProjectRepository repository;
    final allow2160 = capabilities != null && capabilities.maxExportSize.shortestSide >= 2160;
    repository = FileProjectRepository(
      roots: roots,
      fs: fs,
      deleter: deleter,
      useIsolates: useIsolates,
      media: pool,
      access: engine.access,
      allow2160: allow2160,
      poster: EditorPosterCapture.capture,
      onProjectDeleted: (ProjectId id, ProjectRefs? refs) async {
        await exportGate.refresh();
        await gcScheduler.projectDeleted(refs);
      },
      timer: timer,
    );
    final gc = MediaGarbageCollector(
      roots: roots,
      fs: fs,
      deleter: deleter,
      access: engine.access,
      openSessions: () => repository.openSessions,
      openProjects: () => repository.openProjects,
      inFlightQuickHashes: () => pool.inFlightQuickHashes,
      // Derived jobs (proxy, reverse, freeze) belong to open sessions, whose projects are marked
      // through openSessions/openProjects; their outputs are also younger than the 24 h grace.
      exportInProgress: () => exportGate.inProgress,
    );
    final makeTimer = timer ?? Timer.new;
    gcScheduler = GcScheduler(
      gc,
      startDelay: gcStartDelay,
      // Every scheduled run refreshes the export gate first (the GC checks it synchronously).
      timer: (duration, callback) => makeTimer(duration, () => unawaited(exportGate.refresh().whenComplete(callback))),
    );
    final runtime = EditorRuntime._(
      engine: engine,
      roots: roots,
      prefs: prefs,
      capabilities: capabilities,
      pool: pool,
      relinker: relinker,
      repository: repository,
      compiler: DefaultPlanCompiler(
        access: engine.access,
        roots: roots,
        availability: (session) => relinker.monitorOf(session).last,
      ),
      gc: gc,
      gcScheduler: gcScheduler,
      exportGate: exportGate,
      renderPreview: IndexRenderPreviewStore(
        RenderCacheIndex(
          roots: roots,
          deleter: deleter,
          fs: fs,
          limitBytes: RenderCacheIndex.limitForTier(
            (capabilities == null ? EditorTierDefaults.fallback : EditorTierDefaults.of(capabilities)).renderTier,
          ),
        ),
      ),
    );
    if (startGc) gcScheduler.start();
    if (listenToLifecycle) runtime._listenToLifecycle();
    return runtime;
  }

  /// The `ProviderScope` overrides of [runtime]. With [onOpenProjects] the editor's Settings ›
  /// Storage contributors are listed (ARCH §17.10).
  static List<Override> overridesFor(EditorRuntime runtime, {void Function(BuildContext context)? onOpenProjects}) {
    final caps = runtime.capabilities;
    final repository = runtime.repository;
    final engine = runtime.engine;
    return [
      editorRuntimeProvider.overrideWithValue(runtime),
      editorEngineProvider.overrideWithValue(engine),
      projectRepositoryProvider.overrideWithValue(repository),
      mediaPoolServiceProvider.overrideWithValue(runtime.pool),
      editorPrefsProvider.overrideWithValue(runtime.prefs),
      planCompilerPortProvider.overrideWithValue(runtime.compiler),
      renderPreviewStoreProvider.overrideWithValue(runtime.renderPreview),
      if (caps != null) editorCapabilitiesProvider.overrideWith((ref) async => caps),
      storageContributorsProvider.overrideWithValue(
        onOpenProjects == null
            ? const <StorageContributor>[]
            : EditorStorageContributor.all(
                repository: repository,
                cache: EditorCacheCleaner(
                  roots: runtime.roots,
                  trimEngine: () => engine.trimCaches(CacheTrimLevel.clearAll),
                ),
                cacheUse: editorCacheUseOf(openProjects: () => repository.openIds, exporter: engine.exporter),
                onOpenProjects: onOpenProjects,
              ),
      ),
    ];
  }

  /// QA-05 D8: creates the exports folder (`StoreRoots.exportsDir`, under Application Support /
  /// `files/`, so a low-storage purge of the cache cannot delete a running export) and excludes it
  /// from backups, and recreates the cache's `work/` folders the system may have purged. Never
  /// throws; each user creates its folder again before use.
  ///
  /// Nothing is moved from the old `<cache>/danaview/editor/work/export-*` location: the engines'
  /// job records hold those absolute paths (a running, kept or detached export), so a move would
  /// break them, and anything else there is a purgeable leftover the cache cleanup removes.
  static Future<void> prepareWorkFolders(StoreRoots roots, {StoreFs fs = const LocalStoreFs(), MediaAccessPort? access}) async {
    for (final dir in [roots.exportsDir, roots.workDir]) {
      try {
        await fs.createDirectory(dir);
      } on Object catch (e) {
        debugPrint('[EditorBootstrap] Could not create ${p.basename(dir)}/: ${e.runtimeType}');
      }
    }
    if (access == null) return;
    try {
      await access.excludeFromBackup(roots.exportsDir);
    } on Object catch (e) {
      debugPrint('[EditorBootstrap] Could not exclude exports/ from backups: ${e.runtimeType}');
    }
  }

  static Future<EditorCapabilities?> _capabilitiesOf(EditorEngine engine) async {
    try {
      return await engine.capabilities().timeout(capabilitiesTimeout);
    } on Object catch (e) {
      debugPrint('[EditorBootstrap] Capabilities unavailable at start: ${e.runtimeType}');
      return null;
    }
  }
}
