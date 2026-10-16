// OWNER: UX-41
//
// EditorLauncher.openFromPlayer (ARCH §17.1, ux.md §4.4, §4.6) with fakes: the device gate copy per
// reason, "This video can't be edited" copy per platform and code (R7), the missing-file toast,
// untouched-project reuse, the exact position handed to create and to the editor route, the
// "Preparing editor…" wait after 300 ms, the managed-copy path through the import sheet (Cancel
// deletes the half-made project and its partial copy; the free-space refusal shows its copy), and
// the return: the player is suspended (release on low-memory devices), resumed paused when the
// editor route pops, and the orientation owner stack gives the player its mode back.
// FIX-UX-41-1: the player's position is a platform time, so the editor route gets the start of
// the nearest frame of the project's grid (D-35), e.g. 5 333 333 µs and 5 333 000 µs → frame 160.
// FIX-M9 (QA-02 M-9): on the production store (FileProjectRepository in memory), a fresh install or
// a data clear (no projects), the managed-copy import job, a reused untouched project saved at 0
// and a route that ignores `t` all open on frame 160, and the project's saved view.playhead is
// frame 160 before the editor opens.

import 'dart:async';

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart' hide AspectRatio;
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/import_strings.dart';
import 'package:danaview_editor/src/app/strings/launcher_strings.dart';
import 'package:danaview_editor/src/editor/flows/import_media_sheet.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show EditSession;
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_core/testing.dart' show InMemoryProjectRepository;
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_features/orientation.dart';

import '../../support/support.dart';

const _mb = 1024 * 1024;
const _path = '/storage/emulated/0/Movies/holiday.mp4';
/// 12.345 s on the default 30 fps grid: frame 370 (370.35 rounds down), which starts at 12 333 334 µs.
const _openAt = 12333334;
const _iosPhone = EditorSurface(Size(390, 844), platform: TargetPlatform.iOS);

/// The player side of the handoff, recording every call.
class _FakePlayer implements PlayerHandoff {
  final List<String> calls = [];
  final List<String> toasts = [];
  final Object owner = Object();

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> suspend({required bool release}) async => calls.add(release ? 'suspend:release' : 'suspend:pause');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  void showToast(String message) => toasts.add(message);
}

/// The router's editor route: enters the `free` orientation owner while "open" and completes when
/// [pop] is called.
class _FakeEditorRoute {
  final List<(ProjectId, TimeUs)> opened = [];
  final Object owner = Object();
  Completer<void>? _route;

  Future<void> open(ProjectId id, TimeUs at) {
    opened.add((id, at));
    unawaited(ScreenOrientationPolicy.enter(owner, OrientationMode.free));
    return (_route = Completer<void>()).future;
  }

  void pop() {
    unawaited(ScreenOrientationPolicy.release(owner));
    _route?.complete();
  }
}

/// A repository whose create waits on [gate] and makes a managed copy owned by the project, which
/// [delete] removes (what the store does with a cancelled player import).
class _GatedRepository extends FakeProjectRepository {
  Completer<void>? gate;
  final Map<ProjectId, String> copies = {};

  @override
  Future<ProjectId> create(NewProjectSpec spec) async {
    final id = await super.create(spec);
    copies[id] = 'media/ab/holiday.mp4.part';
    final g = gate;
    if (g != null) await g.future;
    return id;
  }

  @override
  Future<void> delete(ProjectId id) async {
    await super.delete(id);
    copies.remove(id);
  }
}

ImportSpaceCheck _check({bool copies = false, int? free}) =>
    ImportSpaceCheck(freeBytes: () async => free, needsCopy: (_) async => copies);

class _Run {
  _Run(this.h, this.repository, this.player, this.route, this.launcher);

  final EditorTestHarness h;
  final _GatedRepository repository;
  final _FakePlayer player;
  final _FakeEditorRoute route;
  final EditorLauncher launcher;
  EditorLaunchOutcome? outcome;
  bool get finished => outcome != null;
}

