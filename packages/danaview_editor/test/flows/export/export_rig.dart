// OWNER: UX-39
//
// Test rig for the export flow: a seeded project (an image clip, a text item and a captions track),
// the editor harness with a real EditorController on FakeEditorEngine, and an `ExportEnvironment`
// over an in-memory file system with scripted collaborators: a sprite runner, a file handoff whose
// outcomes the test chooses, a recording wakelock and host, a manual clock and a compile hook that
// can report pending media.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/flows/export/export_controller.dart';
import 'package:danaview_editor/src/editor/flows/export/export_environment.dart';
import 'package:danaview_editor/src/editor/flows/export/export_sheet.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/plan_compiler_port.dart';
import 'package:danaview_editor_core/eval.dart' show TextMetricsProvider;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_core/testing.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../actions/action_test_support.dart';
import '../../state/state_support.dart' show TestClock, imageAsset, resolverFor;
import '../../support/support.dart';

export 'package:danaview_editor_engine_api/testing.dart' show FakeEditorEngine, FakeExportJob;

const int s = microsPerSecond;

/// Fake roots of the rig.
const StoreRoots rigRoots = StoreRoots(support: '/mem/support', cache: '/mem/cache', documents: '/mem/documents');

/// A video asset of [id] (10 s, 1920x1080 at 30 fps).
MediaAsset videoAsset(String id, {int width = 1920, int height = 1080}) => MediaAsset(
      id: MediaId(id),
      kind: MediaKind.video,
      displayName: 'clip $id',
      locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/media/$id/clip.mp4'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 5000, quickHash: id.padRight(40, '0'), duration: 10 * s),
      probe: MediaProbe(kind: MediaKind.video, duration: 10 * s, hasVideo: true, hasAudio: true, width: width, height: height, nominalFps: 30),
      origin: MediaOrigin.files,
      addedAt: DateTime.utc(2026, 10, 1),
    );

/// A project named "My video": an image clip (0-4 s), optionally a text item and a captions track
/// ("Captions (Spanish)", `es`) with [cues] cues; [empty] has no clips at all.
EditProject exportProject(
  FakeProjectRepository repo, {
  bool text = true,
  int cues = 2,
  bool empty = false,
  bool video4k = false,
  CanvasSpec canvas = const CanvasSpec(),
  String name = 'My video',
}) {
  final base = repo.seedEmpty(name, settings: ProjectSettings(canvas: canvas));
  if (empty) return base;
  final edit = EditSession(base, ids: SeededIdGenerator(11));
  edit.applyPoolChange(AddAssets([imageAsset('md_a'), if (video4k) videoAsset('md_v', width: 3840, height: 2160)]));
  void ok(EditOutcome r, String what) {
    if (!r.changed) throw StateError('$what: $r');
  }

  ok(edit.apply(InsertMedia([const MediaId('md_a')], 0, mode: InsertMode.newLane)), 'insert');
  if (text) ok(edit.apply(const AddText(0, text: 'Hello', duration: 4 * s)), 'text');
  if (cues > 0) {
    final added = edit.apply(const AddTrack(TrackKind.subtitle, name: 'Captions (Spanish)', language: 'es'));
    ok(added, 'track');
    final lane = edit.committedProject.timeline.tracks.firstWhere((t) => t.kind == TrackKind.subtitle).id;
    for (var i = 0; i < cues; i++) {
      ok(edit.apply(AddCue(i * 2 * s, 'Cue $i', track: lane, duration: s)), 'cue $i');
    }
  }
  final project = edit.committedProject;
  repo.seed(project);
  return project;
}

/// A sprite runner that writes nothing: it answers every request with a file entry.
class FakeSpriteRunner implements ExportSpriteRunner {
  /// Every list of requests it was given.
  final List<List<SpriteRequest>> runs = [];

  /// When set, `run` waits for it (cancel tests).
  Completer<void>? gate;

  @override
  TextMetricsProvider? get metrics => null;

  @override
  Future<SpriteManifest> run(List<SpriteRequest> requests, {required String cacheDir, void Function(double fraction)? onProgress, bool Function()? isCancelled}) async {
    runs.add(requests);
    onProgress?.call(0.5);
    final g = gate;
    if (g != null) await g.future;
    if (isCancelled?.call() ?? false) throw const SpritePrepassCancelled();
    onProgress?.call(1);
    return SpriteManifest({
      for (final r in requests)
        r.key: SpriteFile(uri: 'file:///mem/cache/danaview/editor/sprites/${r.key}.vsprite', sw: 64, sh: 32, sscale: r.scale, reveal: r.reveal),
    });
  }
}

/// A file handoff whose outcomes the test chooses and that records what it was given.
class ScriptedFiles implements FileHandoff {
  /// Calls as `kind:path` (`photos`, `files`, `share`).
  final List<String> calls = [];

  /// Suggested names given to `saveToFiles`.
  final List<String> names = [];

  /// Outcome per kind (default `done`).
  final Map<String, FileHandoffOutcome> outcomes = {};

