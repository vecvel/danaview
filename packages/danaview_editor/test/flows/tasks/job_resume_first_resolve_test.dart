// OWNER: FIX-QA05-D5
//
// QA-05 re-run D5: jobs re-queued on open raced the first media resolve. INT-02's session compiler
// answers `resolve` from a snapshot it fills before each plan compile; before the first compile
// finishes every media reads offline. The Tasks controller started (in a microtask after attach)
// before that, so a pending reverse rendition or freeze still failed for good with `mediaOffline`
// and a pending proxy stayed pending with no task. The rig compiler here behaves like INT-02's: its
// snapshot is empty until the first (gated, async) compile resolved the media.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/editor_scope.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_dock.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_host.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/state/plan_compiler_port.dart';
import 'package:danaview_editor/src/editor/state/tasks_controller.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show EditSession;
import 'package:danaview_editor_core/plan.dart' show MapPlanAssetResolver;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart'
    show EditorCapabilities, EngineError, EngineErrorCode, EngineMedia, GeneratedAsset, PlanTransient, RenderPlan;
import 'package:danaview_editor_engine_api/testing.dart';

import '../../support/support.dart';
import 'tasks_rig.dart';

final String _videoHash = 'md_video'.padRight(40, '0');

MediaAsset _staleRendition() => rigAsset('md_rev', MediaKind.video,
    status: const PendingStatus('reverse-before-kill'),
    derived: ReversedSpec(TaskIds.videoMedia, const TimeRange(3 * s, 19 * s), sourceQuickHash: _videoHash));

MediaAsset _staleStill() => rigAsset('md_still', MediaKind.still,
    hasAudio: false, status: const PendingStatus('freeze-before-kill'), derived: StillSpec(TaskIds.videoMedia, 2 * s, sourceQuickHash: _videoHash));

MediaClip get _reversedVideo => rigClip('it_video', 'md_video', 0, 12 * s, sourceIn: 5 * s, reversed: true);

/// Like INT-02's `DefaultPlanCompiler`: `resolve` reads a snapshot that each compile refreshes
/// first (asynchronously); the first refresh waits for [firstResolve]. Media in [offline] do not
/// resolve.
final class _LateResolvingPort implements PlanCompilerPort {
  final Completer<void> firstResolve = Completer<void>();
  final Set<MediaId> offline = {};
  int compiles = 0;

  @override
  SessionPlanCompiler forSession(EditSession session, EditorCapabilities capabilities) => _LateCompiler(this);
}

final class _LateCompiler implements SessionPlanCompiler {
  _LateCompiler(this._port) {
    _inner = ResolvingSessionPlanCompiler((_) => _snapshot);
  }

  final _LateResolvingPort _port;
  late final ResolvingSessionPlanCompiler _inner;
  MapPlanAssetResolver _snapshot = MapPlanAssetResolver.empty;

  @override
  Future<RenderPlan> compile(EditProject project) async {
    _port.compiles++;
    // The gate's future belongs to the test's fake-async zone: await it only while it is open.
    if (!_port.firstResolve.isCompleted) await _port.firstResolve.future;
    // An async gap without a timer (fake-async safe), as INT-02's platform resolves are.
    await Future<void>.microtask(() {});
    _snapshot = MapPlanAssetResolver(originals: {
      for (final a in project.pool.assets.values)
        if (a.status is ReadyStatus && !_port.offline.contains(a.id))
          a.id: ResolvedMedia(uri: 'file:///media/${a.id.value}', fingerprint: a.fingerprint.quickHash),
    });
    return _inner.compile(project);
  }

  @override
  PlanTransient? transientFor(EditProject working, ItemId item) => _inner.transientFor(working, item);

  @override
  EngineMedia? resolve(EditProject project, MediaId media) => _snapshot.original(media);

  @override
  void trim() => _inner.trim();
}

final class _Rig {
  _Rig(this.harness, this.id, this.tester, this.port);

  final EditorTestHarness harness;
  final ProjectId id;
  final WidgetTester tester;
  final _LateResolvingPort port;
  Future<void>? opening;

  FakeEditorEngine get engine => harness.engine;
  EditorController get editor => harness.containerOf(tester).read(editorControllerProvider(id).notifier);
  EditorState get state => harness.containerOf(tester).read(editorControllerProvider(id));
  MediaAsset asset(String id) => state.project!.pool[MediaId(id)]!;
  List<FakeMediaJob<Object?>> jobs(String kind) => [for (final j in engine.jobs.created) if (j.id.startsWith('$kind-')) j];

  /// Pumps the editor and starts opening it (the first plan waits for [_LateResolvingPort.firstResolve]).
  static Future<_Rig> pump(WidgetTester tester, {MediaClip? video, List<MediaAsset> extraAssets = const [], FakeEditorEngine? engine}) async {
    EditorAnnouncer.instance.reset();
    final repo = FakeProjectRepository();
    final empty = repo.seedEmpty('Tasks');
    final project = tasksProject(empty.id, video: video, extraAssets: extraAssets);
    repo.seed(project);
    final port = _LateResolvingPort();
    final harness = EditorTestHarness(
      engine: engine ?? FakeEditorEngine(validatePlans: false),
      repository: repo,
      mediaPool: ScriptedPool(),
      overrides: [planCompilerPortProvider.overrideWithValue(port)],
    );
    final rig = _Rig(harness, project.id, tester, port);
    await harness.pumpApp(
      tester,
      EditorScope(
        projectId: project.id,
        child: const RegionFrame(inspectorOpen: true, regions: {EditorRegion.pane: InspectorHost()}, dock: InspectorDock()),
      ),
      surface: const EditorSurface(Size(1280, 900)),
    );
    await rig.real(() async {
      rig.opening = rig.editor.open();
    });
    return rig;
  }