Future<_Run> _pump(
  WidgetTester tester, {
  EditorCapabilities caps = fakeDefaultCapabilities,
  Map<String, EditCompatibility> compat = const {},
  bool exists = true,
  ImportSpaceCheck? check,
  EditorSurface surface = SurfaceMatrix.phone,
  _GatedRepository? repository,
  Duration position = const Duration(seconds: 12, milliseconds: 345),
}) async {
  final repo = repository ?? _GatedRepository();
  final engine = FakeEditorEngine(caps: caps, compatibilityByPath: Map.of(compat));
  final space = check ?? _check();
  final h = EditorTestHarness(engine: engine, repository: repo, overrides: [importSpaceCheckProvider.overrideWithValue(space)]);
  final launcher = EditorLauncher(
    engine: engine,
    repository: repo,
    capabilities: engine.capabilities,
    spaceCheck: () => space,
    fileExists: (_) async => exists,
    fileSize: (_) async => 120 * _mb,
    playerOrigin: (path, name) async => FromPlayerOrigin(quickHash: 'qh', sizeBytes: 120 * _mb, displayName: name),
  );
  final run = _Run(h, repo, _FakePlayer(), _FakeEditorRoute(), launcher);
  await h.pumpApp(
    tester,
    Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: GestureDetector(
            onTap: () => launcher
                .openFromPlayer(
                  EditorLaunchRequest(pathOrUri: _path, title: 'Holiday', position: position, wasPlaying: true),
                  context,
                  player: run.player,
                  openEditor: run.route.open,
                )
                .then((o) => run.outcome = o),
            child: const Text('Edit'),
          ),
        ),
      ),
    ),
    surface: surface,
  );
  return run;
}

Future<void> _settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tapEdit(WidgetTester tester) async {
  await tester.tap(find.text('Edit'));
  await _settle(tester);
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _settle(tester);
}

// ---- FIX-M9: the production store ----------------------------------------------------------------

/// Frame 160 of the 30 fps frame counter (0:05:10), the s02 position.
const _frame160 = 5333334;

/// The played file as the store sees it: 120 MB, quick hash 'qh' (what `playerOrigin` stores).
final class _Access implements MediaAccessPort {
  @override
  Future<MediaStat?> stat(MediaLocator locator) async => const MediaStat(sizeBytes: 120 * _mb);

  @override
  Future<String> quickHash(MediaLocator locator) async => 'qh';

  @override
  Future<ResolvedMedia> resolve(MediaLocator locator) => throw UnimplementedError();

  @override
  Future<MediaLocator> persist(PickedMediaHandle handle) => throw UnimplementedError();

  @override
  Future<void> release(MediaLocator locator) async {}

  @override
  Future<void> excludeFromBackup(String dirPath) async {}

  @override
  Future<int> remainingGrantBudget() async => 100;
}

/// Imports every pick as an 8 s 1080p30 managed copy into the session's pool (CORE-27's result).
final class _CopyingPool extends FakeMediaPoolService {
  int imports = 0;

  @override
  Future<List<ImportOutcome>> import(EditSession session, List<PickedMedia> picked, {ImportTarget? target}) async {
    calls.add('import');
    final out = <ImportOutcome>[];
    for (final pick in picked) {
      final n = imports++;
      final asset = MediaAsset(
        id: MediaId('md_counter_$n'),
        kind: MediaKind.video,
        displayName: pick.displayName,
        locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/media/qh/counter_$n.mp4'),
        ownership: MediaOwnership.managedCopy,
        fingerprint: const MediaFingerprint(sizeBytes: 120 * _mb, quickHash: 'qh'),
        probe: MediaProbe(kind: MediaKind.video, duration: 8000000, hasVideo: true, width: 1920, height: 1080, nominalFps: 30),
        origin: MediaOrigin.player,
        addedAt: DateTime.utc(2026, 10, 17),
      );
      session.applyPoolChange(AddAssets([asset]));
      out.add(ImportedMedia(pick, asset));
    }
    return out;
  }
}

