// OWNER: AI-12
//
// Mapping source words onto the timeline (ARCH §16.4 step 7, ai.md §10.1) on a FRESH timeline view
// (so edits made during a job are honoured), then merging overlapping speech by priority.
//
// * Each word is mapped through `AudibleClipView.timelineTimeOf` (`ClipTimeMap.timelineTimeOf`:
//   exact for constant speeds and ramps).
// * A word whose visible part is less than 50% of its duration is dropped; a partly visible word
//   is clamped to the clip's timeline range.
// * Words from different clips stay separate even when they are the same media (a split clip
//   yields two streams); only the cue segmenter joins them, with the cut-crossing penalty.
// * Where two audible clips overlap on the timeline, words of the lower-priority clip within
//   +-0.3 s of a kept higher-priority word are dropped. Priority: voice > main video > other
//   video > other audio > music; ties go to the higher track.

import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart';

import '../contracts/timeline_view.dart';
import '../segmentation/timed_word.dart';
import '../transcript/transcript_models.dart';
import 'transcription_planner.dart';
import 'transcription_unit.dart';

/// The words of one unit's transcript (absolute source µs), normalized and filtered to the unit.
@immutable
final class UnitWords {
  /// Creates the pair.
  const UnitWords(this.unit, this.words);

  /// Builds the pair from a transcript, taking the words of its segments.
  factory UnitWords.fromTranscript(TranscriptionUnit unit, TranscriptFile transcript) => UnitWords(unit, [
        for (final s in transcript.segments) ...s.words,
      ]);

  /// The unit.
  final TranscriptionUnit unit;

  /// Words in source µs, sorted.
  final List<TranscriptWord> words;
}

/// One clip's words on the timeline, with what the merge needs to rank it.
@immutable
final class ClipStream {
  /// Creates a stream.
  const ClipStream({required this.clip, required this.timelineRange, required this.priority, required this.trackRank, required this.words});

  /// Clip id.
  final ItemId clip;

  /// The clip's timeline range.
  final TimeRange timelineRange;

  /// [StreamPriority].
  final int priority;

  /// Tie-break rank (higher wins).
  final int trackRank;

  /// The clip's words on the timeline, sorted by start.
  final List<TimedWord> words;
}

/// The result of mapping.
@immutable
final class MappedWords {
  /// Creates the result.
  MappedWords({
    required List<TimedWord> words,
    required List<TimeUs> cutPoints,
    this.droppedInvisible = 0,
    this.droppedOverlap = 0,
    List<ItemId> missingClips = const [],
  })  : words = List.unmodifiable(words),
        cutPoints = List.unmodifiable(cutPoints),
        missingClips = List.unmodifiable(missingClips);

  /// One time-sorted word stream on the timeline.
  final List<TimedWord> words;

  /// Clip boundaries for the segmenter, sorted and unique.
  final List<TimeUs> cutPoints;

  /// Words dropped because less than 50% of them were visible.
  final int droppedInvisible;

  /// Words dropped because a higher-priority clip covered them.
  final int droppedOverlap;

  /// Planned clips that no longer exist, changed media or became inaudible since the plan.
  final List<ItemId> missingClips;
}

/// Maps and merges words.
final class WordMapper {
  /// Creates a mapper; the defaults are the ai.md values.
  const WordMapper({this.minVisibleFraction = 0.5, this.overlapWindow = const Duration(milliseconds: 300)});

  /// A word whose visible share is below this is dropped.
  final double minVisibleFraction;

  /// Lower-priority words this close to a kept word, inside an overlap, are dropped.
  final Duration overlapWindow;

