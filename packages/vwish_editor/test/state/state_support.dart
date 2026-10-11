// OWNER: UX-08
//
// Helpers for the EditorController tests: a counting PlanSync, a manual frame scheduler, an
// image asset with a resolvable file, and a controller wired to FakeEditorEngine and a fake or
// in-memory repository.

import 'dart:async';

import 'package:vwish_editor/src/app/editor_prefs.dart';
import 'package:vwish_editor/src/editor/state/editor_controller.dart';
import 'package:vwish_editor/src/editor/state/editor_session.dart';
import 'package:vwish_editor/src/editor/state/plan_compiler_port.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/plan.dart' show MapPlanAssetResolver, PlanAssetResolver;
import 'package:vwish_editor_core/store.dart';
import 'package:vwish_editor_engine_api/testing.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

/// A PlanSync that counts `schedule` calls.
class CountingPlanSync extends PlanSync {
  /// Creates the sync.
  CountingPlanSync(super.session, {required super.compile});

  /// Number of `schedule` calls.
  int schedules = 0;

  /// Revisions scheduled, in order.
  final List<int> scheduledRevisions = [];

  @override
  void schedule(EditProject project) {
    schedules++;
    scheduledRevisions.add(project.timeline.revision);
    super.schedule(project);
  }
}

/// Frame callbacks run only when a test calls [flush].
class ManualFrames implements EditorFrameScheduler {
  final List<void Function()> _pending = [];

  /// Callbacks waiting for the next frame.
  int get pending => _pending.length;

  @override
  void schedule(void Function() callback) => _pending.add(callback);

  /// Runs one frame.
  void flush() {
    final list = [..._pending];
    _pending.clear();
    for (final c in list) {
      c();
    }
  }
}

/// A fixed clock that tests move.
class TestClock {
  /// Now.
  DateTime now = DateTime.utc(2026, 10, 11, 9);

  /// Advances by [d].
  void advance(Duration d) => now = now.add(d);

  /// The clock function.
  DateTime call() => now;
}

/// A ready image asset [id] (1920x1080).
MediaAsset imageAsset(String id) => MediaAsset(
      id: MediaId(id),
      kind: MediaKind.image,
      displayName: 'photo $id',
      locator: AppRelativeLocator(AppRoot.support, 'vwish/editor/media/$id/photo.png'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000, quickHash: id.padRight(40, '0')),
      probe: MediaProbe(kind: MediaKind.image, hasVideo: true, width: 1920, height: 1080),
      origin: MediaOrigin.files,
      addedAt: DateTime.utc(2026, 10, 1),
    );

/// A resolver that resolves every asset of a project to a fake file.
PlanAssetResolver resolverFor(EditProject project) => MapPlanAssetResolver(originals: {
      for (final a in project.pool.assets.values) a.id: ResolvedMedia(uri: 'file:///fake/${a.id}.png', fingerprint: 'fp-${a.id}'),
    });

/// A controller under test with its collaborators.
class ControllerRig {
  /// Creates the rig over [repository] (default: a FakeProjectRepository-like store given by the
  /// test) and a fresh FakeEditorEngine.
  ControllerRig({
    required this.repository,
    required this.id,
    FakeEditorEngine? engine,
    EditorPrefs? prefs,
    this.resolve = true,
    TestClock? clock,
  })  : engine = engine ?? FakeEditorEngine(validatePlans: false),
        prefs = prefs ?? EditorPrefs.memory(),
        clock = clock ?? TestClock() {
    controller = EditorController(
      id: id,
      session: session,
      repository: repository,
      engine: this.engine,
      prefs: this.prefs,
      compilers: resolve ? ResolvingPlanCompilerPort((_, p) => resolverFor(p)) : null,
      frames: frames,
      planSyncFactory: (s, compile) => syncs.last = CountingPlanSync(s, compile: compile),
      ids: SeededIdGenerator(4242),
      clock: this.clock.call,
    );
    controller.onReleased = () => released++;
    controller.events.listen(events.add);
  }

  /// Project id.
  final ProjectId id;

  /// The store.
  final ProjectRepository repository;

  /// The engine.
  final FakeEditorEngine engine;

  /// Preferences.
  final EditorPrefs prefs;

  /// Whether pool assets resolve to fake files.
  final bool resolve;

  /// The session clock.
  final TestClock clock;

  /// Frames.
  final ManualFrames frames = ManualFrames();

  /// The session holder.
  late final EditorSession session = EditorSession(id);

  /// The controller.
  late final EditorController controller;

  /// PlanSyncs created (the last one is the live one).
  final SyncList syncs = SyncList();

  /// Every event.
  final List<EditorEvent> events = [];

  /// `onReleased` calls.
  int released = 0;

  /// The live PlanSync.
  CountingPlanSync get sync => syncs.last!;

  /// The live fake preview.
  FakePreviewSession get preview => engine.sessions.last;

  /// Events of type [T].
  List<T> eventsOf<T extends EditorEvent>() => events.whereType<T>().toList();

  /// Opens and lets PlanSync settle.
  Future<void> open({TimeUs? initialPlayhead}) async {
    await controller.open(initialPlayhead: initialPlayhead);
    await settle();
  }

  /// Lets microtasks and PlanSync's pump finish.
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
      final s = syncs.last;
      if (s != null) await s.flush();
    }
  }
}

/// The PlanSyncs a rig created.
class SyncList {
  /// The newest.
  CountingPlanSync? last;
}

/// Completes after [f] or throws [TimeoutException].
Future<T> bounded<T>(Future<T> f) => f.timeout(const Duration(seconds: 5));
