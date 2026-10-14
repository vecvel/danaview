// OWNER: UX-35
//
// A rig for the freeze / reverse / replace / clip info / tasks tests: the editor harness with a real
// EditorController opened over FakeEditorEngine (scriptable media jobs) on a project with a video
// clip, a silent video, an image and audio, every asset resolvable, the real inspector host in the
// pane region and UX-06's scripted pool for replacements.

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
import 'package:danaview_editor/src/editor/state/tasks_controller.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart' show MapPlanAssetResolver;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show GeneratedAsset;
import 'package:danaview_editor_engine_api/testing.dart';

import '../../flows/import/import_fakes.dart';
import '../../inspector/inspector_rig.dart' show RegionFrame, RigTicker;
import '../../support/support.dart';

export '../../flows/import/import_fakes.dart' show AddStep, ScriptedPool, pickOf;
export '../../inspector/inspector_rig.dart' show RegionFrame;

const int s = microsPerSecond;

/// The frame grid of the rig's project.
final FrameRate rate = FrameRate.fps30;

/// Ids of the rig's project.
abstract final class TaskIds {
  /// Main video clip 0-12 s of `md_video` (60 s, with audio), source 5-17 s.
  static const ItemId video = ItemId('it_video');

  /// Main silent video clip 12-14 s.
  static const ItemId silent = ItemId('it_silent');

  /// Main image clip 14-16 s.
  static const ItemId image = ItemId('it_image');

  /// Audio clip 0-10 s of `md_song`.
  static const ItemId audio = ItemId('it_audio');

  /// Video clip 0-4 s on a locked overlay lane.
  static const ItemId locked = ItemId('it_locked');

  /// Media.
  static const MediaId videoMedia = MediaId('md_video');
}

MediaAsset rigAsset(String id, MediaKind kind, {bool hasAudio = true, String? name, AssetStatus status = AssetStatus.ready, DerivedSpec? derived}) =>
    MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: name ?? '$id.file',
      locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/media/$id/file'),
      ownership: derived == null ? MediaOwnership.managedCopy : MediaOwnership.projectOwned,
      fingerprint: MediaFingerprint(sizeBytes: 12345678, quickHash: id.padRight(40, '0')),
      probe: MediaProbe(
        kind: kind,
        duration: kind == MediaKind.image || kind == MediaKind.still ? 0 : 60 * s,
        hasVideo: kind != MediaKind.audio,
        hasAudio: hasAudio,
        width: kind == MediaKind.audio ? null : 1920,
        height: kind == MediaKind.audio ? null : 1080,
        nominalFps: kind == MediaKind.video ? 30 : null,
        videoCodec: kind == MediaKind.video ? 'h264' : null,
        audioCodec: hasAudio ? 'aac' : null,
        channels: hasAudio ? 2 : null,
        sampleRate: hasAudio ? 48000 : null,
      ),
      origin: derived == null ? MediaOrigin.files : MediaOrigin.derived,
      derived: derived,
      status: status,
      addedAt: DateTime.utc(2026, 10, 1),
    );

MediaClip rigClip(String id, String media, TimeUs start, TimeUs duration, {bool visual = true, TimeUs sourceIn = 0, bool reversed = false}) =>
    MediaClip(
      id: ItemId(id),
      start: start,
      duration: duration,
      media: MediaId(media),
      sourceIn: sourceIn,
      reversed: reversed,
      visual: visual ? const VisualProps() : null,
      audio: AudioProps.unity,
    );

/// The project of the rig; [extraAssets] and [video] customize it.
EditProject tasksProject(ProjectId id, {MediaClip? video, List<MediaAsset> extraAssets = const [], bool ripple = true}) => EditProject(
      id: id,
      meta: ProjectMeta(name: 'Tasks', createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1)),
      timeline: Timeline(
        tracks: [
          Track(id: const TrackId('tr_main'), kind: TrackKind.video, isMain: true, items: [
            video ?? rigClip('it_video', 'md_video', 0, 12 * s, sourceIn: 5 * s),
            rigClip('it_silent', 'md_silent', 12 * s, 2 * s),
            rigClip('it_image', 'md_image', 14 * s, 2 * s),
          ]),
          Track(
            id: const TrackId('tr_overlay'),
            kind: TrackKind.overlay,
            locked: true,
            items: [rigClip('it_locked', 'md_video', 0, 4 * s)],
          ),
          Track(id: const TrackId('tr_audio'), kind: TrackKind.audio, items: [rigClip('it_audio', 'md_song', 0, 10 * s, visual: false)]),
        ],
      ),
      pool: MediaPool({
        for (final a in [
          rigAsset('md_video', MediaKind.video, name: 'beach.mp4'),
          rigAsset('md_silent', MediaKind.video, hasAudio: false),
          rigAsset('md_image', MediaKind.image, hasAudio: false),
          rigAsset('md_song', MediaKind.audio),
          ...extraAssets,
        ])
          a.id: a,
      }),
      view: ViewState.initial.copyWith(rippleEnabled: ripple),
    );

