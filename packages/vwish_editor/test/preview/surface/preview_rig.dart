// OWNER: UX-18
//
// A rig for the preview tests (UX-18 surface, UX-19 text overlay, UX-22 manipulation): the editor
// harness with a real EditorController opened over FakeEditorEngine on a seeded project with an
// image clip (half scale, centred) and a text item, a manual playhead ticker and clock, the fake
// texture placeholder, a recording wakelock and a resolving plan compiler (so transients flow).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/editor_providers.dart';
import 'package:vwish_editor/src/editor/editor_scope.dart';
import 'package:vwish_editor/src/editor/preview/preview_region.dart';
import 'package:vwish_editor/src/editor/preview/preview_surface.dart';
import 'package:vwish_editor/src/editor/state/editor_controller.dart';
import 'package:vwish_editor/src/editor/state/editor_state.dart';
import 'package:vwish_editor/src/editor/state/plan_compiler_port.dart';
import 'package:vwish_editor/src/editor/state/playhead_controller.dart';
import 'package:vwish_editor/src/editor/state/transport_controller.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';
import 'package:vwish_editor_engine_api/testing.dart';

import '../../state/state_support.dart' show imageAsset, resolverFor;
import '../../support/support.dart';
import '../../transport/transport_support.dart';

const int s = microsPerSecond;

/// Ids of the seeded project.
abstract final class PreviewIds {
  /// The image clip on the main lane (0–5 s, scale 0.5, centred: canvas box 480,270–1440,810).
  static ItemId clip = const ItemId('none');

  /// The text item (0–4 s, "Hello", centred).
  static ItemId text = const ItemId('none');
}

/// A 1920×1080 project: an image clip at half scale (0–5 s) and a text item (0–4 s), 30 fps.
EditProject previewProject(FakeProjectRepository repo, {bool withText = true, List<EditCommand> extra = const []}) {
  final empty = repo.seedEmpty('Preview');
  final edit = EditSession(empty, ids: SeededIdGenerator(7));
  edit.applyPoolChange(AddAssets([imageAsset('md_a')]));
  final inserted = edit.apply(InsertMedia([const MediaId('md_a')], 0, mode: InsertMode.newLane));
  if (!inserted.changed) throw StateError('insert: $inserted');
  final clip = inserted.affected.single;
  final scaled = edit.apply(SetProperty<double>([clip], PropertyKeys.scale, 0.5));
  if (!scaled.changed) throw StateError('scale: $scaled');
  PreviewIds.clip = clip;
  if (withText) {
    final t = edit.apply(const AddText(0, text: 'Hello', duration: 4 * s));
    if (!t.changed) throw StateError('text: $t');
    PreviewIds.text = t.affected.single;
  }
  for (final c in extra) {
    final out = edit.apply(c);
    if (!out.changed) throw StateError('$c -> $out');
  }
  final project = edit.committedProject;
  repo.seed(project);
  return project;
}

/// Records wakelock calls.
class WakelockLog {
  /// Calls, in order.
  final List<bool> calls = [];

  /// Whether the lock is held.
  bool get held => calls.isNotEmpty && calls.last;

  /// The provider value.
  void call(bool on) => calls.add(on);
}

/// An EditorController whose state a test can force (statuses the fake engine can't produce, such as
/// the first-frame wait).
class ForcibleEditorController extends EditorController {
  /// Creates the controller.
  ForcibleEditorController({
    required super.id,
    required super.session,
    required super.repository,
    required super.engine,
    super.prefs,
    super.compilers,
  });

  /// Replaces the state.
  void force(EditorState next) => state = next;
}

/// Builds [ForcibleEditorController]s like `createEditorController`.
ForcibleEditorController createForcibleController(Ref<Object?> ref, ProjectId id) {
  final session = ref.watch(editorSessionProvider(id));
  final link = ref.keepAlive();
  final c = ForcibleEditorController(
    id: id,
    session: session,
    repository: ref.read(projectRepositoryProvider),
    engine: ref.read(editorEngineProvider),
    prefs: ref.read(editorPrefsProvider),
    compilers: ref.read(planCompilerPortProvider),
  );
  c.onReleased = link.close;
  return c;
}