  /// Gate per kind (the call waits for it).
  final Map<String, Completer<void>> gates = {};

  Future<FileHandoffResult> _do(String kind, String path) async {
    calls.add('$kind:$path');
    final g = gates[kind];
    if (g != null) await g.future;
    final outcome = outcomes[kind] ?? FileHandoffOutcome.done;
    return FileHandoffResult(outcome, savedUri: outcome == FileHandoffOutcome.done && kind == 'photos' ? 'fake://photos/1' : null);
  }

  @override
  Future<FileHandoffResult> saveToPhotos(String path) => _do('photos', path);

  @override
  Future<FileHandoffResult> saveToFiles(String path, String suggestedName) {
    names.add(suggestedName);
    return _do('files', path);
  }

  @override
  Future<FileHandoffResult> share(String path) => _do('share', path);

  /// Kinds called, in order.
  List<String> get kinds => [for (final c in calls) c.split(':').first];
}

/// The fake engine with scripted file handoff (everything else is the fake's).
class RigEngine implements EditorEngine {
  /// Wraps [inner].
  RigEngine(this.inner, this.scriptedFiles);

  /// The fake.
  final FakeEditorEngine inner;

  /// The file handoff.
  final ScriptedFiles scriptedFiles;

  @override
  FileHandoff get files => scriptedFiles;

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
  MediaAccess get access => inner.access;

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

/// What the host (router) was asked to do.
class HostLog {
  /// Files played.
  final List<String> played = [];

  /// "Free up space" presses.
  int freeUpSpace = 0;

  /// "Open Settings" presses.
  int openSettings = 0;
}

/// Capabilities used by default: a mid device with H.264 and HEVC, up to 1080p at 60 fps.
const EditorCapabilities rigCaps = EditorCapabilities(
  supported: true,
  tier: DeviceTier.mid,
  hevcEncode: true,
  hardwareHevc: true,
  backgroundKind: BackgroundExportKind.foregroundService,
  maxExportSize: Size(1920, 1080),
  maxFpsByHeight: {1080: 60, 2160: 30},
);

/// The rig.
class ExportRig {
  /// Creates a rig; [project] builds the seeded project.
  ExportRig({
    EditProject Function(FakeProjectRepository repo)? project,
    EditorCapabilities caps = rigCaps,
    TargetPlatform platform = TargetPlatform.android,
    bool withHost = true,
    List<Override> overrides = const [],
    Duration notificationPermissionTimeout = ExportEnvironment.defaultNotificationPermissionTimeout,
  })  : repo = FakeProjectRepository(),
        scripted = ScriptedFiles(),
        fake = FakeEditorEngine(caps: caps, validatePlans: false),
        platform = platform {
    id = (project ?? exportProject)(repo).id;
    mem = MemoryStoreFs();
    for (final d in [rigRoots.support, rigRoots.cache, rigRoots.documents, rigRoots.workDir]) {
      mem.mkdirs(d);
    }
    env = ExportEnvironment(
      roots: rigRoots,
      fs: mem,
      documentsWriter: DocumentsExportWriter(rigRoots, fs: mem),
      deleter: OwnedFileDeleter(rigRoots, fs: mem),
      spriteRunner: (_) => sprites,
      resolveAssets: (session, p) async => resolver(p),
      compile: _compile,
      platform: platform,
      now: clock.call,
      wakelock: wakelock.add,
      newToken: () => 't${_tokens++}',
      notificationPermissionTimeout: notificationPermissionTimeout,
    );
    engine = RigEngine(fake, scripted);
    harness = EditorTestHarness(
      engine: fake,
      repository: repo,
      overrides: [
        editorEngineProvider.overrideWithValue(engine),
        exportEnvironmentProvider.overrideWithValue(env),
        if (withHost)
          exportHostProvider.overrideWithValue(ExportHost(
            onPlay: host.played.add,
            onFreeUpSpace: () => host.freeUpSpace++,
            onOpenSettings: () => host.openSettings++,
          )),
        planCompilerPortProvider.overrideWithValue(ResolvingPlanCompilerPort((_, p) => resolverFor(p))),
        ...overrides,
      ],
    );
  }

  /// The store.
  final FakeProjectRepository repo;

  /// The scripted file handoff.
  final ScriptedFiles scripted;

  /// The fake engine.
  final FakeEditorEngine fake;

  /// The platform of the environment.
  final TargetPlatform platform;

  /// The sprite runner.
  final FakeSpriteRunner sprites = FakeSpriteRunner();

  /// Wakelock calls.
  final List<bool> wakelock = [];

  /// Host calls.
  final HostLog host = HostLog();

  /// The clock.
  final TestClock clock = TestClock();

  /// Media ids the resolver reports offline.
  final Set<MediaId> offline = {};

  /// When set, every compile returns [ExportBlocked] with these requirements.
  PlanRequirements? blockWith;

  late final ProjectId id;
  late final MemoryStoreFs mem;
  late final ExportEnvironment env;
  late final RigEngine engine;
  late final EditorTestHarness harness;
  int _tokens = 0;

