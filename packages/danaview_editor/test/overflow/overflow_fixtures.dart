// OWNER: QA-09
//
// Long-content fixtures for the no-overflow matrix (BUILD_PLAN QA-09, ARCH §1.3 rule 5, §17.9):
// a project whose every user-visible string is as long as the product allows (80-character project
// name, long track names, long media file names, multi-line text and caption content, long marker
// names and notes) over every lane kind, with a cross dissolve, so each surface is rendered with the
// worst realistic content.

import 'package:danaview_editor_core/model.dart';

import '../support/support.dart';

const int _s = microsPerSecond;

/// The longest project name the model accepts (80 characters).
const String longProjectName = 'Goa trip with the whole family and friends, final cut for grandma, version 12 b';

/// A long file name without spaces (the hardest case for wrapping).
const String longFileName = 'VID_20261014_183455_a_very_long_camera_file_name_without_any_spaces_at_all_final.mp4';

/// A long multi-line text overlay.
const String longText = 'Welcome to the longest title card anybody ever typed on a phone keyboard\n'
    'Second line with Ünïcödé, emoji-free, and a very long unbroken word: Donaudampfschifffahrtsgesellschaft';

/// A long two-line caption.
const String longCue = 'This is a deliberately long caption line that will wrap on narrow screens\n'
    'and a second line that keeps going to test the cue list rows';

/// A long marker name.
const String longMarkerName = 'Chorus starts here, remember to cut on the downbeat of the drum fill';

/// Ids of the long-content project.
abstract final class LongIds {
  /// Project.
  static const ProjectId project = ProjectId('pr_overflow0001');

  /// Main lane.
  static const TrackId main = TrackId('tr_ovmain00001');

  /// Overlay lane.
  static const TrackId overlay = TrackId('tr_ovover00001');

  /// Text lane.
  static const TrackId text = TrackId('tr_ovtext00001');

  /// Subtitle lane.
  static const TrackId subtitles = TrackId('tr_ovsubs00001');

  /// Music lane.
  static const TrackId music = TrackId('tr_ovmusc00001');

  /// Voice lane.
  static const TrackId voice = TrackId('tr_ovvoic00001');

  /// Main video clip A (0-4 s).
  static const ItemId clipA = ItemId('it_ovclipa0001');

  /// Main video clip B (4-8 s), after a cross dissolve.
  static const ItemId clipB = ItemId('it_ovclipb0001');

  /// Main image clip (8-11 s).
  static const ItemId still = ItemId('it_ovstill0001');

  /// Overlay image (1-3 s).
  static const ItemId overlayItem = ItemId('it_ovoverl0001');

  /// Text (0-5 s).
  static const ItemId textItem = ItemId('it_ovtext00001');

  /// Caption 1 (1-3 s).
  static const ItemId cue1 = ItemId('it_ovcue000001');

  /// Caption 2 (3-6 s).
  static const ItemId cue2 = ItemId('it_ovcue000002');

  /// Music clip (0-11 s).
  static const ItemId musicItem = ItemId('it_ovmusic0001');

  /// Voice clip (2-5 s).
  static const ItemId voiceItem = ItemId('it_ovvoice0001');

  /// The A|B cut.
  static const TransitionRef cut = TransitionRef(main, clipA, clipB);
}

MediaAsset _asset(String id, MediaKind kind, String name, {int? w, int? h}) => MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: name,
      locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/media/$id/file'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 123456789, quickHash: id.padRight(40, '0')),
      probe: MediaProbe(
        kind: kind,
        duration: kind == MediaKind.image ? 0 : 60 * _s,
        hasVideo: kind == MediaKind.video || kind == MediaKind.image,
        hasAudio: kind == MediaKind.video || kind == MediaKind.audio,
        width: w,
        height: h,
      ),
      origin: MediaOrigin.files,
      addedAt: DateTime.utc(2026, 10, 1),
    );

