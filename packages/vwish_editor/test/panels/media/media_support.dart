// OWNER: UX-36
//
// Test rig of the media panel and the timeline drop target: the editor harness (FakeEditorEngine,
// FakeProjectRepository, UX-06's ScriptedPool as the media pool service) around a real, opened
// EditorController over a seeded project, with a manual playhead ticker. Helpers build bin assets,
// seed projects with clips and turn (time, lane) into global positions through the canvas geometry.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/editor_providers.dart';
import 'package:vwish_editor/src/editor/editor_scope.dart';
import 'package:vwish_editor/src/editor/state/editor_controller.dart';
import 'package:vwish_editor/src/editor/state/editor_state.dart';
import 'package:vwish_editor/src/editor/state/playhead_controller.dart';
import 'package:vwish_editor/src/editor/timeline/render_timeline_canvas.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:vwish_editor/src/editor/timeline/timeline_viewport.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';
import 'package:vwish_editor_engine_api/testing.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../../flows/import/import_fakes.dart';
import '../../inspector/inspector_rig.dart' show RigTicker;
import '../../support/support.dart';

export '../../flows/import/import_fakes.dart';
export '../../support/support.dart';

const int s = microsPerSecond;

/// A bin asset.
MediaAsset binAsset(
  String id, {
  MediaKind kind = MediaKind.video,
  String? name,
  TimeUs duration = 10 * s,
  bool hasAudio = true,
  int width = 1920,
  int height = 1080,
  AssetStatus status = AssetStatus.ready,
  ProxyState proxy = ProxyState.none,
  DerivedSpec? derived,
  DateTime? addedAt,
  int sizeBytes = 2 * 1024 * 1024,
  double fps = 30,
  MediaOwnership ownership = MediaOwnership.managedCopy,
}) {
  final visual = kind == MediaKind.video || kind == MediaKind.image || kind == MediaKind.still;
  return MediaAsset(
    id: MediaId(id),
    kind: kind,
    displayName: name ??
        switch (kind) {
          MediaKind.video => '$id.mp4',
          MediaKind.image => '$id.jpg',
          MediaKind.audio => '$id.m4a',
          MediaKind.lut => '$id.cube',
          MediaKind.still => '$id.png',
          MediaKind.recording => '$id.wav',
        },
    locator: AppRelativeLocator(AppRoot.support, 'vwish/editor/media/$id/file'),
    ownership: ownership,
    fingerprint: MediaFingerprint(sizeBytes: sizeBytes, quickHash: id.padRight(40, '0'), duration: duration),
    probe: MediaProbe(
      kind: kind,
      duration: kind == MediaKind.image || kind == MediaKind.still || kind == MediaKind.lut ? 0 : duration,
      hasVideo: kind == MediaKind.video,
      hasAudio: hasAudio && (kind == MediaKind.video || kind == MediaKind.audio || kind == MediaKind.recording),
      width: visual ? width : null,
      height: visual ? height : null,
      nominalFps: kind == MediaKind.video ? fps : null,
      videoCodec: kind == MediaKind.video ? 'hevc' : null,
      audioCodec: kind == MediaKind.video || kind == MediaKind.audio ? 'aac' : null,
      sizeBytes: sizeBytes,
    ),
    origin: MediaOrigin.files,
    derived: derived,
    status: status,
    proxy: proxy,
    addedAt: addedAt ?? DateTime.utc(2026, 10, 1),
  );
}

/// A project named [name] seeded in [repo]: [assets] in the pool, then [setup] applies commands.
EditProject seedMediaProject(
  FakeProjectRepository repo, {
  List<MediaAsset> assets = const [],
  void Function(EditSession edit)? setup,
  String name = 'Media project',
}) {
  final empty = repo.seedEmpty(name);
  final edit = EditSession(empty, ids: SeededIdGenerator(21));
  if (assets.isNotEmpty) edit.applyPoolChange(AddAssets(assets));
  setup?.call(edit);
  final project = edit.committedProject;
  repo.seed(project);
  return project;
}

/// Applies [command] and fails the test setup when it is refused.
void applyOrThrow(EditSession edit, EditCommand command) {
  final out = edit.apply(command);
  if (!out.changed) throw StateError('$command -> $out');
}

/// The editor harness around a media panel or timeline.
class MediaRig {
  MediaRig._(this.harness, this.id, this.tester, this.ticker, this.pool);

  /// Harness (engine, repository, prefs).
  final EditorTestHarness harness;

  /// Project id.
  final ProjectId id;

  /// Tester.
  final WidgetTester tester;

  /// The playhead's ticker.
  final RigTicker ticker;

  /// The media pool service (UX-06's scripted pool).
  final ScriptedPool pool;

  /// The engine.
  FakeEditorEngine get engine => harness.engine;

