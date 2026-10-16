// OWNER: INT-02
//
// EditorBootstrap (ARCH §4.1, §8, §9, §17.3): the overrides it returns on supported and hidden
// platforms, the wiring of the store, pool, relink, GC (30 s start, export gate, delete hook), plan
// compiler, capabilities and Settings › Storage contributors; FIX-WIRING: the Documents root
// handed to the engine's access (FIX-INT-02-1), `materializePick` passed to the pool and relink
// service and the localized export notification texts in the engine config (INT-07).

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_availability.dart';
import 'package:danaview_editor/src/app/editor_bootstrap.dart';
import 'package:danaview_editor/src/app/editor_prefs.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/app/editor_storage_contributor.dart';
import 'package:danaview_editor/src/app/strings/export_strings.dart';
import 'package:danaview_editor/src/editor/state/default_plan_compiler.dart';
import 'package:danaview_editor/src/editor/state/plan_compiler_port.dart';
import 'package:danaview_editor_core/model.dart'
    show AppRelativeLocator, AppRoot, MediaAccessFailure, MediaAccessFailureKind, MediaLocator, MediaStat, PickedMedia, PickedMediaHandle, ResolvedMedia;
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_core/testing.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_features/storage.dart';

const _roots = StoreRoots(support: '/fake/support', cache: '/fake/cache', documents: '/fake/documents');

class _ManualTimer implements Timer {
  _ManualTimer(this.duration, this.callback);

  final Duration duration;
  final void Function() callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

class _Timers {
  final List<_ManualTimer> all = [];

  Timer call(Duration d, void Function() cb) {
    final t = _ManualTimer(d, cb);
    all.add(t);
    return t;
  }

  List<_ManualTimer> after(Duration d) => all.where((t) => t.duration == d && t.isActive).toList();
}

class _FailingExporter implements ExportService {
  @override
  Future<List<ExportJobState>> activeJobs() async => throw StateError('no engine');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A media access that, like the platform `MobileMediaAccess`, takes a settable Documents root and
/// cannot resolve `AppRelativeLocator(documents, …)` without it.
final class _DocsAccess implements MediaAccess {
  _DocsAccess(this.inner);

  final FakeMediaAccess inner;

  String? documentsRoot;

  @override
  Future<ResolvedMedia> resolve(MediaLocator locator) async {
    if (locator is AppRelativeLocator && locator.root == AppRoot.documents) {
      final root = documentsRoot;
      if (root == null) throw const MediaAccessFailure(MediaAccessFailureKind.accessLost, 'documents root not available');
      return ResolvedMedia(uri: Uri.file('$root/${locator.relPath}').toString(), fingerprint: 'docs');
    }
    return inner.resolve(locator);
  }

  @override
  Future<MediaStat?> stat(MediaLocator locator) => inner.stat(locator);

  @override
  Future<String> quickHash(MediaLocator locator) => inner.quickHash(locator);

  @override
  Future<MediaLocator> persist(PickedMediaHandle handle) => inner.persist(handle);

  @override
  Future<void> release(MediaLocator locator) => inner.release(locator);

  @override
  Future<void> excludeFromBackup(String dirPath) => inner.excludeFromBackup(dirPath);

  @override
  Future<int> remainingGrantBudget() => inner.remainingGrantBudget();

  @override
  Future<bool> requestNotificationPermission() => inner.requestNotificationPermission();

  @override
  Future<String> materializePick(PickedMedia picked, String intoDir) => inner.materializePick(picked, intoDir);
}

/// [FakeEditorEngine] with [_DocsAccess] as its access (the shape of the platform engine).
final class _DocsEngine implements EditorEngine {
  _DocsEngine(this.inner) : access = _DocsAccess(inner.access);

  final FakeEditorEngine inner;

  @override
  final _DocsAccess access;

  @override
  Future<EditorCapabilities> capabilities() => inner.capabilities();

  @override
  Future<EditCompatibility> compatibility(String pathOrUri) => inner.compatibility(pathOrUri);

  @override
  Future<MediaProbe> probe(EngineMedia media) => inner.probe(media);

  @override
  Future<PreviewSession> openPreview(PreviewConfig config) => inner.openPreview(config);

  @override
  ThumbnailSource get thumbnails => inner.thumbnails;

  @override
  WaveformSource get waveforms => inner.waveforms;

  @override
  MediaJobs get jobs => inner.jobs;

  @override
  ExportService get exporter => inner.exporter;

  @override
  VoiceRecorder? get voiceRecorder => inner.voiceRecorder;

  @override
  MediaPicker get picker => inner.picker;

  @override
  FileHandoff get files => inner.files;

  @override
  BackgroundWorkGuard get background => inner.background;

  @override
  ExternalDropTarget get drops => inner.drops;

  @override
  Future<int> freeBytes(String path) => inner.freeBytes(path);

  @override
  Stream<EngineSignal> get signals => inner.signals;