/// The editor route as the editor applies it: `t` when the route has one, else the project's saved
/// view.playhead (what an open without `t`, or a reopen, starts on), read when the route opens.
class _StoreRoute {
  _StoreRoute(this.store, {this.honoursT = true});

  final ProjectRepository store;
  final bool honoursT;
  final List<(ProjectId, TimeUs)> opened = [];
  final List<TimeUs> startsAt = [];

  Future<void> open(ProjectId id, TimeUs at) async {
    opened.add((id, at));
    final loaded = await store.open(id);
    try {
      final rate = loaded.project.settings.frameRate;
      startsAt.add(rate.quantize(honoursT ? at : loaded.project.view.playhead));
    } finally {
      await store.close(id);
    }
  }
}

/// One player Edit at [position] on [store] (managed copy when [copies], as on Android).
Future<(EditorLaunchOutcome?, _StoreRoute)> _editOnStore(
  WidgetTester tester,
  InMemoryProjectRepository store, {
  Duration position = const Duration(microseconds: 5333000),
  bool copies = true,
  bool honoursT = true,
}) async {
  final engine = FakeEditorEngine(caps: fakeDefaultCapabilities);
  final space = _check(copies: copies, free: 10 * 1024 * _mb);
  final h = EditorTestHarness(engine: engine, overrides: [importSpaceCheckProvider.overrideWithValue(space)]);
  final launcher = EditorLauncher(
    engine: engine,
    repository: store,
    capabilities: engine.capabilities,
    spaceCheck: () => space,
    access: _Access(),
    fileExists: (_) async => true,
    fileSize: (_) async => 120 * _mb,
  );
  final route = _StoreRoute(store, honoursT: honoursT);
  EditorLaunchOutcome? outcome;
  await h.pumpApp(
    tester,
    Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: GestureDetector(
            onTap: () => launcher
                .openFromPlayer(
                  EditorLaunchRequest(pathOrUri: _path, title: 'frame counter', position: position),
                  context,
                  player: _FakePlayer(),
                  openEditor: route.open,
                )
                .then((o) => outcome = o),
            child: const Text('Edit'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Edit'));
  for (var i = 0; i < 40 && outcome == null; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  return (outcome, route);
}

/// The saved view.playhead of [id] in [store].
Future<TimeUs> _savedPlayhead(InMemoryProjectRepository store, ProjectId id) async {
  final loaded = await store.open(id);
  await store.close(id);
  return loaded.project.view.playhead;
}

void main() {
  setUp(ScreenOrientationPolicy.resetForTesting);
  tearDown(ScreenOrientationPolicy.resetForTesting);

  group('device gate', () {
    for (final (reason, copy) in [
      (UnsupportedReasons.androidTooOld, 'Video editing needs Android 10 or later. You can still play all your videos.'),
      (
        UnsupportedReasons.gles3Missing,
        "This device's graphics don't support OpenGL ES 3, which the video editor needs. You can still play all your videos."
      ),
      (UnsupportedReasons.insufficientMemory, 'Video editing needs a device with at least 2 GB of memory. You can still play all your videos.'),
    ]) {
      testWidgets('$reason: explains on tap and never creates a project', (tester) async {
        final run = await _pump(tester, caps: EditorCapabilities(supported: false, unsupportedReason: reason));
        await _tapEdit(tester);
        expect(find.text(LauncherStrings.unsupportedDeviceTitle), findsOneWidget);
        expect(find.text(copy), findsOneWidget);
        expect(run.player.calls, ['pause']);
        await tester.tap(find.text(LauncherStrings.ok));
        await _settle(tester);
        expect(run.outcome, EditorLaunchOutcome.deviceUnsupported);
        expect(run.repository.createdSpecs, isEmpty);
        expect(run.route.opened, isEmpty);
      });
    }
  });

  group('compatibility pre-check', () {
    testWidgets('a missing file shows the player toast', (tester) async {
      final run = await _pump(tester, exists: false);
      await _tapEdit(tester);
      expect(run.outcome, EditorLaunchOutcome.fileMissing);
      expect(run.player.toasts, [LauncherStrings.missing]);
      expect(LauncherStrings.missing, "Couldn't find this video. It may have been moved or deleted.");
      expect(run.repository.createdSpecs, isEmpty);
    });

    testWidgets('iOS + MKV: the R7 copy names the container', (tester) async {
      const mkv = '/var/mobile/Containers/Data/Documents/Show.S01E01.mkv';
      final run = await _pump(tester, surface: _iosPhone, compat: {_path: const NotEditable(EditCompatibilityCodes.containerUnsupportedIos)});
      await _tapEdit(tester);
      expect(find.text(LauncherStrings.notEditableTitle), findsOneWidget);
      expect(
        find.text('Danaview can play MP4 files, but iPhone and iPad can only edit MP4, MOV and M4V videos. Convert it to MP4 to edit it.'),
        findsOneWidget,
        reason: 'the fixture path is an .mp4; the container name comes from the file name',
      );
      expect(
        LauncherStrings.notEditableMessage(EditCompatibilityCodes.containerUnsupportedIos, platform: TargetPlatform.iOS, fileName: 'Show.S01E01.mkv'),
        'Danaview can play MKV files, but iPhone and iPad can only edit MP4, MOV and M4V videos. Convert it to MP4 to edit it.',
      );
      expect(LauncherStrings.containerOf(mkv.split('/').last), 'MKV');
      expect(LauncherStrings.containerOf('clip.webm'), 'WebM');
      expect(LauncherStrings.containerOf('clip.avi'), 'AVI');
      await tester.tap(find.text(LauncherStrings.ok));
      await _settle(tester);
      expect(run.outcome, EditorLaunchOutcome.notEditable);
      expect(run.repository.createdSpecs, isEmpty);
    });

    test('codec copy differs per platform; protected and engine codes have their own copy', () {
      final ios = LauncherStrings.notEditableMessage(EditCompatibilityCodes.codecUnsupported, platform: TargetPlatform.iOS, fileName: 'a.mp4');
      final android =
          LauncherStrings.notEditableMessage(EditCompatibilityCodes.codecUnsupported, platform: TargetPlatform.android, fileName: 'a.mp4');
      expect(ios, contains('iPhone and iPad'));
      expect(android, isNot(contains('iPhone')));
      expect(ios, isNot(android));
      expect(
        LauncherStrings.notEditableMessage(EditCompatibilityCodes.protectedContent, platform: TargetPlatform.android, fileName: 'a.mp4'),
        contains('copy-protected'),
      );
      expect(
        LauncherStrings.notEditableMessage(UnsupportedReasons.engineNotAvailable, platform: TargetPlatform.iOS, fileName: 'a.mp4'),
        contains('iPhone and iPad'),
      );
      expect(LauncherStrings.notEditableMessage('something_new', platform: TargetPlatform.android, fileName: 'a.mp4'), contains('MP4'));
    });

    testWidgets('Android codec_unsupported shows the Android copy', (tester) async {
      await _pump(tester, compat: {_path: const NotEditable(EditCompatibilityCodes.codecUnsupported)});
      await _tapEdit(tester);
      expect(
        find.text("This device can't decode this video's format for editing. Convert it to an H.264 MP4 to edit it."),
        findsOneWidget,
      );
    });

    testWidgets('the explanation fits at 280 px and 1.35x', (tester) async {
      await _pump(tester, surface: SurfaceMatrix.narrowest, compat: {_path: const NotEditable(EditCompatibilityCodes.containerUnsupportedIos)});
      await _tapEdit(tester);
      expect(find.text(LauncherStrings.notEditableTitle), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('reuse or create', () {
    testWidgets('an untouched project for the file is reused (Edit twice never litters Projects)', (tester) async {
      final repo = _GatedRepository();
      final existing = repo.seedEmpty('Holiday').id;
      repo.untouchedByPath[_path] = existing;
      final run = await _pump(tester, repository: repo);
      await _tapEdit(tester);
      expect(repo.createdSpecs, isEmpty);
      expect(run.route.opened.single.$1, existing);
      expect(run.route.opened.single.$2, _openAt);
    });

    testWidgets('a new project starts at the exact player position, named after the video', (tester) async {
      final run = await _pump(tester);
      await _tapEdit(tester);
      final spec = run.repository.createdSpecs.single as FromMediaProjectSpec;
      expect(spec.initialPlayhead, 12345000);
      expect(spec.name, 'Holiday');
      expect(spec.picks.single.uri, _path);
      expect(spec.picks.single.origin, MediaOrigin.player);
      expect(spec.picks.single.displayName, 'holiday.mp4');
      expect(spec.picks.single.sizeBytes, 120 * _mb);
      expect(spec.origin, const FromPlayerOrigin(quickHash: 'qh', sizeBytes: 120 * _mb, displayName: 'holiday.mp4'));
      expect(run.route.opened.single.$2, _openAt);
      expect(run.route.opened.single.$1, run.repository.projects.keys.single);
    });

    test('project names are trimmed to 1-80 characters', () {
      expect(EditorLauncher.projectNameFor('  Holiday  '), 'Holiday');
      expect(EditorLauncher.projectNameFor('   '), 'Untitled project');
      expect(EditorLauncher.projectNameFor('x' * 120).length, 80);
    });

    testWidgets('"Preparing editor…" shows only after 300 ms, cannot be dismissed, and closes before the editor opens', (tester) async {
      final repo = _GatedRepository()..gate = Completer<void>();
      final run = await _pump(tester, repository: repo);
      await tester.tap(find.text('Edit'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(LauncherStrings.preparing), findsNothing);
      await _settle(tester, frames: 3);
      expect(find.text(LauncherStrings.preparing), findsOneWidget);
      await tester.tapAt(const Offset(4, 4));
      await _settle(tester, frames: 2);
      expect(find.text(LauncherStrings.preparing), findsOneWidget, reason: 'non-dismissible');
      expect(run.route.opened, isEmpty);
      repo.gate!.complete();
      await _settle(tester);
      expect(find.text(LauncherStrings.preparing), findsNothing);
      expect(run.route.opened, hasLength(1));
    });

    testWidgets('a create failure is explained and the editor never opens', (tester) async {
      final repo = _GatedRepository();
      repo.failNext['create'] = const StoreFailure(StoreFailureKind.diskFull);
      final run = await _pump(tester, repository: repo);
      await _tapEdit(tester);
      expect(find.text(LauncherStrings.failedTitle), findsOneWidget);
      await tester.tap(find.text(LauncherStrings.ok));
      await _settle(tester);
      expect(run.outcome, EditorLaunchOutcome.failed);
      expect(run.route.opened, isEmpty);
      expect(run.player.calls, ['pause']);
    });
  });

  group('managed copy (ImportMediaSheet)', () {
    testWidgets('Cancel deletes the half-made project and its partial copy', (tester) async {
      final repo = _GatedRepository()..gate = Completer<void>();
      final run = await _pump(tester, repository: repo, check: _check(copies: true, free: 10 * 1024 * _mb));
      await _tapEdit(tester);
      expect(find.byKey(const ValueKey('import-media-sheet')), findsOneWidget);
      expect(find.text(LauncherStrings.copyTitle), findsOneWidget);
      expect(find.text(ImportStrings.copying), findsOneWidget);
      expect(repo.copies, hasLength(1));
      await _tapKey(tester, 'import-cancel');
      repo.gate!.complete();
      await _settle(tester);
      expect(repo.copies, isEmpty, reason: 'the partial copy goes with the deleted project');
      expect(repo.projects, isEmpty);
      expect(repo.calls, containsAllInOrder(['create', startsWith('close:'), startsWith('delete:')]));
      expect(find.text(ImportStrings.cancelledTitle), findsOneWidget);
      await _tapKey(tester, 'import-back');
      expect(run.outcome, EditorLaunchOutcome.cancelled);
      expect(run.route.opened, isEmpty);
      expect(run.player.calls, ['pause'], reason: 'the player is never suspended for a cancelled import');
    });

    testWidgets('not enough space: the refusal copy shows and nothing is copied', (tester) async {
      final run = await _pump(tester, check: _check(copies: true, free: 100 * _mb));
      await _tapEdit(tester);
      expect(find.text(ImportStrings.spaceTitle), findsOneWidget);
      expect(find.textContaining('MB'), findsWidgets);
      expect(run.repository.createdSpecs, isEmpty);
      await _tapKey(tester, 'import-back');
      expect(run.outcome, EditorLaunchOutcome.cancelled);
      expect(run.route.opened, isEmpty);
    });

    testWidgets('a finished copy opens the editor at the player position', (tester) async {
      final run = await _pump(tester, check: _check(copies: true, free: 10 * 1024 * _mb));
      await _tapEdit(tester);
      await _settle(tester);
      expect(run.route.opened.single.$2, _openAt);
      expect((run.repository.createdSpecs.single as FromMediaProjectSpec).initialPlayhead, 12345000);
    });
  });

  group('player position on the frame grid (FIX-UX-41-1, D-35)', () {
    test('platform times map to the start of the nearest frame', () {
      // Frame 160 at 30 fps: plan start 5 333 334 µs; the player reports 5 333 333 µs (µs clock)
      // or 5 333 000 µs (ms clock). Flooring either gives frame 159.
      expect(EditorLauncher.gridTimeFor(5333333, FrameRate.fps30), 5333334);
      expect(EditorLauncher.gridTimeFor(5333000, FrameRate.fps30), 5333334);
      expect(EditorLauncher.gridTimeFor(5333334, FrameRate.fps30), 5333334);
      expect(FrameRate.fps30.frameIndexOf(EditorLauncher.gridTimeFor(5333000, FrameRate.fps30)), 160);
      // 24 fps: frame 7 starts at 291 667 µs; the player says 291 000 µs (ms) or 291 666 µs.
      expect(EditorLauncher.gridTimeFor(291000, FrameRate.fps24), 291667);
      expect(EditorLauncher.gridTimeFor(291666, FrameRate.fps24), 291667);
      // 60 fps and 25 fps (exact ms grid).
      expect(EditorLauncher.gridTimeFor(5333000, FrameRate.fps60), FrameRate.fps60.timeOfFrame(320));
      expect(EditorLauncher.gridTimeFor(5320000, FrameRate.fps25), 5320000);
      // Zero and negative stay at the start.
      expect(EditorLauncher.gridTimeFor(0, FrameRate.fps30), 0);
      expect(EditorLauncher.gridTimeFor(-5, FrameRate.fps30), 0);
    });

    for (final (label, us) in [('µs clock', 5333333), ('ms clock', 5333000)]) {
      testWidgets('a new project opens on frame 160 when the player hands over $us µs ($label)', (tester) async {
        final run = await _pump(tester, position: Duration(microseconds: us));
        await _tapEdit(tester);
        expect(run.route.opened.single.$2, 5333334);
        expect(FrameRate.fps30.frameIndexOf(run.route.opened.single.$2), 160);
        expect(run.repository.openProjects, isEmpty, reason: 'the rate read releases the project for the editor');
      });

      testWidgets('a copied project opens on frame 160 for $us µs ($label)', (tester) async {
        final run = await _pump(tester, position: Duration(microseconds: us), check: _check(copies: true, free: 10 * 1024 * _mb));
        await _tapEdit(tester);
        await _settle(tester);
        expect(run.route.opened.single.$2, 5333334);
        expect(run.repository.openProjects, isEmpty);
      });
    }

    testWidgets('a reused project uses its own frame rate (24 fps)', (tester) async {
      final repo = _GatedRepository();
      final existing = repo.seedEmpty('Holiday', settings: const ProjectSettings(frameRate: FrameRate.fps24)).id;
      repo.untouchedByPath[_path] = existing;
      final run = await _pump(tester, repository: repo, position: const Duration(microseconds: 291000));
      await _tapEdit(tester);
      expect(run.route.opened.single, (existing, 291667));
      expect(repo.calls, containsAllInOrder(['open:$existing', 'close:$existing']));
      expect(repo.openProjects, isEmpty);
    });

    testWidgets('when the rate cannot be read the raw position is handed over', (tester) async {
      final repo = _GatedRepository()..failNext['open'] = const StoreFailure(StoreFailureKind.busy);
      final run = await _pump(tester, repository: repo, position: const Duration(microseconds: 5333000));
      await _tapEdit(tester);
      expect(run.route.opened.single.$2, 5333000);
      expect(run.outcome, isNull, reason: 'the editor is still open');
    });
  });

  group('fresh install and data clear on the production store (FIX-M9, QA-02 M-9)', () {
    for (final copies in [true, false]) {
      final label = copies ? 'managed copy (Android import job)' : 'direct create';
      testWidgets('first Edit after a fresh install, $label: opens and is saved on frame 160', (tester) async {
        final store = InMemoryProjectRepository(media: _CopyingPool(), access: _Access());
        final (outcome, route) = await _editOnStore(tester, store, copies: copies);
        expect(outcome, EditorLaunchOutcome.opened);
        final (id, at) = route.opened.single;
        expect(at, _frame160);
        expect(FrameRate.fps30.frameIndexOf(route.startsAt.single), 160);
        final saved = (await tester.runAsync(() => _savedPlayhead(store, id)))!;
        expect(FrameRate.fps30.frameIndexOf(saved), 160, reason: 'the store floors 5 333 000 µs to frame 159; the launcher saves frame 160');
        expect(saved, _frame160);
        final summaries = (await tester.runAsync(store.summaries))!;
        expect(summaries, hasLength(1));
        await tester.runAsync(store.dispose);
      });
    }

    testWidgets('a route that drops `t` still starts on frame 160 (the saved view state)', (tester) async {
      final store = InMemoryProjectRepository(media: _CopyingPool(), access: _Access());
      final (outcome, route) = await _editOnStore(tester, store, honoursT: false);
      expect(outcome, EditorLaunchOutcome.opened);
      expect(FrameRate.fps30.frameIndexOf(route.startsAt.single), 160);
      await tester.runAsync(store.dispose);
    });

    testWidgets('Edit again: the untouched project (saved at 0) is reused and moved to frame 160', (tester) async {
      final store = InMemoryProjectRepository(media: _CopyingPool(), access: _Access());
      final (_, first) = await _editOnStore(tester, store, position: Duration.zero);
      final id = first.opened.single.$1;
      expect((await tester.runAsync(() => _savedPlayhead(store, id)))!, 0);

      final (outcome, second) = await _editOnStore(tester, store, honoursT: false);
      expect(outcome, EditorLaunchOutcome.opened);
      expect(second.opened.single, (id, _frame160), reason: 'Edit twice never litters Projects');
      expect(FrameRate.fps30.frameIndexOf(second.startsAt.single), 160);
      expect((await tester.runAsync(() => _savedPlayhead(store, id)))!, _frame160);
      final summaries = (await tester.runAsync(store.summaries))!;
      expect(summaries, hasLength(1));
      expect(summaries.single.id, id);
      await tester.runAsync(store.dispose);
    });

    testWidgets('after a data clear (empty store) a new project is created on frame 160', (tester) async {
      final before = InMemoryProjectRepository(media: _CopyingPool(), access: _Access());
      await _editOnStore(tester, before, position: Duration.zero);
      await tester.runAsync(before.dispose);
      // pm clear: the projects are gone, the same file is played again.
      final cleared = InMemoryProjectRepository(media: _CopyingPool(), access: _Access());
      final (outcome, route) = await _editOnStore(tester, cleared);
      expect(outcome, EditorLaunchOutcome.opened);
      final (id, at) = route.opened.single;
      expect(at, _frame160);
      expect((await tester.runAsync(() => _savedPlayhead(cleared, id)))!, _frame160);
      await tester.runAsync(cleared.dispose);
    });

    testWidgets('a position past the end opens there but is saved on the last frame', (tester) async {
      final store = InMemoryProjectRepository(media: _CopyingPool(), access: _Access());
      final (_, route) = await _editOnStore(tester, store, position: const Duration(seconds: 20));
      final (id, at) = route.opened.single;
      expect(at, 20000000, reason: 'the editor clamps on open');
      expect((await tester.runAsync(() => _savedPlayhead(store, id)))!, FrameRate.fps30.quantize(8000000));
      await tester.runAsync(store.dispose);
    });

    testWidgets('a project with a pending recovery keeps its saved playhead', (tester) async {
      final repo = _GatedRepository();
      final existing = repo.seedEmpty('Holiday').id;
      repo.untouchedByPath[_path] = existing;
      repo.openResults[existing] = (p) => LoadedProject(
            project: p,
            pendingRecovery: RecoverableSession(
              projectId: p.id,
              projectName: p.name,
              journalSavedAt: DateTime.utc(2026, 10, 17),
              journalRevision: 2,
              mainRevision: 1,
            ),
          );
      final run = await _pump(tester, repository: repo, position: const Duration(microseconds: 5333000));
      await _tapEdit(tester);
      expect(run.route.opened.single.$2, _frame160);
      expect(repo.calls, isNot(contains('save')));
    });
  });

  group('player handoff', () {
    testWidgets('pause mode: suspended while the editor is open, resumed paused when it pops, orientation restored',
        (tester) async {
      final run = await _pump(tester);
      unawaited(ScreenOrientationPolicy.enter(run.player.owner, OrientationMode.followDevice));
      await _tapEdit(tester);
      expect(run.player.calls, ['pause', 'suspend:pause']);
      expect(ScreenOrientationPolicy.topMode, OrientationMode.free);
      expect(run.finished, isFalse);
      run.route.pop();
      await _settle(tester);
      expect(run.player.calls, ['pause', 'suspend:pause', 'resume']);
      expect(run.player.calls, isNot(contains('play')));
      expect(ScreenOrientationPolicy.topOwner, same(run.player.owner));
      expect(ScreenOrientationPolicy.topMode, OrientationMode.followDevice);
      expect(run.outcome, EditorLaunchOutcome.opened);
    });

    testWidgets('low-memory devices release the player engine', (tester) async {
      final run = await _pump(tester, caps: fakeDefaultCapabilities.copyWith(lowMemoryDevice: true));
      await _tapEdit(tester);
      expect(run.player.calls, ['pause', 'suspend:release']);
      run.route.pop();
      await _settle(tester);
      expect(run.player.calls.last, 'resume');
    });

    testWidgets('a second tap while launching is ignored', (tester) async {
      final repo = _GatedRepository()..gate = Completer<void>();
      final run = await _pump(tester, repository: repo);
      await tester.tap(find.text('Edit'));
      await tester.pump();
      expect(run.launcher.isRunning, isTrue);
      final second = await run.launcher.openFromPlayer(
        const EditorLaunchRequest(pathOrUri: _path, title: 'Holiday', position: Duration.zero),
        tester.element(find.text('Edit')),
        player: _FakePlayer(),
        openEditor: (_, __) async {},
      );
      expect(second, EditorLaunchOutcome.busy);
      repo.gate!.complete();
      await _settle(tester);
      expect(repo.createdSpecs, hasLength(1));
    });
  });

  test('editorLauncherProvider builds a launcher from the root providers', () {
    final h = EditorTestHarness();
    final launcher = h.container().read(editorLauncherProvider);
    expect(launcher.engine, same(h.engine));
    expect(launcher.repository, same(h.repository));
    expect(launcher.access, isNull, reason: 'the fake pool has no access port');
  });
}
