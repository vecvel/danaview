// OWNER: AI-12
//
// The planner (ARCH §16.4 step 1, ai.md §8.2): turns a scope plus a timeline view into units.
//
// Included: audible media clips. Excluded: muted clips, clips with volume 0 and clips on muted or
// soloed-out tracks (all `muted`, reported), reversed clips (`reversed`, reported), media without
// an audio stream (`noAudio`, reported), freeze frames and images (silent), and, by default,
// tracks with role `music`. Clips of the same media and stream whose source ranges overlap or lie
// within 5 s of each other merge into one unit (a split clip becomes one transcription); each unit
// is padded by 0.5 s on both sides and clamped to the media.

import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart';

import '../contracts/timeline_view.dart';
import '../contracts/transcription_service.dart';
import 'transcription_unit.dart';

/// What the planner needs to know about a media asset beyond [AudibleClipView].
@immutable
final class MediaAudioInfo {
  /// Creates the record.
  const MediaAudioInfo({required this.hasAudio, this.duration, this.isStill = false});

  /// Whether the asset has an audio stream (media pool probe).
  final bool hasAudio;

  /// Media duration, used to clamp padded ranges; null = unknown.
  final TimeUs? duration;

  /// Images and freeze-frame stills.
  final bool isStill;
}

/// Source of [MediaAudioInfo], usually the project's media pool (implemented by
/// `DomainTimelineView`).
abstract interface class TimelineMediaInfo {
  /// The info of [media], or null when it is not in the pool.
  MediaAudioInfo? audioInfo(MediaId media);
}

/// Plans transcription units.
final class TranscriptionPlanner {
  /// Creates a planner; the defaults are the ai.md values.
  const TranscriptionPlanner({
    this.mergeGap = const Duration(seconds: 5),
    this.pad = const Duration(milliseconds: 500),
  });

  /// Clips of the same media within this source distance merge into one unit.
  final Duration mergeGap;

  /// Padding on both sides of a unit so edge words are complete.
  final Duration pad;

  /// The [StreamPriority] of [track].
  static int priorityOf(TrackView track) {
    switch (track.kind) {
      case TrackKind.audio:
        return switch (track.role) {
          AudioRole.voice => StreamPriority.voice,
          AudioRole.music => StreamPriority.music,
          _ => StreamPriority.otherAudio,
        };
      case TrackKind.video:
        return track.isMain ? StreamPriority.mainVideo : StreamPriority.otherVideo;
      case TrackKind.overlay:
      case TrackKind.text:
      case TrackKind.subtitle:
        return StreamPriority.otherVideo;
    }
  }

  /// Plans [scope] on [view]. [media] supplies pool facts; it defaults to [view] when that
  /// implements [TimelineMediaInfo].
  TranscriptionPlan plan(TimelineView view, TranscriptionScope scope, {TimelineMediaInfo? media}) {
    final info = media ?? (view is TimelineMediaInfo ? view as TimelineMediaInfo : null);
    final tracks = <TrackId, TrackView>{};
    final ranks = <TrackId, int>{};
    var index = 0;
    for (final t in view.tracks) {
      tracks[t.id] = t;
      ranks[t.id] = t.kind == TrackKind.audio ? -index : index;
      index++;
    }

    final skipped = <SkippedClip>[];
    final candidates = <_Candidate>[];
    for (final clip in view.audibleClips()) {
      final track = tracks[clip.track];
      if (track == null) continue;
      final window = _inScope(scope, clip, track);
      if (window == null) continue;
      if (clip.isFreeze) continue;
      final mediaInfo = info?.audioInfo(clip.media);
      if (mediaInfo != null && mediaInfo.isStill) continue;
      if (clip.effectiveVolume <= 0) {
        skipped.add(SkippedClip(clip.id, 'muted'));
        continue;
      }
      if (clip.reversed) {
        skipped.add(SkippedClip(clip.id, 'reversed'));
        continue;
      }
      if (mediaInfo != null && !mediaInfo.hasAudio) {
        skipped.add(SkippedClip(clip.id, 'noAudio'));
        continue;
      }
      final source = window.isFull ? clip.sourceRange : _sourceRangeWithin(clip, window.range!);
      if (source == null || source.isEmpty) continue;
      candidates.add(_Candidate(clip, source, priorityOf(track), ranks[track.id]!, mediaInfo?.duration));
    }

    // Group by media and stream, merge near ranges.
    final groups = <(MediaId, int), List<_Candidate>>{};
    final order = <(MediaId, int)>[];
    for (final c in candidates) {
      final key = (c.clip.media, c.clip.audioStream ?? 0);
      final list = groups[key];
      if (list == null) {
        groups[key] = [c];
        order.add(key);
      } else {
        list.add(c);
      }
    }

    final units = <TranscriptionUnit>[];
    for (final key in order) {
      final list = groups[key]!..sort((a, b) => a.source.start != b.source.start ? a.source.start.compareTo(b.source.start) : a.clip.id.value.compareTo(b.clip.id.value));
      var cluster = <_Candidate>[list.first];
      var clusterEnd = list.first.source.end;
      void flush() => units.add(_unit(cluster));
      for (final c in list.skip(1)) {
        if (c.source.start - clusterEnd <= mergeGap.inMicroseconds) {
          cluster.add(c);
          if (c.source.end > clusterEnd) clusterEnd = c.source.end;
        } else {
          flush();
          cluster = [c];
          clusterEnd = c.source.end;
        }
      }
      flush();
    }
    units.sort((a, b) {
      final c = a.clips.first.timelineRange.start.compareTo(b.clips.first.timelineRange.start);
      return c != 0 ? c : a.sourceRange.start.compareTo(b.sourceRange.start);
    });
    return TranscriptionPlan(units: units, skipped: skipped);
  }