  @override
  Future<void> trimCaches(CacheTrimLevel level) => inner.trimCaches(level);
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeEditorEngine engine;
  late _Timers timers;
  late MemoryStoreFs fs;

  setUp(() {
    engine = FakeEditorEngine();
    timers = _Timers();
    fs = MemoryStoreFs();
  });

  Future<List<Override>> create({
    EditorSupport platform = const EditorSupported(),
    void Function(BuildContext)? onOpenProjects,
    bool noEngine = false,
  }) =>
      EditorBootstrap.create(
        engine: noEngine ? null : engine,
        roots: _roots,
        prefs: EditorPrefs.memory(),
        platform: platform,
        fs: fs,
        timer: timers.call,
        listenToLifecycle: false,
        onOpenProjects: onOpenProjects,
      );

  ProviderContainer containerOf(List<Override> overrides) {
    final c = ProviderContainer(overrides: overrides);
    addTearDown(() async {
      await c.read(editorRuntimeProvider)?.dispose();
      c.dispose();
    });
    return c;
  }

  group('hidden editor', () {
    for (final (name, platform, noEngine) in [
      ('desktop platform', const EditorHidden(EditorHiddenReason.platform), false),
      ('DANAVIEW_EDITOR off', const EditorHidden(EditorHiddenReason.flagOff), false),
      ('no engine', const EditorSupported(), true),
    ]) {
      test('$name: no runtime, no contributors, root providers unconfigured', () async {
        final c = containerOf(await create(platform: platform, noEngine: noEngine, onOpenProjects: (_) {}));
        expect(c.read(editorRuntimeProvider), isNull);
        expect(c.read(storageContributorsProvider), isEmpty);
        expect(() => c.read(projectRepositoryProvider), throwsA(isA<EditorNotConfiguredError>()));
        expect(() => c.read(editorEngineProvider), throwsA(isA<EditorNotConfiguredError>()));
        expect(engine.log.calls, isEmpty, reason: 'a hidden editor never touches the engine');
      });
    }
  });

  group('supported platform', () {
    test('overrides every root provider with the wired runtime', () async {
      final c = containerOf(await create());
      final runtime = c.read(editorRuntimeProvider)!;

      expect(c.read(editorEngineProvider), same(engine));
      expect(c.read(projectRepositoryProvider), same(runtime.repository));
      expect(c.read(projectRepositoryProvider), isA<FileProjectRepository>());
      final pool = c.read(mediaPoolServiceProvider);
      expect(pool, same(runtime.pool));
      expect(runtime.pool.freeSpace, isNotNull, reason: 'core preflight backs up the UI preflight');
      expect(runtime.pool.relinker, same(runtime.relinker));
      expect(runtime.pool.access, same(engine.access));
      expect(runtime.pool.roots, _roots);
      expect(c.read(planCompilerPortProvider), isA<DefaultPlanCompiler>());
      expect(await c.read(editorCapabilitiesProvider.future), fakeDefaultCapabilities);
      expect(runtime.capabilities, fakeDefaultCapabilities);
      expect(c.read(editorPrefsProvider), same(runtime.prefs));
    });

    test('the repository lists, creates and opens projects through the wired store', () async {
      final c = containerOf(await create());
      final repo = c.read(projectRepositoryProvider);
      final id = await repo.create(const EmptyProjectSpec(name: 'Holiday'));
      final summaries = await repo.watchSummaries().first;
      expect(summaries.map((s) => s.name), contains('Holiday'));
      final loaded = await repo.open(id);
      expect(loaded.project.id, id);
      await repo.close(id);
    });

    test('Settings › Storage lists the projects and cache contributors only with Projects navigation', () async {
      var opened = 0;
      final withNav = containerOf(await create(onOpenProjects: (_) => opened++));
      final contributors = withNav.read(storageContributorsProvider);
      expect(contributors.map((c) => c.id), ['editor.projects', 'editor.cache']);
      expect(contributors.first, isA<EditorProjectsStorageContributor>());
      expect(contributors.last.ownedPaths, {_roots.editorCache});

      final withoutNav = containerOf(await create());
      expect(withoutNav.read(storageContributorsProvider), isEmpty);
      expect(opened, 0);
    });

    test('wires without capabilities when the engine cannot report them', () async {
      engine.failNext['capabilities'] = EngineFailure.of(EngineErrorCode.internal);
      final c = containerOf(await create());
      final runtime = c.read(editorRuntimeProvider)!;
      expect(runtime.capabilities, isNull);
      expect(c.read(projectRepositoryProvider), isA<FileProjectRepository>());
    });
  });