  /// Maps [transcripts] through [timeline] (a fresh view). [window] limits the result to a
  /// timeline range (the scope's range): words are clamped to it with the same 50% rule.
  MappedWords map({
    required TimelineView timeline,
    required Iterable<UnitWords> transcripts,
    TimeRange? window,
  }) {
    final tracks = <TrackId, TrackView>{};
    final ranks = <TrackId, int>{};
    var index = 0;
    for (final t in timeline.tracks) {
      tracks[t.id] = t;
      ranks[t.id] = t.kind == TrackKind.audio ? -index : index;
      index++;
    }
    final clips = <ItemId, AudibleClipView>{for (final c in timeline.audibleClips()) c.id: c};

    var droppedInvisible = 0;
    final missing = <ItemId>[];
    final streamWords = <ItemId, List<TimedWord>>{};
    final streamMeta = <ItemId, (AudibleClipView, TrackView)>{};
    final order = <ItemId>[];
    final seen = <ItemId>{};
    for (final uw in transcripts) {
      final valid = <AudibleClipView>[];
      for (final planned in uw.unit.clips) {
        final clip = clips[planned.id];
        final track = clip == null ? null : tracks[clip.track];
        if (clip == null ||
            track == null ||
            clip.media != uw.unit.media ||
            (clip.audioStream ?? 0) != uw.unit.audioStreamIndex ||
            clip.reversed ||
            clip.isFreeze ||
            clip.effectiveVolume <= 0) {
          missing.add(planned.id);
          continue;
        }
        if (!seen.add(clip.id)) continue; // a clip belongs to one unit
        valid.add(clip);
        streamWords[clip.id] = [];
        streamMeta[clip.id] = (clip, track);
        order.add(clip.id);
      }
      valid.sort((a, b) => a.timelineRange.start.compareTo(b.timelineRange.start));
      for (final w in uw.words) {
        final candidates = <(AudibleClipView, TimedWord, double)>[];
        for (final clip in valid) {
          final m = _mapWord(clip, w, window);
          if (m != null) {
            candidates.add((clip, m.$1, m.$2));
          } else if (_overlapsSource(clip, w)) {
            droppedInvisible++;
          }
        }
        if (candidates.isEmpty) continue;
        // A word cut by a split is visible in two clips, each showing a part: it belongs to the one
        // that shows most of it (the earlier clip on a tie), so it is not captioned twice. A word
        // that some clip shows in full (a repeated or overlapping range) stays in every clip.
        final full = candidates.any((c) => c.$3 >= 1 - 1e-9);
        if (full || candidates.length == 1) {
          for (final c in candidates) {
            streamWords[c.$1.id]!.add(c.$2);
          }
        } else {
          var best = candidates.first;
          for (final c in candidates.skip(1)) {
            if (c.$3 > best.$3 + 1e-9) best = c;
          }
          streamWords[best.$1.id]!.add(best.$2);
          droppedInvisible += candidates.length - 1;
        }
      }
    }
    final streams = <ClipStream>[];
    for (final id in order) {
      final (clip, track) = streamMeta[id]!;
      final mapped = streamWords[id]!..sort((a, b) => a.start != b.start ? a.start.compareTo(b.start) : a.end.compareTo(b.end));
      streams.add(ClipStream(
        clip: id,
        timelineRange: clip.timelineRange,
        priority: TranscriptionPlanner.priorityOf(track),
        trackRank: ranks[track.id]!,
        words: mapped,
      ));
    }

    final merged = mergeStreams(streams, window: overlapWindow);
    final before = streams.fold<int>(0, (n, s) => n + s.words.length);

    final cuts = <TimeUs>{
      for (final c in timeline.cutPoints)
        if (window == null || (c > window.start && c < window.end)) c,
    }.toList()
      ..sort();

    return MappedWords(
      words: merged,
      cutPoints: cuts,
      droppedInvisible: droppedInvisible,
      droppedOverlap: before - merged.length,
      missingClips: missing,
    );
  }

  bool _overlapsSource(AudibleClipView clip, TranscriptWord w) => w.endUs > clip.sourceRange.start && w.startUs < clip.sourceRange.end;

  /// Maps one source word through [clip], or null when less than [minVisibleFraction] of it is
  /// visible (trimmed away, or outside [window]). A partly visible word is clamped to the clip's
  /// (and the window's) timeline range.
  TimedWord? mapWord(AudibleClipView clip, TranscriptWord w, {TimeRange? window}) => _mapWord(clip, w, window)?.$1;

