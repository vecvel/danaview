// OWNER: UX-25
//
// A rig for the speed panel tests: the editor harness with a real EditorController opened over
// FakeEditorEngine on a project with video, audio, silent and image clips (12 s of a 60 s source
// at 30 fps), and the panel placed in the inspector region by the real InspectorHost / InspectorDock.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/editor_providers.dart';
import 'package:vwish_editor/src/editor/contracts/contracts.dart';
import 'package:vwish_editor/src/editor/editor_scope.dart';
import 'package:vwish_editor/src/editor/inspector/inspector_dock.dart';
import 'package:vwish_editor/src/editor/inspector/inspector_host.dart';
import 'package:vwish_editor/src/editor/layout/editor_layout.dart';
import 'package:vwish_editor/src/editor/state/editor_controller.dart';
import 'package:vwish_editor/src/editor/state/editor_state.dart';
import 'package:vwish_editor/src/editor/state/playhead_controller.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_engine_api/testing.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart' show EditorCapabilities;

import '../../inspector/inspector_rig.dart' show RegionFrame, RigTicker;
import '../../support/support.dart';

export '../../inspector/inspector_rig.dart' show RegionFrame, frameSpec;

const int s = microsPerSecond;

/// The frame grid of the rig's project.
final FrameRate rate = FrameRate.fps30;

TimeUs frames(int n) => rate.timeOfFrame(n);

/// Ids of the rig's project.
abstract final class SpeedIds {
  /// Main video clip 0-12 s of `m_video` (60 s, with audio).
  static const ItemId video = ItemId('it_video');

  /// Main video clip 12-14 s of `m_silent` (no audio): the neighbour of [video].
  static const ItemId silent = ItemId('it_silent');

  /// Main image clip 14-16 s.
  static const ItemId image = ItemId('it_image');

  /// Audio clip 0-10 s of `m_song`.
  static const ItemId audio = ItemId('it_audio');

  /// Audio clip 0-4 s on a locked lane.
  static const ItemId locked = ItemId('it_locked');
}

MediaAsset _asset(String id, MediaKind kind, {bool hasAudio = true}) => MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: '$id.file',
      locator: AppRelativeLocator(AppRoot.support, 'vwish/editor/media/$id/file'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000, quickHash: id.padRight(40, '0')),
      probe: MediaProbe(
        kind: kind,
        duration: kind == MediaKind.image ? 0 : 60 * s,
        hasVideo: kind != MediaKind.audio,
        hasAudio: hasAudio,
        width: 1920,
        height: 1080,
      ),
      origin: MediaOrigin.files,
      addedAt: DateTime.utc(2026, 10, 1),
    );

MediaClip _clip(String id, String media, TimeUs start, TimeUs duration,
        {bool visual = true, SpeedSpec speed = SpeedSpec.normal, AudioProps? audio}) =>
    MediaClip(
      id: ItemId(id),
      start: start,
      duration: duration,
      media: MediaId(media),
      speed: speed,
      visual: visual ? const VisualProps() : null,
      audio: audio ?? AudioProps.unity,
    );

/// The project of the rig. [video] is the first clip (default: 12 s at normal speed).
EditProject speedProject(ProjectId id, {MediaClip? video, bool ripple = true}) => EditProject(
      id: id,
      meta: ProjectMeta(name: 'Speed', createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1)),
      timeline: Timeline(
        tracks: [
          Track(id: const TrackId('tr_main'), kind: TrackKind.video, isMain: true, items: [
            video ?? _clip('it_video', 'm_video', 0, 12 * s),
            _clip('it_silent', 'm_silent', 12 * s, 2 * s),
            _clip('it_image', 'm_image', 14 * s, 2 * s),
          ]),
          Track(id: const TrackId('tr_audio'), kind: TrackKind.audio, items: [_clip('it_audio', 'm_song', 0, 10 * s, visual: false)]),
          Track(
              id: const TrackId('tr_locked'),
              kind: TrackKind.audio,
              locked: true,
              items: [_clip('it_locked', 'm_song', 0, 4 * s, visual: false)]),
        ],
      ),
      pool: MediaPool({
        for (final a in [
          _asset('m_video', MediaKind.video),
          _asset('m_silent', MediaKind.video, hasAudio: false),
          _asset('m_image', MediaKind.image, hasAudio: false),
          _asset('m_song', MediaKind.audio),
        ])
          a.id: a,
      }),
      view: ViewState.initial.copyWith(rippleEnabled: ripple),
    );

/// The harness around the real inspector with a real, opened EditorController.
class SpeedRig {
  SpeedRig._(this.harness, this.id, this.tester, this.ticker);

  /// Harness.
  final EditorTestHarness harness;

  /// Project id.
  final ProjectId id;

  /// Tester.
  final WidgetTester tester;

  /// The playhead's ticker.
  final RigTicker ticker;

  /// The fake engine (its capabilities are what the panel reads).
  FakeEditorEngine get engine => harness.engine;

  /// The container of the pumped app.
  ProviderContainer get container => harness.containerOf(tester);

  /// The editor controller.
  EditorController get editor => container.read(editorControllerProvider(id).notifier);

  /// The editor state.
  EditorState get state => container.read(editorControllerProvider(id));

  /// The playhead.
  PlayheadController get playhead => container.read(playheadProvider(id));

  /// The committed (or working) project.
  EditProject get project => state.project!;

  /// The clip [id] of the project.
  MediaClip clip(ItemId id) => project.index.item(id)! as MediaClip;

  /// The history position (entries applied).
  int get entries => state.history.position;

  /// Pumps the panel host for [open] and opens the editor.
  static Future<SpeedRig> pump(
    WidgetTester tester, {
    EditorSurface surface = const EditorSurface(Size(1280, 900)),
    ItemId? open = SpeedIds.video,
    EditorCapabilities? caps,
    MediaClip? video,
    bool ripple = true,
    List<Override> overrides = const [],
    bool selectOpen = true,
  }) async {
    final repo = FakeProjectRepository();
    final empty = repo.seedEmpty('Speed');
    final project = speedProject(empty.id, video: video, ripple: ripple);
    repo.seed(project);
    final ticker = RigTicker();
    final engine = FakeEditorEngine(validatePlans: false);
    if (caps != null) engine.caps = caps;
    final harness = EditorTestHarness(
      engine: engine,
      repository: repo,
      overrides: [
        playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: () => Duration.zero)),
        ...overrides,
      ],
    );
    final rig = SpeedRig._(harness, project.id, tester, ticker);
    await harness.pumpApp(
      tester,
      EditorScope(
        projectId: project.id,
        child: const RegionFrame(
          inspectorOpen: true,
          regions: {EditorRegion.pane: InspectorHost()},
          dock: InspectorDock(),
        ),
      ),
      surface: surface,
    );
    await rig.real(() => rig.editor.open());
    if (open != null) {
      if (selectOpen) rig.editor.select(open);
      rig.editor.openInspector(SpeedInspector(open));
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

  /// Seeks the playhead exactly to [t] and settles.
  Future<void> seek(TimeUs t) async {
    await real(() async {
      await playhead.seekExact(t);
    });
    await tester.pump();
  }
}