  /// Resolves every asset except [offline].
  PlanAssetResolver resolver(EditProject p) {
    final all = resolverFor(p) as MapPlanAssetResolver;
    return MapPlanAssetResolver(originals: {
      for (final e in all.originals.entries)
        if (!offline.contains(e.key)) e.key: e.value,
    });
  }

  Future<ExportCompileResult> _compile(ExportCompileInput input) async {
    final block = blockWith;
    final result = block != null ? ExportBlocked(requirements: block) : await defaultExportCompile(input);
    compiles.add((input, result));
    return result;
  }

  /// Every compile, with its input and result (pre-check compiles have no sprite requests).
  final List<(ExportCompileInput, ExportCompileResult)> compiles = [];

  /// The export service.
  FakeExportService get exporter => fake.exporter;

  /// The jobs started.
  List<FakeExportJob> get started => fake.exporter.started;

  /// The work folder.
  String get workDir => rigRoots.workDir;

  /// Puts a fake output at [path] (the engine wrote it).
  void writeOutput(String path, {int bytes = 1234}) => mem.putFile(path, Uint8List(bytes));

  /// Finishes [job] after writing its output.
  Future<void> finish(FakeExportJob job, {int bytes = 1234}) async {
    writeOutput(job.outputPath, bytes: bytes);
    job.finish();
    await settle();
  }

  /// Lets queued microtasks and timers of the fakes run.
  Future<void> settle([int turns = 8]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  // ---- Unit-test helpers (no widget tree) ----------------------------------------------------

  /// A container over the harness overrides, with the export controller of [id] kept alive.
  ProviderContainer container() {
    final c = ProviderContainer(overrides: harness.overrides);
    _containers.add(c);
    addTearDown(disposeContainers);
    c.listen(exportControllerProvider(id), (_, __) {}, fireImmediately: false);
    return c;
  }

  final List<ProviderContainer> _containers = [];

  /// Disposes every container made by [container] (idempotent).
  void disposeContainers() {
    for (final c in _containers) {
      c.dispose();
    }
    _containers.clear();
  }

  /// Opens the editor of [id] in [c].
  Future<EditorController> openEditor(ProviderContainer c) async {
    final editor = c.read(editorControllerProvider(id).notifier);
    await editor.open();
    await settle();
    return editor;
  }

  /// The export controller in [c].
  ExportController controllerIn(ProviderContainer c) => c.read(exportControllerProvider(id).notifier);

  /// The export state in [c].
  ExportUiState stateIn(ProviderContainer c) => c.read(exportControllerProvider(id));

  // ---- Widget-test helpers ---------------------------------------------------------------------

  /// Pumps a host page with an Export button that runs `ExportSheet.show`, opens the editor and
  /// returns the container.
  Future<ProviderContainer> pump(WidgetTester tester, {EditorSurface surface = SurfaceMatrix.phone, Map<EditorActionId, EditorActionBinding>? bindings}) async {
    await harness.pumpApp(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DanaviewButton.primary(label: 'Export now', onPressed: () => ExportSheet.show(context, projectId: id)),
                DanaviewButton.secondary(label: 'Check pending', onPressed: () => ExportSheet.showIfPending(context, projectId: id)),
              ],
            ),
          ),
        ),
      ),
      surface: surface,
    );
    final c = harness.containerOf(tester);
    await tester.runAsync(() async {
      await c.read(editorControllerProvider(id).notifier).open();
      await settle();
    });
    await tester.pump();
    return c;
  }

  /// Presses the host page's Export button and lets the pre-checks finish.
  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.text('Export now'));
    await pumpSome(tester);
  }

  /// Presses the host page's "Check pending" button (reattach) and lets it finish.
  Future<void> openPending(WidgetTester tester) async {
    await tester.tap(find.text('Check pending'));
    await pumpSome(tester);
  }

  /// Taps the widget with [key] (scrolling it into view) and pumps.
  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await pumpSome(tester);
  }

  /// Finishes [job] with an output file and pumps.
  Future<void> finishJob(WidgetTester tester, FakeExportJob job, {int bytes = 1234}) async {
    writeOutput(job.outputPath, bytes: bytes);
    job.finish();
    await pumpSome(tester);
  }

  /// Presses Export in the open sheet, goes through the first-export notice when it appears, and
  /// returns the started job.
  Future<FakeExportJob> startExport(WidgetTester tester) async {
    await tapKey(tester, 'export-start');
    if (find.byKey(const ValueKey('export-notice-continue')).evaluate().isNotEmpty) {
      await tapKey(tester, 'export-notice-continue');
    }
    return started.last;
  }

  /// Pumps a few frames (spinners and indeterminate bars never settle).
  Future<void> pumpSome(WidgetTester tester, [int frames = 8]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }
}

/// The recording action registry of widget tests: every action records its id, so the sheet's
/// relink and format exits can be observed.
Override recordingActions(ActionLog log) => editorActionRegistryProvider.overrideWithValue(
      EditorActionRegistry.forPlatform(TargetPlatform.android, recordingBindings(log)),
    );
