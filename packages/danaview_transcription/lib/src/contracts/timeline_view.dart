// OWNER: AI-08
//
// The read-only project view the pipeline needs (ai.md §10.1). `DomainTimelineView` (AI-13)
// adapts `EditProject`; a fresh view is read at the start (plan) and again at the end (mapping),
// so edits made during a job are honoured.

import 'dart:ui' show Size;

import 'package:danaview_editor_core/model.dart';

/// One track as the pipeline sees it.
abstract interface class TrackView {
  /// Id.
  TrackId get id;

  /// Kind.
  TrackKind get kind;

  /// Audio role (audio tracks).
  AudioRole? get role;

  /// Track flags.
  bool get muted;

  /// Solo flag.
  bool get solo;

  /// Hidden flag.
  bool get hidden;

  /// Locked flag (generated captions cannot replace a locked track).
  bool get locked;

  /// Whether this is the main video track.
  bool get isMain;
}

/// One audible media clip.
abstract interface class AudibleClipView {
  /// Clip id.
  ItemId get id;

  /// Track.
  TrackId get track;

  /// Pool asset.
  MediaId get media;

  /// `quickHash` of the media (transcript cache key).
  String get mediaQuickHash;

  /// Audio stream, null = first.
  int? get audioStream;

  /// Timeline range.
  TimeRange get timelineRange;

  /// Source range.
  TimeRange get sourceRange;

  /// Reversed clips are excluded (reported).
  bool get reversed;

  /// Freeze frames are excluded.
  bool get isFreeze;

  /// 0 when muted, track muted or not soloed.
  double get effectiveVolume;

  /// Timeline time at which source time [s] is shown, or null when trimmed away; inverts
  /// constant speed and ramps exactly (CORE-06 `ClipTimeMap.timelineTimeOf`).
  TimeUs? timelineTimeOf(TimeUs s);
}

/// One cue of a subtitle track.
abstract interface class CueView {
  /// Cue id.
  ItemId get id;

  /// Timeline range.
  TimeRange get range;

  /// Text.
  String get text;

  /// Origin.
  CueOrigin get origin;

  /// Edited after generation (Regenerate asks first).
  bool get editedAfterGeneration;
}

/// One subtitle track.
abstract interface class SubtitleTrackView {
  /// Track id.
  TrackId get id;

  /// Display name.
  String get name;

  /// BCP-47 language.
  String? get language;

  /// Provenance of generated captions.
  CaptionProvenance? get provenance;

  /// Cues in time order.
  List<CueView> get cues;
}

/// The project as Auto captions reads it.
abstract interface class TimelineView {
  /// Project.
  ProjectId get project;

  /// Project frame rate (cue edges are quantized to it).
  FrameRate get frameRate;

  /// Canvas size (9:16 projects use 32 characters per line).
  Size get canvasSize;

  /// Timeline duration.
  TimeUs get duration;

  /// Tracks in canonical order.
  Iterable<TrackView> get tracks;

  /// Audible media clips.
  Iterable<AudibleClipView> audibleClips();

  /// Subtitle tracks.
  Iterable<SubtitleTrackView> get subtitleTracks;

  /// Clip boundaries on audible tracks (segmentation cut points).
  List<TimeUs> get cutPoints;

  /// Resolves a pool asset for audio extraction (null when offline).
  Future<ResolvedMedia?> resolveMedia(MediaId media);
}
