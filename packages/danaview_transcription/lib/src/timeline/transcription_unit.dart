// OWNER: AI-12
//
// Units of work (ARCH §16.4 step 1, ai.md §8.2): one unit is one media file and audio stream,
// one source range to transcribe, and the clips that show it.

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart';

import '../contracts/transcription_service.dart' show SkippedClip;

/// Overlap priority of a stream (ai.md §10.1): voice > main video > other video > other audio >
/// music. Higher wins.
abstract final class StreamPriority {
  /// Music tracks.
  static const int music = 0;

  /// Audio lanes that are not voice or music (original, effects, no role).
  static const int otherAudio = 1;

  /// Overlay and non-main video lanes.
  static const int otherVideo = 2;

  /// The main video lane.
  static const int mainVideo = 3;

  /// Voice-over lanes.
  static const int voice = 4;
}

/// One clip of a unit, as planned.
@immutable
final class UnitClip {
  /// Creates the record.
  const UnitClip({
    required this.id,
    required this.track,
    required this.timelineRange,
    required this.sourceRange,
    required this.priority,
    required this.trackRank,
  });

  /// Clip id (the mapping re-reads the clip from a fresh timeline by this id).
  final ItemId id;

  /// Track.
  final TrackId track;

  /// Timeline range when planned.
  final TimeRange timelineRange;

  /// Source range when planned (restricted to the scope range when one was given).
  final TimeRange sourceRange;

  /// [StreamPriority] of the clip's track.
  final int priority;

  /// Tie-break among equal priorities: the higher rank wins ("ties go to the higher track").
  final int trackRank;

  @override
  bool operator ==(Object other) =>
      other is UnitClip &&
      other.id == id &&
      other.track == track &&
      other.timelineRange == timelineRange &&
      other.sourceRange == sourceRange &&
      other.priority == priority &&
      other.trackRank == trackRank;

  @override
  int get hashCode => Object.hash(id, track, timelineRange, sourceRange, priority, trackRank);
}

/// One media file's audio to transcribe.
@immutable
final class TranscriptionUnit {
  /// Creates a unit.
  TranscriptionUnit({
    required this.media,
    required this.mediaQuickHash,
    required this.audioStream,
    required this.sourceRange,
    required this.coreRange,
    required List<UnitClip> clips,
    required this.priority,
  })  : clips = List.unmodifiable(clips),
        clipIds = Set.unmodifiable({for (final c in clips) c.id});

  /// Pool asset.
  final MediaId media;

  /// `quickHash` of the media (transcript cache key).
  final String mediaQuickHash;

  /// Audio stream; null = the first.
  final int? audioStream;

  /// The range to transcribe: [coreRange] padded by 0.5 s on both sides, clamped to the media.
  final TimeRange sourceRange;

  /// The union of the clips' source ranges, unpadded.
  final TimeRange coreRange;

  /// The clips that show this media, in timeline order.
  final List<UnitClip> clips;

  /// Ids of [clips] (the `clips` set of ARCH §16.4).
  final Set<ItemId> clipIds;

  /// The best [StreamPriority] among the clips.
  final int priority;

  /// The stream index with null meaning the first.
  int get audioStreamIndex => audioStream ?? 0;

  /// Duration to transcribe.
  TimeUs get duration => sourceRange.duration;

  @override
  bool operator ==(Object other) =>
      other is TranscriptionUnit &&
      other.media == media &&
      other.mediaQuickHash == mediaQuickHash &&
      other.audioStream == audioStream &&
      other.sourceRange == sourceRange &&
      other.coreRange == coreRange &&
      other.priority == priority &&
      const ListEquality<UnitClip>().equals(other.clips, clips);

  @override
  int get hashCode => Object.hash(media, mediaQuickHash, audioStream, sourceRange, coreRange, priority, Object.hashAll(clips));

  @override
  String toString() => 'TranscriptionUnit($media#$audioStreamIndex $sourceRange, ${clips.length} clips)';
}

/// What the planner decided.
@immutable
final class TranscriptionPlan {
  /// Creates a plan.
  TranscriptionPlan({required List<TranscriptionUnit> units, List<SkippedClip> skipped = const []})
      : units = List.unmodifiable(units),
        skipped = List.unmodifiable(skipped);

  /// Units in timeline order of their first clip.
  final List<TranscriptionUnit> units;

  /// Clips that were not planned, with a reason code (`muted`, `reversed`, `noAudio`).
  final List<SkippedClip> skipped;

  /// Whether there is nothing to transcribe.
  bool get isEmpty => units.isEmpty;

  /// Total audio to transcribe.
  TimeUs get totalDuration => units.fold(0, (n, u) => n + u.duration);

  /// The unit language detection runs on: the highest priority, then the longest, then the
  /// earliest (ai.md §8.2 step 5). Null when the plan is empty.
  TranscriptionUnit? get detectionUnit {
    TranscriptionUnit? best;
    for (final u in units) {
      if (best == null ||
          u.priority > best.priority ||
          (u.priority == best.priority && u.duration > best.duration)) {
        best = u;
      }
    }
    return best;
  }
}
