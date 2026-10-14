// OWNER: UX-29
//
// A rig for the Format panel, Project sheet and History sheet tests: the editor harness with a real
// EditorController opened over FakeEditorEngine (its PlanSyncs count `schedule` calls), the
// inspector region (real InspectorHost / InspectorDock) and a launcher element whose context runs
// actions the way the top bar does.
//
// Project (30 fps, 16:9, 1080p, black background): main lane A 0-4 s and B 4-8 s of `m_a`, a 4:3
// 1440x1080 source at 25 fps (so "Original" is 4:3 and "Match first clip" is 25 fps), an audio clip
// and one marker at 2 s.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/editor_scope.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_dock.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_host.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/state/plan_compiler_port.dart';
import 'package:danaview_editor/src/editor/state/playhead_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show EditSession;
import 'package:danaview_editor_core/store.dart' show LoadedProject, ProjectHealth, SaveReason, SaveReceipt;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show EditorCapabilities;
import 'package:danaview_editor_engine_api/testing.dart';

import '../../inspector/inspector_rig.dart' show RegionFrame, RigTicker;
import '../../state/state_support.dart' show CountingPlanSync;
import '../../support/support.dart';

const int s = microsPerSecond;

/// Key of the launcher element (the context actions run in).
const ValueKey<String> launcherKey = ValueKey<String>('project-rig.launcher');

/// A fake repository that records the reason of every save.
class RecordingRepository extends FakeProjectRepository {
  /// Reasons of the saves, in order.
  final List<SaveReason> reasons = [];

  @override
  Future<SaveReceipt> save(EditSession session, {required SaveReason reason}) {
    reasons.add(reason);
    return super.save(session, reason: reason);
  }
}

MediaAsset _asset(String id, MediaKind kind, {int width = 1440, int height = 1080, double? fps = 25}) => MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: '$id.file',
      locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/media/$id/file'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000, quickHash: id.padRight(40, '0')),
      probe: MediaProbe(
        kind: kind,
        duration: 60 * s,
        hasVideo: kind != MediaKind.audio,
        hasAudio: true,
        width: kind == MediaKind.audio ? null : width,
        height: kind == MediaKind.audio ? null : height,
        nominalFps: kind == MediaKind.video ? fps : null,
      ),
      origin: MediaOrigin.files,
      addedAt: DateTime.utc(2026, 10, 1),
    );

MediaClip _clip(String id, String media, TimeUs start, TimeUs duration, {bool visual = true}) => MediaClip(
      id: ItemId(id),
      start: start,
      duration: duration,
      media: MediaId(media),
      visual: visual ? const VisualProps() : null,
    );

/// The rig's project; [empty] has no items and no markers.
EditProject projectRigProject(ProjectId id, {bool empty = false, String name = 'Holiday edit'}) => EditProject(
      id: id,
      meta: ProjectMeta(name: name, createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1)),
      timeline: Timeline(
        tracks: [
          Track(
            id: const TrackId('tr_main'),
            kind: TrackKind.video,
            isMain: true,
            items: empty ? const [] : [_clip('it_a', 'm_a', 0, 4 * s), _clip('it_b', 'm_a', 4 * s, 4 * s)],
          ),
          Track(
            id: const TrackId('tr_audio'),
            kind: TrackKind.audio,
            items: empty ? const [] : [_clip('it_song', 'm_song', 0, 6 * s, visual: false)],
          ),
        ],
        markers: empty ? const [] : const [Marker(id: MarkerId('mk_1'), time: 2 * s, name: 'Beat')],
      ),
      pool: MediaPool({
        for (final a in [_asset('m_a', MediaKind.video), _asset('m_song', MediaKind.audio)]) a.id: a,
      }),
    );

/// Places the launcher (a plain box whose context runs actions) above the inspector frame.
class _RigHome extends StatelessWidget {
  const _RigHome({required this.withPanel});

  final bool withPanel;

  @override
  Widget build(BuildContext context) => Stack(children: [
        if (withPanel)
          const Positioned.fill(
            child: RegionFrame(
              inspectorOpen: true,
              regions: {EditorRegion.pane: InspectorHost()},
              dock: InspectorDock(),
            ),
          ),
        const Positioned(left: 0, top: 0, width: 1, height: 1, child: SizedBox(key: launcherKey)),
      ]);
}