  TranscriptionUnit _unit(List<_Candidate> cluster) {
    final first = cluster.first;
    var start = first.source.start;
    var end = first.source.end;
    var priority = first.priority;
    for (final c in cluster) {
      if (c.source.start < start) start = c.source.start;
      if (c.source.end > end) end = c.source.end;
      if (c.priority > priority) priority = c.priority;
    }
    final padUs = pad.inMicroseconds;
    var pStart = start - padUs;
    if (pStart < 0) pStart = 0;
    var pEnd = end + padUs;
    final duration = cluster.map((c) => c.mediaDuration).whereType<TimeUs>().fold<TimeUs?>(null, (a, b) => a == null || b > a ? b : a);
    if (duration != null && pEnd > duration) pEnd = duration;
    if (pEnd < end) pEnd = end; // never trim real clip content
    if (pStart > start) pStart = start;
    final clips = [
      for (final c in cluster)
        UnitClip(
          id: c.clip.id,
          track: c.clip.track,
          timelineRange: c.clip.timelineRange,
          sourceRange: c.source,
          priority: c.priority,
          trackRank: c.rank,
        ),
    ]..sort((a, b) => a.timelineRange.start.compareTo(b.timelineRange.start));
    return TranscriptionUnit(
      media: first.clip.media,
      mediaQuickHash: first.clip.mediaQuickHash,
      audioStream: first.clip.audioStream,
      sourceRange: TimeRange(pStart, pEnd),
      coreRange: TimeRange(start, end),
      clips: clips,
      priority: priority,
    );
  }

  // -------------------------------------------------------------------------------------------
  // Scope.
  // -------------------------------------------------------------------------------------------

  /// Null when the clip is out of scope; otherwise the window it is cut to (full = whole clip).
  _Window? _inScope(TranscriptionScope scope, AudibleClipView clip, TrackView track) {
    switch (scope) {
      case ClipScope(:final item):
        return clip.id == item ? const _Window.full() : null;
      case ItemsScope(:final items):
        return items.contains(clip.id) ? const _Window.full() : null;
      case TimelineScope(:final tracks, :final range):
        if (tracks == null) {
          if (track.kind == TrackKind.audio && track.role == AudioRole.music) return null; // unchecked by default
        } else if (!tracks.contains(track.id)) {
          return null;
        }
        if (range == null) return const _Window.full();
        final visible = clip.timelineRange.intersect(range);
        if (visible == null) return null;
        return visible == clip.timelineRange ? const _Window.full() : _Window(visible);
    }
  }

  /// The part of [clip]'s source that is shown during timeline [window] (binary search through
  /// [AudibleClipView.timelineTimeOf], which is increasing for the non-reversed clips planned).
  TimeRange? _sourceRangeWithin(AudibleClipView clip, TimeRange window) {
    final src = clip.sourceRange;
    TimeUs firstSourceAtOrAfter(TimeUs t) {
      // Smallest source time in [src.start, src.end] whose timeline time is >= t.
      var lo = src.start;
      var hi = src.end;
      while (lo < hi) {
        final mid = lo + ((hi - lo) >> 1);
        final at = clip.timelineTimeOf(mid);
        if (at != null && at >= t) {
          hi = mid;
        } else {
          lo = mid + 1;
        }
      }
      return lo;
    }

    final s0 = window.start <= clip.timelineRange.start ? src.start : firstSourceAtOrAfter(window.start);
    final s1 = window.end >= clip.timelineRange.end ? src.end : firstSourceAtOrAfter(window.end);
    if (s1 <= s0) return null;
    return TimeRange(s0, s1);
  }
}

final class _Window {
  const _Window.full()
      : range = null,
        isFull = true;
  const _Window(TimeRange this.range) : isFull = false;
  final TimeRange? range;
  final bool isFull;
}

final class _Candidate {
  const _Candidate(this.clip, this.source, this.priority, this.rank, this.mediaDuration);
  final AudibleClipView clip;
  final TimeRange source;
  final int priority;
  final int rank;
  final TimeUs? mediaDuration;
}
