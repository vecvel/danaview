// OWNER: CORE-15
//
// Subtitle commands (ARCH §7.2, domain.md §4.9 and §6.7, ai.md §10.2; schema 1): `AddCue`,
// `SetCueText`, `SetCueRange`, `SplitCue`, `MergeCues`, `DeleteCues`, `ShiftCues`,
// `ImportSubtitles`, `SetSubtitleStyle`, `SetSubtitlePosition`, `SetBurnIn`,
// `SetSubtitleLanguage`. The two AI commands live in caption_commands.dart.
//
// Rules shared by all of them:
// * cues are items of subtitle lanes: sorted, never overlapping, on the frame grid, at least one
//   frame long, with text that is non-empty after trimming (`EmptyText`); text uses `\n` between
//   lines and only the inline markup `<i>` / `<b>` (balanced; splits close and reopen tags);
// * locked lanes refuse (`TrackLocked`), lanes of another kind are `IncompatibleTrack`, cue ids
//   that are not cues are `UnsupportedForKind`;
// * every text or timing change of a `CueOrigin.generated` cue sets `editedAfterGeneration`
//   (ai.md §10.2 rule 2); style, position, burn-in and language changes do not;
// * inputs are quantized to the grid: starts and ends to the nearest frame, deltas to whole
//   frames; split times down to the frame start;
// * each command is one history entry.
//
// Coalescing is the session's: the UI passes `SetCueText.coalesceKey(id)` for typing.

part of '../edit_command.dart';

/// Stable notice codes of the subtitle and caption commands (UX maps them to copy).
abstract final class SubtitleNoticeCodes {
  /// `ShiftCues` stopped at the project start: the shift is smaller than asked
  /// ([EditNotice.count] frames applied).
  static const String shiftClampedAtZero = 'shiftClampedAtZero';

  /// Overlapping imported cues went to extra subtitle lanes ([EditNotice.count] cues).
  static const String cuesSpilled = 'cuesSpilled';

  /// Cues were left out because their text was empty or they had no room
  /// ([EditNotice.count] cues).
  static const String cuesSkipped = 'cuesSkipped';
}

// -------------------------------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------------------------------

final RegExp _markupTag = RegExp(r'</?[ibIB]>');

/// The text of [s] without inline markup.
String _visibleText(String s) => s.replaceAll(_markupTag, '');

/// Line endings normalized to `\n`.
String _lineBreaks(String s) => s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