/// The harness with a real, opened EditorController.
class ProjectRig {
  ProjectRig._(this.harness, this.id, this.tester);

  /// Harness.
  final EditorTestHarness harness;

  /// Project id.
  final ProjectId id;

  /// Tester.
  final WidgetTester tester;

  /// Every PlanSync the controller made (the last one is live).
  final List<CountingPlanSync> syncs = [];

  /// The live PlanSync.
  CountingPlanSync get sync => syncs.last;

  /// The repository.
  RecordingRepository get repository => harness.repository as RecordingRepository;

  /// The fake engine.
  FakeEditorEngine get engine => harness.engine;

  /// The container of the pumped app.
  ProviderContainer get container => harness.containerOf(tester);

  /// The editor controller.
  EditorController get editor => container.read(editorControllerProvider(id).notifier);

  /// The editor state.
  EditorState get state => container.read(editorControllerProvider(id));

  /// The working project.
  EditProject get project => state.project!;

  /// Project settings.
  ProjectSettings get settings => project.settings;

  /// The history position.
  int get entries => state.history.position;

  /// Labels of every history entry, oldest first.
  List<String> get labels => [for (final e in editor.session.historyEntries) e.label];

  /// An action context over the launcher element (like the top bar's).
  WidgetActionContext get ctx =>
      WidgetActionContext.container(projectId: id, context: tester.element(find.byKey(launcherKey)), container: container);

  /// The registry.
  EditorActionRegistry get registry => container.read(editorActionRegistryProvider);

  /// Pumps the rig. [withPanel] places the inspector region; [openFormat] opens the Format panel;
  /// [open] opens the editor; [readOnly] opens the project read-only (newer schema).
  static Future<ProjectRig> pump(
    WidgetTester tester, {
    EditorSurface surface = const EditorSurface(Size(1280, 900)),
    bool withPanel = true,
    bool openFormat = false,
    bool open = true,
    bool empty = false,
    bool readOnly = false,
    String name = 'Holiday edit',
    EditorCapabilities? caps,
    List<Override> overrides = const [],
  }) async {
    final repo = RecordingRepository();
    final seeded = repo.seedEmpty(name);
    final project = projectRigProject(seeded.id, empty: empty, name: name);
    repo.seed(project);
    if (readOnly) repo.openResults[project.id] = (p) => LoadedProject(project: p, health: ProjectHealth.readOnlyNewer);
    final ticker = RigTicker();
    final engine = FakeEditorEngine(validatePlans: false);
    if (caps != null) engine.caps = caps;
    late final ProjectRig rig;
    final harness = EditorTestHarness(
      engine: engine,
      repository: repo,
      overrides: [
        playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: () => Duration.zero)),
        editorControllerProvider.overrideWith((ref, pid) {
          final session = ref.watch(editorSessionProvider(pid));
          final link = ref.keepAlive();
          final controller = EditorController(
            id: pid,
            session: session,
            repository: ref.read(projectRepositoryProvider),
            engine: ref.read(editorEngineProvider),
            prefs: ref.read(editorPrefsProvider),
            compilers: ref.read(planCompilerPortProvider),
            planSyncFactory: (preview, compile) {
              final sync = CountingPlanSync(preview, compile: compile);
              rig.syncs.add(sync);
              return sync;
            },
          );
          controller.onReleased = link.close;
          return controller;
        }),
        ...overrides,
      ],
    );
    rig = ProjectRig._(harness, project.id, tester);
    await harness.pumpApp(tester, EditorScope(projectId: project.id, child: _RigHome(withPanel: withPanel)), surface: surface);
    if (open) await rig.real(() => rig.editor.open());
    if (openFormat) {
      rig.editor.openInspector(const CanvasInspector());
    }
    await tester.pump();
    await tester.pump();
    return rig;
  }

  /// Runs [body] with real async and pumps.
  Future<void> real(Future<void> Function() body) async {
    await tester.runAsync(() async {
      await body();
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
  }

  /// Invokes [action] from the launcher and lets sheets animate in.
  Future<EditorActionResult> invoke(EditorActionId action) async {
    final result = registry.invoke(action, ctx);
    await tester.pumpAndSettle();
    return result;
  }
}
