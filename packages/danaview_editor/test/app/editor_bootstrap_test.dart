// OWNER: INT-02
//
// EditorBootstrap (ARCH §4.1, §8, §9, §17.3): the overrides it returns on supported and hidden
// platforms, the wiring of the store, pool, relink, GC (30 s start, export gate, delete hook), plan
// compiler, capabilities and Settings › Storage contributors.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_availability.dart';
import 'package:danaview_editor/src/app/editor_bootstrap.dart';
import 'package:danaview_editor/src/app/editor_prefs.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/app/editor_storage_contributor.dart';
import 'package:danaview_editor/src/editor/state/default_plan_compiler.dart';
import 'package:danaview_editor/src/editor/state/plan_compiler_port.dart';
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

  test('engine config uses the editor roots', () {
    final config = EditorBootstrap.engineConfigOf(_roots);
    expect(config.cacheRoot, '/fake/cache/danaview/editor');
    expect(config.supportRoot, '/fake/support/danaview/editor');
  });
}