/// The long-content project (30 fps, 16:9): main lane with two video clips joined by a cross
/// dissolve and an image; an overlay image; a two-line text; a subtitle track with two long cues;
/// music and voice lanes; three markers. Not seeded: see [seedLongProject].
EditProject longProject({ProjectId id = LongIds.project, String name = longProjectName}) {
  final main = Track(
    id: LongIds.main,
    kind: TrackKind.video,
    isMain: true,
    name: 'Main camera with a very long track name that never fits',
    items: [
      MediaClip(id: LongIds.clipA, start: 0, duration: 4 * _s, media: const MediaId('md_ovvid000001'), sourceIn: 2 * _s, visual: VisualProps.neutral, label: longFileName),
      MediaClip(id: LongIds.clipB, start: 4 * _s, duration: 4 * _s, media: const MediaId('md_ovvid000002'), sourceIn: 2 * _s, visual: VisualProps.neutral),
      MediaClip(id: LongIds.still, start: 8 * _s, duration: 3 * _s, media: const MediaId('md_ovimg000001'), visual: VisualProps.neutral),
    ],
    transitions: const [
      Transition(id: TransitionId('tx_ovcross0001'), left: LongIds.clipA, right: LongIds.clipB, kind: TransitionKind.crossDissolve, durationFrames: 15),
    ],
  );
  final overlay = Track(
    id: LongIds.overlay,
    kind: TrackKind.overlay,
    name: 'Picture in picture overlay lane with a long name',
    items: [MediaClip(id: LongIds.overlayItem, start: 1 * _s, duration: 2 * _s, media: const MediaId('md_ovimg000001'), visual: VisualProps.neutral)],
  );
  final text = Track(
    id: LongIds.text,
    kind: TrackKind.text,
    name: 'Titles and lower thirds for the whole film',
    items: [const TextItem(id: LongIds.textItem, start: 0, duration: 5 * _s, text: longText)],
  );
  final subtitles = Track(
    id: LongIds.subtitles,
    kind: TrackKind.subtitle,
    name: 'English (United Kingdom) captions, reviewed twice',
    subtitle: const SubtitleTrackData(language: 'en-GB'),
    items: const [
      SubtitleCue(id: LongIds.cue1, start: 1 * _s, duration: 2 * _s, text: longCue),
      SubtitleCue(id: LongIds.cue2, start: 3 * _s, duration: 3 * _s, text: longCue),
    ],
  );
  final music = Track(
    id: LongIds.music,
    kind: TrackKind.audio,
    audioRole: AudioRole.music,
    name: 'Background music bed with a long descriptive name',
    items: [const MediaClip(id: LongIds.musicItem, start: 0, duration: 11 * _s, media: MediaId('md_ovsong00001'))],
  );
  final voice = Track(
    id: LongIds.voice,
    kind: TrackKind.audio,
    audioRole: AudioRole.voice,
    name: 'Voiceover narration take seven (the good one)',
    items: [const MediaClip(id: LongIds.voiceItem, start: 2 * _s, duration: 3 * _s, media: MediaId('md_ovvoice0001'))],
  );
  final now = DateTime.utc(2026, 10, 1);
  return EditProject(
    id: id,
    meta: ProjectMeta(name: name, createdAt: now, updatedAt: now),
    timeline: Timeline(
      tracks: [main, overlay, text, subtitles, music, voice],
      markers: const [
        Marker(id: MarkerId('mk_ovmark00001'), time: 2 * _s, name: longMarkerName, note: longCue),
        Marker(id: MarkerId('mk_ovmark00002'), time: 6 * _s, name: longMarkerName, colorIndex: 3),
        Marker(id: MarkerId('mk_ovmark00003'), time: 9 * _s),
      ],
    ),
    pool: MediaPool({
      for (final a in [
        _asset('md_ovvid000001', MediaKind.video, longFileName, w: 3840, h: 2160),
        _asset('md_ovvid000002', MediaKind.video, 'PXL_20261014_183455123.TS.mp4', w: 1080, h: 1920),
        _asset('md_ovimg000001', MediaKind.image, 'IMG_20261014_extraordinarily_long_photo_name_from_messenger_export.jpeg', w: 4032, h: 3024),
        _asset('md_ovsong00001', MediaKind.audio, 'A very long song title (feat. many artists) [extended club remix 2026].m4a'),
        _asset('md_ovvoice0001', MediaKind.audio, 'Voiceover 2026-10-14 18.34.55 take 7.wav'),
      ])
        a.id: a,
    }),
  );
}

/// Seeds [longProject] into [repo] and returns it.
EditProject seedLongProject(FakeProjectRepository repo, {ProjectId id = LongIds.project, String name = longProjectName}) {
  final project = longProject(id: id, name: name);
  repo.seed(project);
  return project;
}