  /// The mapped word and its visible share (0..1, the smaller of the source and window shares).
  (TimedWord, double)? _mapWord(AudibleClipView clip, TranscriptWord w, TimeRange? window) {
    final src = clip.sourceRange;
    final s0 = w.startUs;
    final s1 = w.endUs < w.startUs ? w.startUs : w.endUs;
    final dur = s1 - s0;

    // Visible share in source terms.
    var share = 1.0;
    if (dur <= 0) {
      if (s0 < src.start || s0 >= src.end) return null;
    } else {
      final vs = s0 > src.start ? s0 : src.start;
      final ve = s1 < src.end ? s1 : src.end;
      if (ve <= vs) return null;
      share = (ve - vs) / dur;
      if (share < minVisibleFraction) return null;
    }

    final clipRange = clip.timelineRange;
    final TimeUs t0 = s0 < src.start ? clipRange.start : (clip.timelineTimeOf(s0) ?? clipRange.start);
    final TimeUs t1 = s1 >= src.end ? clipRange.end : (clip.timelineTimeOf(s1) ?? clipRange.end);
    var start = t0 < clipRange.start ? clipRange.start : t0;
    var end = t1 > clipRange.end ? clipRange.end : t1;
    if (end < start) end = start;

    if (window != null) {
      final full = end - start;
      if (full <= 0) {
        if (start < window.start || start >= window.end) return null;
      } else {
        final vis = (end < window.end ? end : window.end) - (start > window.start ? start : window.start);
        if (vis <= 0 || vis < full * minVisibleFraction) return null;
        final windowShare = vis / full;
        if (windowShare < share) share = windowShare;
      }
      if (start < window.start) start = window.start;
      if (end > window.end) end = window.end;
      if (end < start) end = start;
    }
    return (TimedWord(text: w.text, start: start, end: end, p: w.probability, clip: clip.id), share);
  }

  /// Merges per-clip streams into one time-sorted stream: inside an overlap of two clips, words of
  /// the lower-priority clip within [window] of a kept word of a higher-priority one are dropped.
  /// Pure and deterministic; ties in priority go to the higher `trackRank`, then the smaller id.
  static List<TimedWord> mergeStreams(List<ClipStream> streams, {Duration window = const Duration(milliseconds: 300)}) {
    final ordered = [...streams]..sort((a, b) {
        var c = b.priority.compareTo(a.priority);
        if (c != 0) return c;
        c = b.trackRank.compareTo(a.trackRank);
        if (c != 0) return c;
        return a.clip.value.compareTo(b.clip.value);
      });
    final win = window.inMicroseconds;
    final out = <TimedWord>[];
    final kept = <(TimedWord, ClipStream)>[]; // sorted by word start
    var maxKeptDuration = 0;
    for (final s in ordered) {
      final survivors = <(TimedWord, ClipStream)>[];
      for (final w in s.words) {
        if (!_shadowed(w, s, kept, win, maxKeptDuration)) survivors.add((w, s));
      }
      for (final e in survivors) {
        out.add(e.$1);
        final d = e.$1.end - e.$1.start;
        if (d > maxKeptDuration) maxKeptDuration = d;
      }
      if (survivors.isNotEmpty) {
        kept
          ..addAll(survivors)
          ..sort((a, b) => a.$1.start.compareTo(b.$1.start));
      }
    }
    // Stable by start, then end; the order of `out` (priority order) breaks exact ties.
    final indexed = [for (var i = 0; i < out.length; i++) (i, out[i])]..sort((a, b) {
        var c = a.$2.start.compareTo(b.$2.start);
        if (c != 0) return c;
        c = a.$2.end.compareTo(b.$2.end);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    return [for (final e in indexed) e.$2];
  }

  static bool _shadowed(TimedWord w, ClipStream stream, List<(TimedWord, ClipStream)> kept, int win, int maxKeptDuration) {
    if (kept.isEmpty) return false;
    // First kept word that could be within the window: start >= w.start - win - maxKeptDuration.
    final floor = w.start - win - maxKeptDuration;
    var lo = 0;
    var hi = kept.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (kept[mid].$1.start < floor) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    for (var i = lo; i < kept.length; i++) {
      final (k, ks) = kept[i];
      if (k.start > w.end + win) break;
      if (ks.clip == stream.clip) continue;
      if (!(k.start < w.end + win && k.end > w.start - win)) continue;
      // Only inside the overlap of the two clips.
      final overlap = ks.timelineRange.intersect(stream.timelineRange);
      if (overlap == null) continue;
      if ((w.end > overlap.start && w.start < overlap.end) || (w.end == w.start && overlap.contains(w.start))) return true;
    }
    return false;
  }
}
