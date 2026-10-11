// OWNER: CORE-03
//
// Shared builders for the core model tests.

import 'package:danaview_editor_core/model.dart';

const FrameRate r30 = FrameRate.fps30;

/// Time of frame [k] at 30 fps.
TimeUs f(int k) => r30.timeOfFrame(k);

MediaClip clip(String id, int startFrame, int frames, {String media = 'md_aaaaaaaaaaaa', VisualProps? visual}) => MediaClip(
      id: ItemId(id),
      start: f(startFrame),
      duration: f(startFrame + frames) - f(startFrame),
      media: MediaId(media),
      visual: visual,
    );

TextItem text(String id, int startFrame, int frames) => TextItem(
      id: ItemId(id),
      start: f(startFrame),
      duration: f(startFrame + frames) - f(startFrame),
      text: 'Hello',
    );

SubtitleCue cue(String id, int startFrame, int frames) => SubtitleCue(
      id: ItemId(id),
      start: f(startFrame),
      duration: f(startFrame + frames) - f(startFrame),
      text: 'Hi',
    );

Track track(String id, TrackKind kind, {bool main = false, List<TimelineItem> items = const []}) => Track(
      id: TrackId(id),
      kind: kind,
      isMain: main,
      items: items,
      audioRole: kind == TrackKind.audio ? AudioRole.music : null,
      subtitle: kind == TrackKind.subtitle ? const SubtitleTrackData() : null,
    );

final DateTime t0 = DateTime.utc(2026, 10, 8, 12);

EditProject project({List<Track>? tracks, MediaPool pool = MediaPool.empty}) => EditProject(
      id: const ProjectId('pr_aaaaaaaaaaaa'),
      meta: ProjectMeta(name: 'Trip', createdAt: t0, updatedAt: t0),
      timeline: Timeline(tracks: tracks ?? [track('tr_video0000001', TrackKind.video, main: true)]),
      pool: pool,
    );