  group('garbage collection', () {
    test('the first run starts after 30 s and is skipped while an export runs', () async {
      final c = containerOf(await create());
      final runtime = c.read(editorRuntimeProvider)!;
      final start = timers.after(const Duration(seconds: 30));
      expect(start, hasLength(1));
      expect(runtime.gcScheduler.history, isEmpty);

      engine.exporter.records.add(ExportRunning(FakeExportJob('job1', '/fake/cache/danaview/editor/work/export-job1.mp4', 0)));
      start.single.fire();
      await _settle();
      expect(runtime.gcScheduler.history, hasLength(1));
      expect(runtime.gcScheduler.history.single.skipped, GcSkipReason.exportInProgress);

      engine.exporter.records.clear();
      final report = await runtime.collectGarbage();
      expect(report.skipped, isNull);
    });

    test('deleting a project runs the GC with a fresh export gate', () async {
      final c = containerOf(await create());
      final runtime = c.read(editorRuntimeProvider)!;
      final repo = c.read(projectRepositoryProvider);
      final id = await repo.create(const EmptyProjectSpec(name: 'Gone'));
      await repo.delete(id);
      await _settle();
      expect(runtime.gcScheduler.history, isNotEmpty);
      expect(runtime.gcScheduler.history.last.skipped, isNull);
      expect(engine.log.calls, contains('exporter.activeJobs'));
    });

    test('the export gate counts unknown and failed checks as an export in progress', () async {
      final gate = EditorExportGate(_FailingExporter());
      expect(gate.inProgress, isTrue);
      expect(await gate.refresh(), isTrue);

      final ok = EditorExportGate(engine.exporter);
      expect(await ok.refresh(), isFalse);
      engine.exporter.records.add(ExportRunning(FakeExportJob('j', '/x', 0)));
      expect(await ok.refresh(), isTrue);
    });
  });

  test('engine config uses the editor roots and the app copy of the export notifications', () {
    final config = EditorBootstrap.engineConfigOf(_roots);
    expect(config.cacheRoot, '/fake/cache/danaview/editor');
    expect(config.supportRoot, '/fake/support/danaview/editor');
    expect(config.exportNotificationTexts, same(ExportStrings.notificationTexts));
  });

  group('FIX-WIRING', () {
    test('FIX-INT-02-1: the runtime hands StoreRoots.documents to the engine access, so Documents media resolve', () async {
      final docsEngine = _DocsEngine(engine);
      const locator = AppRelativeLocator(AppRoot.documents, 'Imports/beach.mov');
      await expectLater(
        docsEngine.access.resolve(locator),
        throwsA(isA<MediaAccessFailure>().having((e) => e.kind, 'kind', MediaAccessFailureKind.accessLost)),
        reason: 'the defect: without the root every Documents media is access-lost',
      );

      final runtime = await EditorBootstrap.createRuntime(
        engine: docsEngine,
        roots: _roots,
        prefs: EditorPrefs.memory(),
        fs: fs,
        timer: timers.call,
        startGc: false,
        listenToLifecycle: false,
      );
      addTearDown(runtime.dispose);

      expect(docsEngine.access.documentsRoot, '/fake/documents');
      expect((await docsEngine.access.resolve(locator)).uri, 'file:///fake/documents/Imports/beach.mov');
    });

    test('FIX-INT-02-1: also through EditorBootstrap.create (the app path)', () async {
      final docsEngine = _DocsEngine(engine);
      final c = ProviderContainer(
        overrides: await EditorBootstrap.create(
          engine: docsEngine,
          roots: _roots,
          prefs: EditorPrefs.memory(),
          platform: const EditorSupported(),
          fs: fs,
          timer: timers.call,
          listenToLifecycle: false,
        ),
      );
      addTearDown(() async {
        await c.read(editorRuntimeProvider)?.dispose();
        c.dispose();
      });
      expect(c.read(editorRuntimeProvider), isNotNull);
      expect(docsEngine.access.documentsRoot, _roots.documents);
    });

    test('bindDocumentsRoot leaves an access without the setter alone', () {
      expect(EditorBootstrap.bindDocumentsRoot(engine.access, '/fake/documents'), isFalse);
      final docs = _DocsAccess(engine.access);
      expect(EditorBootstrap.bindDocumentsRoot(docs, '/d'), isTrue);
      expect(docs.documentsRoot, '/d');
    });

    test('an engine access without a Documents root still wires (fakes, desktop stubs)', () async {
      final c = containerOf(await create());
      expect(c.read(editorRuntimeProvider), isNotNull);
    });

    test('INT-07: the pool and the relink service copy non-persistable picks through engine.access.materializePick', () async {
      final c = containerOf(await create());
      final runtime = c.read(editorRuntimeProvider)!;
      expect(runtime.pool.materialize, isNotNull);
      expect(runtime.relinker.materialize, isNotNull);
      expect(runtime.pool.materialize, engine.access.materializePick);
      expect(runtime.relinker.materialize, engine.access.materializePick);

      const pick = PickedMedia(uri: 'content://media/42', displayName: 'clip.mp4');
      final out = await runtime.pool.materialize!(pick, _roots.picksDir);
      expect(engine.access.materialized, [out]);
      final again = await runtime.relinker.materialize!(pick, _roots.picksDir);
      expect(engine.access.materialized, [out, again]);
    });
  });
}
