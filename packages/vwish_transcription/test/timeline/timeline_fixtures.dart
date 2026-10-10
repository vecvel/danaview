// OWNER: AI-12
//
// Builders shared by the timeline tests: pool assets, clips, tracks and projects (times in ms).

import 'package:vwish_editor_core/model.dart';
import 'package:vwish_transcription/vwish_transcription.dart';

/// Milliseconds as µs.
TimeUs ms(int v) => v * 1000;

/// Seconds as µs.
TimeUs sec(num v) => (v * 1000000).round();

final DateTime when = DateTime.utc(2026, 10, 10);

/// A pool asset (`qh_<id>` is its quick hash).
MediaAsset asset(
  String id, {
  MediaKind kind = MediaKind.video,
  TimeUs? duration,
  bool hasAudio = true,
  DerivedSpec? derived,
}) =>
    MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: id,
      locator: AppRelativeLocator(AppRoot.documents, id),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000, quickHash: 'qh_$id'),
      probe: MediaProbe(
        kind: kind,
        duration: kind == MediaKind.image ? 0 : duration ?? sec(60),
        hasVideo: kind == MediaKind.video,
        hasAudio: (kind == MediaKind.video || kind == MediaKind.audio) && hasAudio,
        width: kind == MediaKind.audio ? null : 1920,
        height: kind == MediaKind.audio ? null : 1080,
      ),
      origin: MediaOrigin.files,
      derived: derived,
      addedAt: when,
    );

/// A media clip on the timeline range `[startMs, endMs)` showing the source from [sourceInMs].
MediaClip clip(
  String id,
  int startMs,
  int endMs,
  String media, {
  int sourceInMs = 0,
  SpeedSpec speed = SpeedSpec.normal,
  bool reversed = false,
  int? audioStream,
  double volume = 1,
  bool muted = false,
  bool detached = false,
}) =>
    MediaClip(
      id: ItemId(id),
      start: ms(startMs),
      duration: ms(endMs - startMs),
      media: MediaId(media),
      sourceIn: ms(sourceInMs),
      speed: speed,
      reversed: reversed,
      audioStream: audioStream,
      audio: AudioProps(volume: volume, muted: muted),
      detachedAudio: detached,
    );

/// The main video track.
Track mainTrack(List<TimelineItem> items, {String id = 'tr_main', bool muted = false, bool solo = false}) =>
    Track(id: TrackId(id), kind: TrackKind.video, isMain: true, items: items, muted: muted, solo: solo);

/// A track of [kind] (audio lanes take [role]).
Track lane(
  String id,
  TrackKind kind,
  List<TimelineItem> items, {
  AudioRole? role,
  bool muted = false,
  bool solo = false,
}) =>
    Track(
      id: TrackId(id),
      kind: kind,
      items: items,
      audioRole: kind == TrackKind.audio ? role ?? AudioRole.original : null,
      muted: muted,
      solo: solo,
      subtitle: kind == TrackKind.subtitle ? const SubtitleTrackData() : null,
    );

/// A project at 30 fps; [tracks] must be in canonical order.
EditProject project(List<Track> tracks, List<MediaAsset> assets, {ProjectSettings settings = const ProjectSettings()}) => EditProject(
      id: const ProjectId('pr_aaaaaaaaaaaa'),
      meta: ProjectMeta(name: 'Trip', createdAt: when, updatedAt: when),
      timeline: Timeline(settings: settings, tracks: tracks),
      pool: MediaPool({for (final a in assets) a.id: a}),
    );

/// A recognized word in source ms.
TranscriptWord sw(String text, int startMs, int endMs, {double p = 0.9}) =>
    TranscriptWord(text: text, startUs: ms(startMs), endUs: ms(endMs), probability: p);

/// Plans with the default planner.
TranscriptionPlan plan(EditProject p, [TranscriptionScope scope = const TimelineScope()]) =>
    const TranscriptionPlanner().plan(DomainTimelineView(p), scope);

/// The clip ids of a unit.
List<String> clipIds(TranscriptionUnit u) => [for (final c in u.clips) c.id.value];