/// Cue text from an outside source: line endings normalized, every line trimmed, blank lines
/// dropped (the SRT/VTT codec's rule too).
String _cleanCueText(String s) => [
      for (final line in _lineBreaks(s).split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ].join('\n');

/// Whether [s] has no visible text.
bool _blank(String s) => _visibleText(s).trim().isEmpty;

/// The subtitle lane [id], unlocked.
Track _subtitleLane(_Draft d, TrackId id) {
  final t = d.editableTrack(id);
  if (t.kind != TrackKind.subtitle) d.reject(IncompatibleTrack(id));
  return t;
}

/// The cue [id] with its lane, refusing non-cues and locked lanes.
({Track track, int index, SubtitleCue cue}) _cueOf(_Draft d, ItemId id) {
  final loc = d.locate(id);
  final item = loc.item;
  if (item is! SubtitleCue) d.reject(UnsupportedForKind(item is TextItem ? 'text' : 'clip'));
  if (loc.track.locked) d.reject(TrackLocked(loc.track.id));
  return (track: loc.track, index: loc.itemIndex, cue: item);
}

/// [cue] marked as edited when it was generated.
SubtitleCue _edited(SubtitleCue cue) =>
    cue.origin == CueOrigin.generated && !cue.editedAfterGeneration ? cue.copyWith(editedAfterGeneration: true) : cue;

/// A cue of [text] on frames `[k0, k1)`.
SubtitleCue _newCue(_Draft d, int k0, int k1, String text, {required CueOrigin origin}) => SubtitleCue(
      id: d.ids.itemId(),
      start: d.timeOf(k0),
      duration: d.timeOf(k1) - d.timeOf(k0),
      text: text,
      origin: origin,
    );

/// A cue proposal on the project grid: frames `[k0, k1)` (k1 > k0 ≥ 0) and normalized text.
typedef _GridCue = ({int k0, int k1, String text});

/// [drafts] on the grid, sorted by start: starts and ends to the nearest frame (start ≥ 0, at least
/// one frame long), text trimmed with `\n` line breaks. Cues with blank text are counted in
/// [skipped] and left out.
List<_GridCue> _gridCues(_Draft d, List<SubtitleCueDraft> drafts, void Function() skipped) {
  final out = <_GridCue>[];
  for (final draft in drafts) {
    final text = _cleanCueText(draft.text);
    if (_blank(text)) {
      skipped();
      continue;
    }
    var k0 = d.rate.frameIndexNearest(draft.range.start);
    if (k0 < 0) k0 = 0;
    var k1 = d.rate.frameIndexNearest(draft.range.end);
    if (k1 <= k0) k1 = k0 + 1;
    out.add((k0: k0, k1: k1, text: text));
  }
  // A stable sort by start (then end).
  final indexed = [for (var i = 0; i < out.length; i++) (i, out[i])];
  indexed.sort((a, b) {
    final c = a.$2.k0.compareTo(b.$2.k0);
    if (c != 0) return c;
    final e = a.$2.k1.compareTo(b.$2.k1);
    return e != 0 ? e : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// Fits [cues] (sorted) into the free space between each other and the immovable [fixed] cues
/// (sorted): a cue starts at the end of what precedes it and stops where the next fixed cue
/// begins; cues left with no frame are dropped (counted in [dropped]).
List<_GridCue> _fitCues(_Draft d, List<_GridCue> cues, List<TimelineItem> fixed, void Function() dropped) {
  final out = <_GridCue>[];
  var prevEnd = 0;
  var j = 0;
  int startOf(TimelineItem i) => d.frameOf(i.start);
  int endOf(TimelineItem i) => d.frameOf(i.end);
  for (final c in cues) {
    var k0 = c.k0 < prevEnd ? prevEnd : c.k0;
    var k1 = c.k1;
    var again = true;
    while (again) {
      again = false;
      while (j < fixed.length && endOf(fixed[j]) <= k0) {
        j++;
      }
      if (j < fixed.length && startOf(fixed[j]) <= k0) {
        k0 = endOf(fixed[j]);
        again = true;
      }
    }
    if (j < fixed.length && startOf(fixed[j]) < k1) k1 = startOf(fixed[j]);
    if (k1 - k0 < 1) {
      dropped();
      continue;
    }
    out.add((k0: k0, k1: k1, text: c.text));
    prevEnd = k1;
  }
  return out;
}

// -------------------------------------------------------------------------------------------
// Text splitting and joining
// -------------------------------------------------------------------------------------------

/// A piece of cue text: an inline tag or one grapheme cluster, at a UTF-16 [offset].
typedef _Tok = ({String text, bool tag, int offset});

List<_Tok> _tokens(String s) {
  final out = <_Tok>[];
  var pos = 0;
  void graphemes(String segment) {
    for (final g in segment.characters) {
      out.add((text: g, tag: false, offset: pos));
      pos += g.length;
    }
  }

  var last = 0;
  for (final m in _markupTag.allMatches(s)) {
    if (m.start > last) graphemes(s.substring(last, m.start));
    out.add((text: m[0]!, tag: true, offset: pos));
    pos += m[0]!.length;
    last = m.end;
  }
  if (last < s.length) graphemes(s.substring(last));
  return out;
}

bool _isSpace(String grapheme) => grapheme.trim().isEmpty;

/// Splits [text] in two: at the token boundary nearest [utf16Index] when given, else at the word
/// boundary nearest the middle (whitespace between words is dropped; without any, the middle
/// grapheme). Returns null when a half has no visible text. Inline tags are closed in the left
/// half and reopened in the right.
(String, String)? _splitCueText(String text, int? utf16Index) {
  final toks = _tokens(text);
  int? cut; // boundary: left = toks[0, cut), right = toks[cut ..]
  var dropSpace = false;
  if (utf16Index != null) {
    var bestDelta = 1 << 40;
    for (var i = 1; i < toks.length; i++) {
      final delta = (toks[i].offset - utf16Index).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        cut = i;
      }
    }
  } else {
    var visible = 0;
    for (final t in toks) {
      if (!t.tag) visible++;
    }
    final mid = visible / 2;
    var seen = 0;
    var best = 1 << 40;
    double bestDist = double.infinity;
    for (var i = 0; i < toks.length; i++) {
      final t = toks[i];
      if (t.tag) continue;
      if (_isSpace(t.text)) {
        final dist = (seen - mid).abs();
        if (dist < bestDist) {
          bestDist = dist;
          best = i;
        }
      }
      seen++;
    }
    if (best != 1 << 40) {
      cut = best;
      dropSpace = true;
    } else if (visible >= 2) {
      // No whitespace (one word, CJK): the middle grapheme.
      final want = visible ~/ 2;
      var count = 0;
      for (var i = 0; i < toks.length; i++) {
        if (toks[i].tag) continue;
        if (count == want) {
          cut = i;
          break;
        }
        count++;
      }
    }
  }
  if (cut == null) return null;
  var left = toks.take(cut).map((t) => t.text).join();
  var right = toks.skip(dropSpace ? cut + 1 : cut).map((t) => t.text).join();
  left = left.trimRight();
  right = right.trimLeft();
  // Balance the inline tags the cut opened or closed.
  final open = <String>[];
  for (final m in _markupTag.allMatches(left)) {
    final tag = m[0]!.toLowerCase();
    final name = tag[tag.length - 2];
    if (tag.startsWith('</')) {
      final at = open.lastIndexOf(name);
      if (at >= 0) open.removeAt(at);
    } else {
      open.add(name);
    }
  }
  if (open.isNotEmpty) {
    left = left + open.reversed.map((n) => '</$n>').join();
    right = open.map((n) => '<$n>').join() + right;
  }
  if (_blank(left) || _blank(right)) return null;
  return (left, right);
}

/// How the texts of merged cues are joined (domain.md §6.7): with a space when the result has at
/// most 42 graphemes and no line break, else with `\n`.
String _joinCueTexts(List<String> texts) {
  final parts = [for (final t in texts) t.trim()];
  final spaced = parts.join(' ');
  if (!spaced.contains('\n') && _visibleText(spaced).characters.length <= 42) return spaced;
  return parts.join('\n');
}

// -------------------------------------------------------------------------------------------
// AddCue
// -------------------------------------------------------------------------------------------

/// Adds a cue of [text] at [at] on a subtitle lane (domain.md §6.7): into the free space at [at],
/// [duration] long (default `EditPolicy.defaultCueUs`, 2 s) and shortened to fit before the next
/// cue (at least one frame). [at] is quantized to the nearest frame.
///
/// [track] null picks the topmost unlocked subtitle lane with room at [at]; when none has, the
/// policy decides: a new subtitle lane (`OverlapPolicy.newLane`) or `NoRoom`. An explicit lane
/// with no room at [at] (a cue is there, or the next one starts at [at]) is `NoRoom`.
///
/// Rejections: `EmptyText`, `InvalidValue` (`at`, `duration`), `ItemNotFound`, `TrackLocked`,
/// `IncompatibleTrack`, `NoRoom`.
final class AddCue extends EditCommand {
  /// Creates the command.
  const AddCue(this.at, this.text, {this.track, this.duration});

  /// Start (quantized to the nearest frame, ≥ 0).
  final TimeUs at;

  /// Cue text.
  final String text;

  /// The lane, or null for the topmost unlocked subtitle lane with room.
  final TrackId? track;

  /// Requested length (null: the policy default).
  final TimeUs? duration;

  @override
  String get label => 'Add caption';

  @override
  void _apply(_Draft d) {
    final clean = _cleanCueText(text);
    if (_blank(clean)) d.reject(const EmptyText());
    if (at < 0) d.reject(const InvalidValue('at'));
    final wanted = duration ?? d.policy.defaultCueUs;
    if (wanted <= 0) d.reject(const InvalidValue('duration'));
    final k0 = d.rate.frameIndexNearest(at);
    final n = d.lengthFrames(wanted);

    /// The frames available at [k0] on [lane] (0 when taken).
    int room(Track lane) {
      var free = n;
      for (final c in lane.items) {
        final s = d.frameOf(c.start);
        final e = d.frameOf(c.end);
        if (e <= k0) continue;
        if (s <= k0) return 0;
        if (s - k0 < free) free = s - k0;
        break;
      }
      return free;
    }

    TrackId laneId;
    int frames;
    final explicit = track;
    if (explicit != null) {
      final lane = _subtitleLane(d, explicit);
      frames = room(lane);
      if (frames < 1) d.reject(const NoRoom());
      laneId = lane.id;
    } else {
      Track? found;
      var foundFrames = 0;
      for (final t in d.tracks.reversed) {
        if (t.kind != TrackKind.subtitle || t.locked) continue;
        final r = room(t);
        if (r >= 1) {
          found = t;
          foundFrames = r;
          break;
        }
      }
      if (found != null) {
        laneId = found.id;
        frames = foundFrames;
      } else {
        if (d.policy.overlap == OverlapPolicy.reject && d.tracks.any((t) => t.kind == TrackKind.subtitle)) {
          d.reject(const NoRoom());
        }
        laneId = d.createTrack(TrackKind.subtitle);
        frames = n;
      }
    }
    final cue = _newCue(d, k0, k0 + frames, clean, origin: CueOrigin.manual);
    d.addItems(laneId, [cue]);
    d.selection = SelectionHint({cue.id}, primary: cue.id, lane: laneId);
  }

  @override
  String toString() => 'AddCue($at, track: $track, duration: $duration)';
}

// -------------------------------------------------------------------------------------------
// SetCueText
// -------------------------------------------------------------------------------------------

/// Sets the text of a cue (`\n` line breaks, inline `<i>`/`<b>` kept as given). Sets
/// `editedAfterGeneration` on generated cues. Setting the same text is a no-op.
///
/// Rejections: `ItemNotFound`, `UnsupportedForKind` (not a cue), `TrackLocked`, `EmptyText`
/// (blank after trimming; the UI offers Delete instead).
final class SetCueText extends EditCommand {
  /// Creates the command.
  const SetCueText(this.cue, this.text);

  /// The coalescing key for typing into a cue: pass it to `EditSession.apply` (CORE-19).
  static String coalesceKey(ItemId cue) => 'cue:$cue';

  /// The cue.
  final ItemId cue;

  /// The new text.
  final String text;

  @override
  String get label => 'Edit caption';

  @override
  void _apply(_Draft d) {
    final loc = _cueOf(d, cue);
    final clean = _lineBreaks(text);
    if (_blank(clean)) d.reject(const EmptyText());
    if (clean == loc.cue.text) return;
    d.replaceItems([_edited(loc.cue.copyWith(text: clean))]);
  }

  @override
  String toString() => 'SetCueText($cue)';
}

// -------------------------------------------------------------------------------------------
// SetCueRange
// -------------------------------------------------------------------------------------------

/// Sets a cue's start and end (nearest frames), never overlapping its neighbours and at least one
/// frame long. Sets `editedAfterGeneration` on generated cues.
///
/// Without [clamp] the first violated rule is the rejection: `InvalidValue('start')` (before 0),
/// `BelowMinDuration`, `WouldOverlap(track, range)`. With [clamp] the nearest valid result is
/// used and reported as `EditPreview.clampedTo`: an edge stops at 0 and at the neighbouring cue,
/// and the edge that moved never crosses the one that did not (it stops one frame short of it);
/// when both edges move and cross, the end becomes one frame after the start.
final class SetCueRange extends EditCommand {
  /// Creates the command.
  const SetCueRange(this.cue, this.start, this.end, {this.clamp = false});

  /// The cue.
  final ItemId cue;

  /// New start.
  final TimeUs start;

  /// New end.
  final TimeUs end;

  /// Whether to clamp instead of refusing.
  final bool clamp;

  @override
  String get label => 'Retime caption';

  @override
  void _apply(_Draft d) {
    final loc = _cueOf(d, cue);
    final lane = loc.track;
    final items = lane.items;
    final i = loc.index;
    final oldK0 = d.frameOf(loc.cue.start);
    final oldK1 = d.frameOf(loc.cue.end);
    var k0 = d.rate.frameIndexNearest(start);
    var k1 = d.rate.frameIndexNearest(end);
    final requested = (k0, k1);
    if (k0 < 0) {
      if (!clamp) d.reject(const InvalidValue('start'));
      k0 = 0;
    }
    if (k1 <= k0) {
      if (!clamp) d.reject(const BelowMinDuration());
      if (k0 != oldK0 && k1 == oldK1) {
        k0 = k1 - 1;
      } else {
        k1 = k0 + 1;
      }
      if (k0 < 0) {
        k0 = 0;
        k1 = 1;
      }
    }
    final lo = i > 0 ? d.frameOf(items[i - 1].end) : 0;
    final hi = i + 1 < items.length ? d.frameOf(items[i + 1].start) : null;
    if (k0 < lo) {
      if (!clamp) d.reject(WouldOverlap(lane.id, TimeRange(d.timeOf(k0), items[i - 1].end)));
      k0 = lo;
    }
    if (hi != null && k1 > hi) {
      if (!clamp) d.reject(WouldOverlap(lane.id, TimeRange(items[i + 1].start, d.timeOf(k1))));
      k1 = hi;
    }
    if (k1 - k0 < 1) d.reject(const BelowMinDuration());
    if (k0 == oldK0 && k1 == oldK1) return;
    final moved = loc.cue.copyWith(start: d.timeOf(k0), duration: d.timeOf(k1) - d.timeOf(k0));
    d.replaceItems([_edited(moved)]);
    if (clamp && (k0, k1) != requested) d.clampedTo = moved.range;
  }

  @override
  String toString() => 'SetCueRange($cue, $start, $end, clamp: $clamp)';
}

// -------------------------------------------------------------------------------------------
// SplitCue
// -------------------------------------------------------------------------------------------

/// Splits a cue at [at] (floored to its frame start, strictly inside the cue). The left half
/// keeps the id. [textSplit] is a UTF-16 index into the text from the UI cursor (the nearest
/// boundary between graphemes and tags is used); without it the text splits at the word boundary
/// nearest the middle, by graphemes. Inline tags are closed and reopened across the cut; both
/// halves must have visible text. Both halves of a generated cue are marked edited.
///
/// Rejections: `ItemNotFound`, `UnsupportedForKind`, `TrackLocked`, `NothingAtTime(at)`,
/// `InvalidValue('textSplit')` (outside the text), `EmptyText` (a half would be empty).
final class SplitCue extends EditCommand {
  /// Creates the command.
  const SplitCue(this.cue, this.at, {this.textSplit});

  /// The cue.
  final ItemId cue;

  /// Split time.
  final TimeUs at;

  /// UTF-16 index of the text cut, or null.
  final int? textSplit;

  @override
  String get label => 'Split caption';

  @override
  void _apply(_Draft d) {
    final loc = _cueOf(d, cue);
    final k = d.frameOf(at);
    final k0 = d.frameOf(loc.cue.start);
    final k1 = d.frameOf(loc.cue.end);
    if (k <= k0 || k >= k1) d.reject(NothingAtTime(d.timeOf(k)));
    final idx = textSplit;
    final text = loc.cue.text;
    if (idx != null && (idx <= 0 || idx >= text.length)) d.reject(const InvalidValue('textSplit'));
    final halves = _splitCueText(text, idx);
    if (halves == null) d.reject(const EmptyText());
    final t = d.timeOf(k);
    final left = _edited(loc.cue.copyWith(duration: t - loc.cue.start, text: halves.$1));
    final right = _edited(SubtitleCue(
      id: d.ids.itemId(),
      start: t,
      duration: loc.cue.end - t,
      label: loc.cue.label,
      text: halves.$2,
      origin: loc.cue.origin,
      editedAfterGeneration: loc.cue.editedAfterGeneration,
    ));
    d.replaceItems([left]);
    d.addItems(loc.track.id, [right]);
    d.selection = SelectionHint({left.id, right.id}, primary: right.id, lane: loc.track.id);
  }

  @override
  String toString() => 'SplitCue($cue, $at, textSplit: $textSplit)';
}

// -------------------------------------------------------------------------------------------
// MergeCues
// -------------------------------------------------------------------------------------------

/// Merges consecutive cues of one lane into the first one (which keeps its id): the range is the
/// union (a gap between them is absorbed) and the texts are joined with a space when the result
/// has at most 42 graphemes and no line break, else with `\n`. A merge involving generated cues
/// marks a generated result as edited.
///
/// Rejections: `InvalidValue('cues')` (fewer than two), `ItemNotFound`, `UnsupportedForKind`,
/// `TrackLocked`, `NotAdjacent` (different lanes, or another cue lies between them).
final class MergeCues extends EditCommand {
  /// Creates the command.
  MergeCues(Set<ItemId> cues) : cues = Set.unmodifiable(cues);

  /// The cues to merge.
  final Set<ItemId> cues;

  @override
  String get label => 'Merge captions';

  @override
  void _apply(_Draft d) {
    if (cues.length < 2) d.reject(const InvalidValue('cues'));
    final located = [for (final id in cues) _cueOf(d, id)];
    final lane = located.first.track;
    if (located.any((l) => l.track.id != lane.id)) d.reject(const NotAdjacent());
    located.sort((a, b) => a.index.compareTo(b.index));
    for (var i = 1; i < located.length; i++) {
      if (located[i].index != located[i - 1].index + 1) d.reject(const NotAdjacent());
    }
    final first = located.first.cue;
    final last = located.last.cue;
    final merged = _edited(first.copyWith(
      duration: last.end - first.start,
      text: _joinCueTexts([for (final l in located) l.cue.text]),
    ));
    d.removeItems({for (final l in located.skip(1)) l.cue.id});
    d.replaceItems([merged]);
    d.selection = SelectionHint({merged.id}, primary: merged.id, lane: lane.id);
  }

  @override
  String toString() => 'MergeCues($cues)';
}

// -------------------------------------------------------------------------------------------
// DeleteCues
// -------------------------------------------------------------------------------------------

/// Deletes cues (no ripple: captions keep their times). No ids is a no-op.
///
/// Rejections: `ItemNotFound`, `UnsupportedForKind`, `TrackLocked`.
final class DeleteCues extends EditCommand {
  /// Creates the command.
  DeleteCues(Set<ItemId> cues) : cues = Set.unmodifiable(cues);

  /// The cues.
  final Set<ItemId> cues;

  @override
  String get label => cues.length == 1 ? 'Delete caption' : 'Delete captions';

  @override
  void _apply(_Draft d) {
    for (final id in cues) {
      _cueOf(d, id);
    }
    if (cues.isEmpty) return;
    d.removeItems(cues);
  }

  @override
  String toString() => 'DeleteCues($cues)';
}

// -------------------------------------------------------------------------------------------
// ShiftCues
// -------------------------------------------------------------------------------------------

/// Re-times the cues of a subtitle lane by [deltaUs] as one history entry: every cue of the lane,
/// or with [range] the cues that start inside it (`start ≥ range.start`, `start < range.end`).
/// The delta is quantized to whole frames (nearest, symmetric). A shift that would move the first
/// cue before 0 stops at 0 (notice `shiftClampedAtZero`, count = frames applied). Generated cues
/// are marked edited.
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `IncompatibleTrack`, `WouldOverlap(track, range)`
/// (a shifted cue would overlap a cue that is not shifted).
final class ShiftCues extends EditCommand {
  /// Creates the command.
  const ShiftCues(this.track, this.deltaUs, {this.range});

  /// The subtitle lane.
  final TrackId track;

  /// The shift (µs, quantized to frames).
  final TimeUs deltaUs;

  /// Only cues starting inside this range, or null for the whole lane.
  final TimeRange? range;

  @override
  String get label => 'Shift captions';

  @override
  void _apply(_Draft d) {
    final lane = _subtitleLane(d, track);
    var df = d.deltaFrames(deltaUs);
    if (df == 0) return;
    final r = range;
    final moving = <SubtitleCue>[];
    final still = <TimelineItem>[];
    for (final c in lane.items) {
      final inRange = r == null || (c.start >= r.start && c.start < r.end);
      if (inRange && c is SubtitleCue) {
        moving.add(c);
      } else {
        still.add(c);
      }
    }
    if (moving.isEmpty) return;
    final firstFrame = d.frameOf(moving.first.start);
    if (firstFrame + df < 0) {
      df = -firstFrame;
      d.notices.add(EditNotice(SubtitleNoticeCodes.shiftClampedAtZero, count: df.abs()));
      if (df == 0) return;
    }
    final shifted = [for (final c in moving) _edited(d.shiftFrames(c, df) as SubtitleCue)];
    // The shifted run must not touch the cues that stay.
    for (final s in shifted) {
      for (final o in still) {
        if (o.end <= s.start) continue;
        if (o.start >= s.end) break;
        d.reject(WouldOverlap(lane.id, s.range.intersect(o.range) ?? s.range));
      }
    }
    d.replaceItems(shifted);
  }

  @override
  String toString() => 'ShiftCues($track, $deltaUs, range: $range)';
}

// -------------------------------------------------------------------------------------------
// ImportSubtitles
// -------------------------------------------------------------------------------------------

/// Where `ImportSubtitles` puts the cues.
enum SubtitleImportMode {
  /// A new subtitle lane on top of the subtitle lanes.
  newTrack,

  /// Replace every cue of an existing lane (its style, position, burn-in and language stay; its
  /// caption provenance is cleared because the cues no longer come from the generator).
  replace,
}

/// Imports parsed subtitle cues (`SubtitleCodec.parse`, mapped to [SubtitleCueDraft]) as
/// `CueOrigin.imported` cues: starts and ends round to the nearest frame, every cue is at least
/// one frame long, blank cues are skipped (notice `cuesSkipped`). Overlapping cues spill onto
/// further subtitle lanes (first lane that is free, greedy by start) so nothing is lost (notice
/// `cuesSpilled`, count = cues that left the first lane); spill lanes copy the first lane's
/// language, style, position and burn-in and are named `<name> 2`, `<name> 3`, …
///
/// [mode] [SubtitleImportMode.newTrack] creates the lane ([name], [language]); [mode]
/// [SubtitleImportMode.replace] needs [track].
///
/// Rejections: `InvalidValue('cues')` (nothing to import), `InvalidValue('track')` (replace
/// without a lane), `ItemNotFound`, `TrackLocked`, `IncompatibleTrack`.
final class ImportSubtitles extends EditCommand {
  /// Creates the command.
  ImportSubtitles(List<SubtitleCueDraft> cues, {this.mode = SubtitleImportMode.newTrack, this.track, this.name = '', this.language})
      : cues = List.unmodifiable(cues);

  /// The cues (ranges need not be on the grid).
  final List<SubtitleCueDraft> cues;

  /// New lane or replace.
  final SubtitleImportMode mode;

  /// The lane to replace.
  final TrackId? track;

  /// Name of the new lane.
  final String name;

  /// Language tag of the new lane.
  final String? language;

  @override
  String get label => 'Import subtitles';

  @override
  void _apply(_Draft d) {
    Track? target;
    if (mode == SubtitleImportMode.replace) {
      final id = track;
      if (id == null) d.reject(const InvalidValue('track'));
      target = _subtitleLane(d, id);
    }
    var skipped = 0;
    final grid = _gridCues(d, cues, () => skipped++);
    if (grid.isEmpty) d.reject(const InvalidValue('cues'));

    // Greedy lane assignment by start.
    final laneEnds = <int>[];
    final lanes = <List<_GridCue>>[];
    for (final c in grid) {
      var l = laneEnds.indexWhere((e) => e <= c.k0);
      if (l < 0) {
        l = laneEnds.length;
        laneEnds.add(0);
        lanes.add([]);
      }
      laneEnds[l] = c.k1;
      lanes[l].add(c);
    }

    final data = target?.subtitle ?? SubtitleTrackData(language: language);
    final spillData = data.copyWith(provenance: null);
    final ids = <ItemId>[];
    TrackId first;
    if (target != null) {
      first = target.id;
      d.affected.addAll([for (final i in target.items) i.id]);
      final cuesOfFirst = [for (final c in lanes.first) _newCue(d, c.k0, c.k1, c.text, origin: CueOrigin.imported)];
      d.putTrack(target.copyWith(items: cuesOfFirst, transitions: const [], subtitle: spillData));
      d.affected.addAll([for (final c in cuesOfFirst) c.id]);
      ids.addAll([for (final c in cuesOfFirst) c.id]);
    } else {
      first = d.createTrack(TrackKind.subtitle, name: name, subtitle: SubtitleTrackData(language: language));
      final created = [for (final c in lanes.first) _newCue(d, c.k0, c.k1, c.text, origin: CueOrigin.imported)];
      d.addItems(first, created);
      ids.addAll([for (final c in created) c.id]);
    }
    var spilled = 0;
    final baseName = target?.name ?? name;
    for (var l = 1; l < lanes.length; l++) {
      final lane = d.createTrack(TrackKind.subtitle,
          name: baseName.isEmpty ? '' : '$baseName ${l + 1}', subtitle: spillData);
      final created = [for (final c in lanes[l]) _newCue(d, c.k0, c.k1, c.text, origin: CueOrigin.imported)];
      d.addItems(lane, created);
      ids.addAll([for (final c in created) c.id]);
      spilled += created.length;
    }
    if (spilled > 0) d.notices.add(EditNotice(SubtitleNoticeCodes.cuesSpilled, count: spilled));
    if (skipped > 0) d.notices.add(EditNotice(SubtitleNoticeCodes.cuesSkipped, count: skipped));
    d.selection = SelectionHint(ids.toSet(), primary: ids.first, lane: first);
  }

  @override
  String toString() => 'ImportSubtitles(${cues.length} cues, ${mode.name}, track: $track)';
}

// -------------------------------------------------------------------------------------------
// Track-wide settings: style, position, burn-in, language
// -------------------------------------------------------------------------------------------

/// Edits the subtitle data of an unlocked subtitle lane.
void _editSubtitleData(_Draft d, TrackId id, SubtitleTrackData Function(SubtitleTrackData data) edit) {
  final lane = _subtitleLane(d, id);
  final data = lane.subtitle ?? const SubtitleTrackData();
  final next = edit(data);
  if (next == data) return;
  d.putTrack(lane.copyWith(subtitle: next));
}

/// Sets the style shared by the cues of a lane. Ranges: `fontSizePt` in [8, 200], `maxLines`
/// 1..3, `maxWidth` in (0, 1]; anything else is `InvalidValue(<field>)`.
final class SetSubtitleStyle extends EditCommand {
  /// Creates the command.
  const SetSubtitleStyle(this.track, this.style);

  /// The lane.
  final TrackId track;

  /// The style.
  final SubtitleStyle style;

  @override
  String get label => 'Caption style';

  @override
  void _apply(_Draft d) {
    final s = style;
    if (!(s.fontSizePt >= 8 && s.fontSizePt <= 200)) d.reject(const InvalidValue('fontSizePt'));
    if (s.maxLines < 1 || s.maxLines > 3) d.reject(const InvalidValue('maxLines'));
    if (!(s.maxWidth > 0 && s.maxWidth <= 1)) d.reject(const InvalidValue('maxWidth'));
    _editSubtitleData(d, track, (data) => data.copyWith(style: s));
  }

  @override
  String toString() => 'SetSubtitleStyle($track)';
}

/// Sets the vertical placement of a lane's cues; a custom `yFraction` must be in [0, 1].
final class SetSubtitlePosition extends EditCommand {
  /// Creates the command.
  const SetSubtitlePosition(this.track, this.position);

  /// The lane.
  final TrackId track;

  /// The placement.
  final SubtitlePosition position;

  @override
  String get label => 'Caption position';

  @override
  void _apply(_Draft d) {
    final p = position;
    if (p is CustomSubtitlePosition && !(p.yFraction >= 0 && p.yFraction <= 1)) d.reject(const InvalidValue('position'));
    _editSubtitleData(d, track, (data) => data.copyWith(position: p));
  }

  @override
  String toString() => 'SetSubtitlePosition($track, $position)';
}

/// Sets a lane's default for the export sheet's "Burn into video" switch.
final class SetBurnIn extends EditCommand {
  /// Creates the command.
  const SetBurnIn(this.track, this.burnIn);

  /// The lane.
  final TrackId track;

  /// Whether to burn the captions in by default.
  final bool burnIn;

  @override
  String get label => burnIn ? 'Burn in captions' : 'Do not burn in captions';

  @override
  void _apply(_Draft d) => _editSubtitleData(d, track, (data) => data.copyWith(burnIn: burnIn));

  @override
  String toString() => 'SetBurnIn($track, $burnIn)';
}

final RegExp _languageTag = RegExp(r'^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$');

/// Sets a lane's BCP-47 language tag (`en`, `pt-BR`, `zh-Hant`); null or blank clears it.
/// Anything that is not shaped like a tag is `InvalidValue('language')`.
final class SetSubtitleLanguage extends EditCommand {
  /// Creates the command.
  const SetSubtitleLanguage(this.track, this.language);

  /// The lane.
  final TrackId track;

  /// The tag, or null to clear.
  final String? language;

  @override
  String get label => 'Caption language';

  @override
  void _apply(_Draft d) {
    final raw = language?.trim();
    final tag = raw == null || raw.isEmpty ? null : raw;
    if (tag != null && !_languageTag.hasMatch(tag)) d.reject(const InvalidValue('language'));
    _editSubtitleData(d, track, (data) => data.copyWith(language: tag));
  }

  @override
  String toString() => 'SetSubtitleLanguage($track, $language)';
}
