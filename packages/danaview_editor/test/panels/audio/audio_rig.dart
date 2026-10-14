// OWNER: UX-33
//
// A rig for the audio panel tests: the editor harness with a real EditorController opened over
// FakeEditorEngine and UX-06's ScriptedPool (Add music imports) on a project with a video with
// sound, a silent video, a music clip, an "original" lane and a locked lane (30 fps), and the panel
// placed in the inspector region by the real InspectorHost / InspectorDock.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/editor_scope.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_dock.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_host.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/state/playhead_controller.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/testing.dart';

import '../../flows/import/import_fakes.dart';
import '../../inspector/inspector_rig.dart' show RegionFrame, RigTicker;
import '../../support/support.dart';

export '../../flows/import/import_fakes.dart' show AddStep, ScriptedPool, pickOf;
export '../../inspector/inspector_rig.dart' show RegionFrame;

const int s = microsPerSecond;

/// Ids of the rig's project.
abstract final class AudioIds {
  /// Main video clip 0-12 s of `m_video` (60 s, with audio).
  static const ItemId video = ItemId('it_video');

  /// Main video clip 12-14 s of `m_silent` (no audio).
  static const ItemId silent = ItemId('it_silent');

  /// Music clip 0-10 s of `m_song` on the music lane.
  static const ItemId music = ItemId('it_music');

  /// Audio clip 0-4 s on a locked lane.
  static const ItemId locked = ItemId('it_locked');

  /// The main lane.
  static const TrackId main = TrackId('tr_main');

  /// The music lane (role music).
  static const TrackId musicLane = TrackId('tr_music');

  /// The locked audio lane.
  static const TrackId lockedLane = TrackId('tr_locked');
}

MediaAsset _asset(String id, MediaKind kind, {bool hasAudio = true}) => MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: '$id.file',
      locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/media/$id/file'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000, quickHash: id.padRight(40, '0')),
      probe: MediaProbe(
        kind: kind,
        duration: 60 * s,
        hasVideo: kind == MediaKind.video,
        hasAudio: hasAudio,
        width: kind == MediaKind.video ? 1920 : null,
        height: kind == MediaKind.video ? 1080 : null,
      ),
      origin: MediaOrigin.files,
      addedAt: DateTime.utc(2026, 10, 1),
    );

MediaClip _clip(String id, String media, TimeUs start, TimeUs duration, {bool visual = true, AudioProps? audio}) => MediaClip(
      id: ItemId(id),
      start: start,
      duration: duration,
      media: MediaId(media),
      visual: visual ? const VisualProps() : null,
      audio: audio ?? AudioProps.unity,
    );

/// The project of the rig. [video] replaces the first clip; [music] adds the music lane.
EditProject audioProject(ProjectId id, {MediaClip? video, bool music = true, bool ripple = true}) => EditProject(
      id: id,
      meta: ProjectMeta(name: 'Audio', createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1)),
      timeline: Timeline(
        tracks: [
          Track(id: AudioIds.main, kind: TrackKind.video, isMain: true, items: [
            video ?? _clip('it_video', 'm_video', 0, 12 * s),
            _clip('it_silent', 'm_silent', 12 * s, 2 * s),
          ]),
          if (music)
            Track(
                id: AudioIds.musicLane,
                kind: TrackKind.audio,
                audioRole: AudioRole.music,
                items: [_clip('it_music', 'm_song', 0, 10 * s, visual: false)]),
          Track(
              id: AudioIds.lockedLane,
              kind: TrackKind.audio,
              audioRole: AudioRole.effects,
              locked: true,
              items: [_clip('it_locked', 'm_song', 0, 4 * s, visual: false)]),
        ],
      ),
      pool: MediaPool({
        for (final a in [
          _asset('m_video', MediaKind.video),
          _asset('m_silent', MediaKind.video, hasAudio: false),
          _asset('m_song', MediaKind.audio),
        ])
          a.id: a,
      }),
      view: ViewState.initial.copyWith(rippleEnabled: ripple),
    );

/// The harness around the real inspector with a real, opened EditorController.
class AudioRig {
  AudioRig._(this.harness, this.id, this.tester, this.ticker, this.pool);

  /// Harness.
  final EditorTestHarness harness;

  /// Project id.
  final ProjectId id;

  /// Tester.
  final WidgetTester tester;

  /// The playhead's ticker.
  final RigTicker ticker;

  /// The media pool service (Add music imports through it).
  final ScriptedPool pool;

  /// The fake engine.
  FakeEditorEngine get engine => harness.engine;

  /// The container of the pumped app.
  ProviderContainer get container => harness.containerOf(tester);

  /// The editor controller.
  EditorController get editor => container.read(editorControllerProvider(id).notifier);

  /// The editor state.
  EditorState get state => container.read(editorControllerProvider(id));

  /// The playhead.
  PlayheadController get playhead => container.read(playheadProvider(id));

  /// The working project.
  EditProject get project => state.project!;

  /// The clip [id] of the project.
  MediaClip clip(ItemId id) => project.index.item(id)! as MediaClip;

  /// The track [id] of the project.
  Track track(TrackId id) => project.timeline.tracks.singleWhere((t) => t.id == id);

  /// The history position (entries applied).
  int get entries => state.history.position;

  /// Label of the newest history entry.
  String? get undoLabel => state.history.undoLabel;

  /// Pumps the panel host for [open] and opens the editor.
  static Future<AudioRig> pump(
    WidgetTester tester, {
    EditorSurface surface = const EditorSurface(Size(1280, 900)),
    ItemId? open = AudioIds.video,
    AudioPanelFocus focus = AudioPanelFocus.volume,
    MediaClip? video,
    bool music = true,
    bool ripple = true,
    bool selectOpen = true,
    ScriptedPool? pool,
  }) async {
    final repo = FakeProjectRepository();
    final empty = repo.seedEmpty('Audio');
    final project = audioProject(empty.id, video: video, music: music, ripple: ripple);
    repo.seed(project);
    final ticker = RigTicker();
    final scripted = pool ?? ScriptedPool();
    final harness = EditorTestHarness(
      engine: FakeEditorEngine(validatePlans: false),
      repository: repo,
      mediaPool: scripted,
      overrides: [
        mediaPoolServiceProvider.overrideWithValue(scripted),
        playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: () => Duration.zero)),
      ],
    );
    final rig = AudioRig._(harness, project.id, tester, ticker, scripted);
    EditorAnnouncer.instance.reset();
    addTearDown(EditorAnnouncer.instance.reset);
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
      rig.editor.openInspector(AudioInspector(open, focus: focus));
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