  Future<void> real(Future<void> Function() body) async {
    await tester.runAsync(() async {
      await body();
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
    await tester.pump();
  }

  /// Lets the first media resolve (and the first plan) finish.
  Future<void> resolveFirst() => real(() async {
        port.firstResolve.complete();
        await opening;
      });

  Future<void> finish() async {
    await tester.pump(const Duration(seconds: 1));
    EditorAnnouncer.instance.reset();
  }
}

void main() {
  testWidgets('a pending reverse rendition waits for the first media resolve, then resumes (not mediaOffline)', (tester) async {
    final rig = await _Rig.pump(tester, video: _reversedVideo, extraAssets: [_staleRendition()]);
    expect(rig.state.phase, EditorPhase.ready, reason: 'the session is attached; the first plan is still compiling');
    expect(rig.jobs('reverse'), isEmpty);
    expect(rig.asset('md_rev').status, const PendingStatus('reverse-before-kill'), reason: 'not failed as offline before the resolve');
    expect(rig.state.tasks.where((t) => t.failed), isEmpty);

    await rig.resolveFirst();
    final reverse = rig.jobs('reverse');
    expect(reverse, hasLength(1), reason: 're-queued once the media resolved');
    expect(rig.asset('md_rev').status, PendingStatus(reverse.single.id));
    await rig.real(() async => reverse.single.complete(GeneratedAsset(path: '/out/r', sizeBytes: 4096, duration: 16 * s)));
    expect(rig.asset('md_rev').status, isA<ReadyStatus>());
    expect(rig.jobs('reverse'), hasLength(1));
    await rig.finish();
  });

  testWidgets('a pending freeze still waits for the first media resolve, then resumes', (tester) async {
    final rig = await _Rig.pump(tester, video: rigClip('it_video', 'md_still', 0, 2 * s), extraAssets: [_staleStill()]);
    expect(rig.jobs('freezeFrame'), isEmpty);
    expect(rig.asset('md_still').status, const PendingStatus('freeze-before-kill'));

    await rig.resolveFirst();
    final freeze = rig.jobs('freezeFrame');
    expect(freeze, hasLength(1));
    expect(rig.asset('md_still').status, PendingStatus(freeze.single.id));
    await rig.finish();
  });

  testWidgets('a pending proxy resumes after the first media resolve with no user action', (tester) async {
    final rig = await _Rig.pump(tester, extraAssets: [rigAsset('md_proxied', MediaKind.video).copyWith(proxy: ProxyState.pending)]);
    expect(rig.jobs('proxy'), isEmpty);
    await rig.resolveFirst();
    final proxy = rig.jobs('proxy');
    expect(proxy, hasLength(1));
    await rig.real(() async => proxy.single.complete(GeneratedAsset(path: '/out/p', sizeBytes: 4096)));
    expect(rig.asset('md_proxied').proxy, ProxyState.ready);
    await rig.finish();
  });

  testWidgets('a resumed proxy whose media is offline stays pending and starts on a later resolve', (tester) async {
    final rig = await _Rig.pump(tester, extraAssets: [rigAsset('md_proxied', MediaKind.video).copyWith(proxy: ProxyState.pending)]);
    rig.port.offline.add(const MediaId('md_proxied'));
    await rig.resolveFirst();
    expect(rig.jobs('proxy'), isEmpty);
    expect(rig.asset('md_proxied').proxy, ProxyState.pending);

    // The media is back; the next plan compile (here a preview restart) resolves it again.
    rig.port.offline.clear();
    final before = rig.port.compiles;
    await rig.real(() async {
      await rig.editor.restartPreview();
      await rig.harness.containerOf(tester).read(editorSessionProvider(rig.id)).planSync!.flush();
    });
    expect(rig.port.compiles, before + 1);
    expect(rig.jobs('proxy'), hasLength(1), reason: 'the pool did not change, the resolve did');
    await rig.finish();
  });

  testWidgets('without a preview the media still resolves once, and the jobs resume', (tester) async {
    final engine = FakeEditorEngine(validatePlans: false);
    engine.failNext['openPreview'] = const EngineError(EngineErrorCode.internal, debugDetail: 'no preview');
    final rig = await _Rig.pump(tester, video: _reversedVideo, extraAssets: [_staleRendition()], engine: engine);
    expect(rig.state.preview.phase, PreviewPhase.failed);
    expect(rig.asset('md_rev').status, const PendingStatus('reverse-before-kill'));
    await rig.resolveFirst();
    expect(rig.port.compiles, 1, reason: 'one warm-up compile');
    expect(rig.jobs('reverse'), hasLength(1));
    await rig.finish();
  });

  testWidgets('a user reverse before the first resolve starts after it, not failed offline', (tester) async {
    final rig = await _Rig.pump(tester);
    final tasks = rig.harness.containerOf(tester).read(tasksControllerProvider(rig.id));
    await rig.real(() async => tasks.reverse(TaskIds.video, on: true));
    expect(rig.jobs('reverse'), isEmpty);
    final rendition = TasksController.renditionFor(rig.state.project!.pool, rig.state.project!.index.item(TaskIds.video)! as MediaClip);
    expect(rendition?.status, isA<PendingStatus>());
    await rig.resolveFirst();
    expect(rig.jobs('reverse'), hasLength(1));
    await rig.finish();
  });
}
