// OWNER: UX-26
//
// A rig for the Keyframes panel tests: the editor harness with a real EditorController opened over
// FakeEditorEngine on a 30 fps project, and the panel placed in the inspector region by the real
// InspectorHost / InspectorDock.
//
// The project:
// * `it_video` 0-6 s (main lane): opacity keys at 0 s (100%), 1 s (50%) and 3 s (0%), exposure keys
//   at 0 s and 2 s;
// * `it_plain` 6-10 s (main lane): a video clip with no keys;
// * `it_image` 10-12 s (main lane): an image with no keys;
// * `it_audio` 0-8 s (audio lane): volume keys at 1 s and 4 s;
// * `it_locked` 0-4 s (locked overlay lane): opacity keys at 0 s and 2 s;
// * `it_text` 0-5 s (text lane): no keys.

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
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/testing.dart';

import '../../inspector/inspector_rig.dart' show RegionFrame, RigTicker;
import '../../support/support.dart';

export '../../inspector/inspector_rig.dart' show RegionFrame, frameSpec;

const int s = microsPerSecond;

/// The frame grid of the rig's project.
final FrameRate rate = FrameRate.fps30;

/// The time of frame [n] (also the item-local time of a key on frame [n] of an item at 0).
TimeUs frames(int n) => rate.timeOfFrame(n);

/// Ids of the rig's project.
abstract final class KfIds {
  /// Video clip 0-6 s with opacity and exposure keys.
  static const ItemId video = ItemId('it_video');

  /// Video clip 6-10 s without keys.
  static const ItemId plain = ItemId('it_plain');

  /// Image clip 10-12 s without keys.
  static const ItemId image = ItemId('it_image');

  /// Audio clip 0-8 s with volume keys.
  static const ItemId audio = ItemId('it_audio');

  /// Video clip 0-4 s on a locked overlay lane, with opacity keys.
  static const ItemId locked = ItemId('it_locked');

  /// Text 0-5 s without keys.
  static const ItemId text = ItemId('it_text');
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
        duration: kind == MediaKind.image ? 0 : 60 * s,
        hasVideo: kind != MediaKind.audio,
        hasAudio: hasAudio,
        width: 1920,
        height: 1080,
      ),
      origin: MediaOrigin.files,
      addedAt: DateTime.utc(2026, 10, 1),
    );

KeyframeTrack _track(Map<int, double> byFrame) => KeyframeTrack([for (final e in byFrame.entries) Keyframe(frames(e.key), e.value)]);

MediaClip _clip(String id, String media, TimeUs start, TimeUs duration, {bool visual = true, KeyframeSet keys = KeyframeSet.empty}) =>
    MediaClip(
      id: ItemId(id),
      start: start,
      duration: duration,
      media: MediaId(media),
      visual: visual ? const VisualProps() : null,
      audio: AudioProps.unity,
      keyframes: keys,
    );

/// The project of the rig.
EditProject keyframesProject(ProjectId id) => EditProject(
      id: id,
      meta: ProjectMeta(name: 'Keyframes', createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1)),
      timeline: Timeline(
        tracks: [
          Track(id: const TrackId('tr_main'), kind: TrackKind.video, isMain: true, items: [
            _clip(
              'it_video',
              'm_video',
              0,
              6 * s,
              keys: KeyframeSet({
                'transform.opacity': _track({0: 1.0, 30: 0.5, 90: 0.0}),
                'adjust.exposure': _track({0: 0.0, 60: 0.4}),
              }),
            ),
            _clip('it_plain', 'm_video', 6 * s, 4 * s),
            _clip('it_image', 'm_image', 10 * s, 2 * s),
          ]),
          Track(id: const TrackId('tr_overlay'), kind: TrackKind.overlay, locked: true, items: [
            _clip('it_locked', 'm_video', 0, 4 * s,
                keys: KeyframeSet({
                  'transform.opacity': _track({0: 1.0, 60: 0.2})
                })),
          ]),
          Track(id: const TrackId('tr_text'), kind: TrackKind.text, items: [
            const TextItem(id: ItemId('it_text'), start: 0, duration: 5 * s, text: 'Title'),
          ]),
          Track(id: const TrackId('tr_audio'), kind: TrackKind.audio, items: [
            _clip('it_audio', 'm_song', 0, 8 * s,
                visual: false,
                keys: KeyframeSet({
                  'audio.volume': _track({30: 1.0, 120: 0.5})
                })),
          ]),
        ],
      ),
      pool: MediaPool({
        for (final a in [
          _asset('m_video', MediaKind.video),
          _asset('m_image', MediaKind.image, hasAudio: false),
          _asset('m_song', MediaKind.audio),
        ])
          a.id: a,
      }),
      view: ViewState.initial,
    );

/// The harness around the real inspector with a real, opened EditorController.
class KfRig {
  KfRig._(this.harness, this.id, this.tester, this.ticker);

  /// Harness.
  final EditorTestHarness harness;

  /// Project id.
  final ProjectId id;

  /// Tester.
  final WidgetTester tester;

  /// The playhead's ticker.
  final RigTicker ticker;

  /// The container of the pumped app.
  ProviderContainer get container => harness.containerOf(tester);

  /// The editor controller.
  EditorController get editor => container.read(editorControllerProvider(id).notifier);

  /// The editor state.
  EditorState get state => container.read(editorControllerProvider(id));

  /// The playhead.
  PlayheadController get playhead => container.read(playheadProvider(id));

  /// The project.
  EditProject get project => state.project!;

  /// The item [id] of the project.
  TimelineItem item(ItemId id) => project.index.item(id)!;

  /// The item-local key times of [key] on [id].
  List<TimeUs> keys(ItemId id, PropertyKey<Object?> key) => KeyframeOps.keyTimes(keyframesOf(item(id)), key);

  /// The values of the channel [channel] on [id] by item-local time.
  Map<TimeUs, double> values(ItemId id, String channel) =>
      {for (final k in keyframesOf(item(id))[channel]?.keys ?? const <Keyframe>[]) k.t: k.v};

  /// The history position (entries applied).
  int get entries => state.history.position;

  /// Pumps the panel host, opens the editor, seeks to [at] and opens the panel on [open].
  static Future<KfRig> pump(
    WidgetTester tester, {
    EditorSurface surface = const EditorSurface(Size(1280, 900)),
    ItemId? open = KfIds.video,
    TimeUs at = 0,
    bool selectOpen = true,
    List<Override> overrides = const [],
  }) async {
    final repo = FakeProjectRepository();
    final empty = repo.seedEmpty('Keyframes');
    final project = keyframesProject(empty.id);
    repo.seed(project);
    final ticker = RigTicker();
    final engine = FakeEditorEngine(validatePlans: false);
    final harness = EditorTestHarness(
      engine: engine,
      repository: repo,
      overrides: [
        playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: () => Duration.zero)),
        ...overrides,
      ],
    );
    final rig = KfRig._(harness, project.id, tester, ticker);
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
    if (at != 0) await rig.seek(at);
    if (open != null) {
      if (selectOpen) rig.editor.select(open);
      rig.editor.openInspector(KeyframesInspector(open));
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