/// Every asset of a project resolves (offline: none) so jobs can start.
final PlanCompilerPort allOnline = ResolvingPlanCompilerPort(
  (_, project) => MapPlanAssetResolver(originals: {
    for (final a in project.pool.assets.values)
      if (a.status is ReadyStatus) a.id: ResolvedMedia(uri: 'file:///media/${a.id.value}', fingerprint: a.fingerprint.quickHash),
  }),
);

/// The harness around the real inspector with a real, opened EditorController.
class TasksRig {
  TasksRig._(this.harness, this.id, this.tester, this.pool);

  /// Harness.
  final EditorTestHarness harness;

  /// Project id.
  final ProjectId id;

  /// Tester.
  final WidgetTester tester;

  /// The scripted media pool (replacements).
  final ScriptedPool pool;

  /// The fake engine.
  FakeEditorEngine get engine => harness.engine;

  /// The fake jobs.
  FakeMediaJobs get jobs => engine.jobs;

  /// The container of the pumped app.
  ProviderContainer get container => harness.containerOf(tester);

  /// The editor controller.
  EditorController get editor => container.read(editorControllerProvider(id).notifier);

  /// The editor state.
  EditorState get state => container.read(editorControllerProvider(id));

  /// The tasks controller.
  TasksController get tasks => container.read(tasksControllerProvider(id));

  /// The registry.
  EditorActionRegistry get registry => container.read(editorActionRegistryProvider);

  /// An action context over the pumped app.
  WidgetActionContext get ctx => WidgetActionContext.container(
        projectId: id,
        context: tester.element(find.byType(RegionFrame)),
        container: container,
        source: EditorActionSource.toolTile,
      );

  /// The playhead.
  PlayheadController get playhead => container.read(playheadProvider(id));

  /// The committed project.
  EditProject get project => state.project!;

  /// The clip [id].
  MediaClip clip(ItemId id) => project.index.item(id)! as MediaClip;

  /// The asset [id].
  MediaAsset asset(MediaId id) => project.pool[id]!;

  /// The history position.
  int get entries => state.history.position;

  /// The newest job created of [kind] (`reverse`, `freezeFrame`, `proxy`).
  FakeMediaJob<Object?> job(String kind) => jobs.created.lastWhere((j) => j.id.startsWith('$kind-'));

  /// Pumps the inspector host and opens the editor.
  static Future<TasksRig> pump(
    WidgetTester tester, {
    EditorSurface surface = const EditorSurface(Size(1280, 900)),
    MediaClip? video,
    List<MediaAsset> extraAssets = const [],
    InspectorRoute? open,
    FakeEditorEngine? engine,
    ScriptedPool? pool,
    bool readTasks = true,
  }) async {
    EditorAnnouncer.instance.reset();
    final repo = FakeProjectRepository();
    final empty = repo.seedEmpty('Tasks');
    final project = tasksProject(empty.id, video: video, extraAssets: extraAssets);
    repo.seed(project);
    final pid = project.id;
    final scripted = pool ?? ScriptedPool();
    final harness = EditorTestHarness(
      engine: engine ?? FakeEditorEngine(validatePlans: false),
      repository: repo,
      mediaPool: scripted,
      overrides: [
        planCompilerPortProvider.overrideWithValue(allOnline),
        playheadProvider.overrideWith((ref, p) => createPlayheadController(ref, p, ticker: RigTicker(), clock: () => Duration.zero)),
      ],
    );
    final rig = TasksRig._(harness, pid, tester, scripted);
    await harness.pumpApp(
      tester,
      EditorScope(
        projectId: pid,
        child: const RegionFrame(
          inspectorOpen: true,
          regions: {EditorRegion.pane: InspectorHost()},
          dock: InspectorDock(),
        ),
      ),
      surface: surface,
    );
    if (readTasks) rig.tasks;
    await rig.real(() => rig.editor.open());
    if (open != null) rig.editor.openInspector(open);
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

  /// Lets microtasks and listeners run.
  Future<void> settle() async {
    await tester.pump();
    await tester.pump();
  }

  /// Seeks the playhead exactly to [t].
  Future<void> seek(TimeUs t) => real(() async {
        await playhead.seekExact(t);
      });

  /// Completes [job] with a generated file.
  Future<void> complete(FakeMediaJob<Object?> job, {int bytes = 4096, TimeUs? duration}) async {
    job.complete(GeneratedAsset(path: '/out/${job.id}', sizeBytes: bytes, duration: duration));
    await settle();
  }

  /// Ends the test: clears the announcer's timer.
  Future<void> finish() async {
    await tester.pump(const Duration(seconds: 1));
    EditorAnnouncer.instance.reset();
  }
}