/// The preview region at 384×216 (scale 0.2 of the 1920×1080 canvas).
Widget regionHome(ProjectId id) => const Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 384, height: 216, child: PreviewRegion()),
    );

/// The editor harness around one widget under test.
class PreviewRig {
  PreviewRig._(this.harness, this.id, this.tester, this.frames, this.time, this.wakelock);

  final EditorTestHarness harness;
  final ProjectId id;
  final WidgetTester tester;

  /// The manual ticker the playhead uses.
  final ManualTicker frames;

  /// The manual clock the playhead uses.
  final ManualClock time;

  /// Wakelock calls.
  final WakelockLog wakelock;

  /// The harness' fake engine.
  FakeEditorEngine get engine => harness.engine;

  /// The live fake preview.
  FakePreviewSession get preview => engine.sessions.last;

  /// The container of the pumped app.
  ProviderContainer get container => harness.containerOf(tester);

  /// The editor controller.
  EditorController get editor => container.read(editorControllerProvider(id).notifier);

  /// The forcible controller (pumped with `forcible: true`).
  ForcibleEditorController get forcible => editor as ForcibleEditorController;

  /// The editor state.
  EditorState get state => container.read(editorControllerProvider(id));

  /// The playhead.
  PlayheadController get playhead => container.read(playheadProvider(id));

  /// The transport.
  TransportController get transport => container.read(transportProvider(id));

  /// Pumps [home] (default: the preview region at 384×216) and opens the editor.
  static Future<PreviewRig> pump(
    WidgetTester tester, {
    Widget Function(ProjectId id) home = regionHome,
    EditorSurface surface = SurfaceMatrix.phone,
    EditProject Function(FakeProjectRepository repo)? project,
    bool open = true,
    bool forcible = false,
    List<Override> overrides = const [],
  }) async {
    final repo = FakeProjectRepository();
    final id = (project ?? previewProject)(repo).id;
    final ticker = ManualTicker();
    final clock = ManualClock();
    final wakelock = WakelockLog();
    final harness = EditorTestHarness(
      engine: FakeEditorEngine(validatePlans: false),
      repository: repo,
      overrides: [
        playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: clock.call)),
        previewTextureBuilderProvider.overrideWithValue((context, id) => FakeTexturePlaceholder(textureId: id)),
        previewWakelockProvider.overrideWithValue(wakelock.call),
        planCompilerPortProvider.overrideWithValue(ResolvingPlanCompilerPort((_, p) => resolverFor(p))),
        if (forcible) editorControllerProvider.overrideWith(createForcibleController),
        ...overrides,
      ],
    );
    final rig = PreviewRig._(harness, id, tester, ticker, clock, wakelock);
    await harness.pumpApp(tester, EditorScope(projectId: id, child: home(id)), surface: surface);
    if (open) await rig.openEditor();
    return rig;
  }

  /// Opens the editor (real async) and lets the UI settle.
  Future<void> openEditor({TimeUs? initialPlayhead}) async {
    await tester.runAsync(() async {
      await editor.open(initialPlayhead: initialPlayhead);
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
    await tester.pump();
  }

  /// Runs [body] with real async (fake engine calls) and then pumps.
  Future<void> real(Future<void> Function() body) async {
    await tester.runAsync(() async {
      await body();
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
  }

  /// Lets pending engine futures complete (real async) and pumps.
  Future<void> settle() => real(() async {});

  /// Plays [n] frames (clock samples plus vsync ticks).
  Future<void> playFrames(int n) async {
    for (var i = 0; i < n; i++) {
      time.advance(const Duration(microseconds: 33333));
      preview.advanceFrames(1);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      frames.tick();
      await tester.pump();
    }
  }

  /// The global position of the region-local point [local] (canvas px × 0.2 in [regionHome]).
  Offset at(Offset local, {Finder? within}) => tester.getTopLeft(within ?? find.byType(PreviewRegion)) + local;

  /// The global position of canvas point ([x], [y]) in [regionHome] (scale 0.2).
  Offset canvas(double x, double y) => at(Offset(x * 0.2, y * 0.2));
}