  /// The container of the pumped app.
  ProviderContainer get container => harness.containerOf(tester);

  /// The editor controller.
  EditorController get editor => container.read(editorControllerProvider(id).notifier);

  /// The editor state.
  EditorState get state => container.read(editorControllerProvider(id));

  /// The project.
  EditProject get project => state.project!;

  /// The playhead.
  PlayheadController get playhead => container.read(playheadProvider(id));

  /// The viewport.
  TimelineViewportController get viewport => container.read(viewportProvider(id));

  /// Editor events seen since [listen].
  final List<EditorEvent> events = [];

  /// Number of history entries.
  int get historyDepth => state.history.position;

  /// Label of the newest history entry.
  String? get undoLabel => state.history.undoLabel;

  /// Pumps [build] (made from the project id) inside the harness and opens the editor.
  static Future<MediaRig> pump(
    WidgetTester tester,
    Widget Function(ProjectId id) build, {
    EditProject Function(FakeProjectRepository repo)? project,
    EditorSurface surface = SurfaceMatrix.phone,
    ScriptedPool? pool,
    FakeEditorEngine? engine,
    List<Override> overrides = const [],
  }) async {
    final repo = FakeProjectRepository();
    final seeded = (project ?? (r) => seedMediaProject(r))(repo);
    final ticker = RigTicker();
    final scripted = pool ?? ScriptedPool();
    final harness = EditorTestHarness(
      engine: engine ?? FakeEditorEngine(validatePlans: false),
      repository: repo,
      mediaPool: scripted,
      overrides: [
        mediaPoolServiceProvider.overrideWithValue(scripted),
        playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: () => Duration.zero)),
        ...overrides,
      ],
    );
    final rig = MediaRig._(harness, seeded.id, tester, ticker, scripted);
    EditorAnnouncer.instance.reset();
    addTearDown(EditorAnnouncer.instance.reset);
    // A fresh ProviderScope (a second pump in one test would reuse the first container).
    await tester.pumpWidget(const SizedBox.shrink());
    await harness.pumpApp(
      tester,
      EditorScope(
        projectId: seeded.id,
        child: DefaultTextStyle(style: VwishTextStyles.body.copyWith(fontFamily: VwishFonts.family), child: build(seeded.id)),
      ),
      surface: surface,
    );
    await rig.real(() => rig.editor.open());
    rig.editor.events.listen(rig.events.add);
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

  /// Seeks the playhead exactly to [t].
  Future<void> seek(TimeUs t) async {
    await real(() async {
      await playhead.seekExact(t);
    });
    await tester.pump();
  }

  /// Adds [assets] to the open project's pool (as an import does).
  Future<void> addAssets(List<MediaAsset> assets) async {
    editor.applyPoolChange(AddAssets(assets));
    await tester.pump();
  }

  /// Applies [command] through the controller and pumps.
  Future<EditResult> apply(EditCommand command) async {
    final result = editor.apply(command);
    await tester.pump();
    return result;
  }

  /// Every clip of the project, by track id.
  Map<TrackId, List<TimelineItem>> get clips => {for (final t in project.timeline.tracks) t.id: t.items};

  /// The first track of [kind], or null.
  Track? trackOf(TrackKind kind) => project.timeline.tracks.where((t) => t.kind == kind).firstOrNull;

  /// Events of type [T].
  List<T> eventsOf<T extends EditorEvent>() => events.whereType<T>().toList();
}

/// A timeline sized to [size] inside [wrap], for the drop tests.
class DropRig {
  /// Creates the rig over [media].
  DropRig(this.media);

  /// The media rig.
  final MediaRig media;

  /// The tester.
  WidgetTester get tester => media.tester;

  /// The canvas.
  RenderTimelineCanvas canvas() => tester.renderObject<RenderTimelineCanvas>(find.byType(TimelineCanvas));

  /// Global position of time [t] in the middle of lane [lane] (vertical [fraction] of the lane).
  Offset at(TimeUs t, String lane, {double fraction = 0.5}) {
    final c = canvas();
    final g = c.geometry;
    final li = g.snapshot.laneIndexOf(TrackId(lane))!;
    return c.localToGlobal(Offset(media.viewport.xOf(t), g.laneTop(li) + g.stack.heights[li] * fraction));
  }

  /// Global position of time [t] below the last lane.
  Offset below(TimeUs t) {
    final c = canvas();
    final g = c.geometry;
    final last = g.snapshot.lanes.length - 1;
    return c.localToGlobal(Offset(media.viewport.xOf(t), g.laneTop(last) + g.stack.heights[last] + 6));
  }

  /// Global position of time [t] on the ruler.
  Offset ruler(TimeUs t) {
    final c = canvas();
    return c.localToGlobal(Offset(media.viewport.xOf(t), -c.geometry.metrics.rulerHeight / 2));
  }
}
