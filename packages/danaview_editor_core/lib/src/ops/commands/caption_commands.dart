// OWNER: CORE-15
//
// The generated-caption commands (ai.md §10.2, adopted verbatim; schema 1): `AddGeneratedCaptionTrack`
// ("Auto captions") and `ReplaceGeneratedCaptions` ("Regenerate captions"). AI proposes
// `SubtitleCueDraft`s and provenance; these commands own what goes into the project.
//
// Requirements (ai.md §10.2):
// 1. each command is **one history entry**, validated as a whole; a locked target lane is the
//    `TrackLocked` rejection ("Unlock the track to replace its captions");
// 2. generated cues carry `CueOrigin.generated` and `editedAfterGeneration == false`; any later
//    text or timing edit sets the flag (subtitle_commands.dart);
// 3. cue ids are fresh;
// 5. the new lane goes on top of the subtitle lanes and is the suggested selection
//    (`SelectionHint.lane`).
//
// Drafts are put on the grid (nearest frames, at least one frame, text trimmed). The AI pipeline
// hands over non-overlapping cues, but the commands do not trust that: a draft that starts before
// the previous one ended starts at its end, and a draft with no frame left is dropped (notice
// `cuesSkipped`). Blank drafts are dropped too.

part of '../edit_command.dart';

/// Creates a subtitle lane of generated captions (label "Auto captions"): one history entry.
///
/// The lane is named [trackName] (e.g. `Captions (English)`), tagged with [language] and carries
/// [provenance]; the lane's style, position and burn-in are the defaults. Rejections:
/// `InvalidValue('cues')` (no drafts, or none with text).
final class AddGeneratedCaptionTrack extends EditCommand {
  /// Creates the command.
  AddGeneratedCaptionTrack({
    required this.trackName,
    required this.language,
    required this.provenance,
    required List<SubtitleCueDraft> cues,
  }) : cues = List.unmodifiable(cues);

  /// Name of the new lane.
  final String trackName;

  /// BCP-47 language of the captions.
  final String language;

  /// What produced the captions.
  final CaptionProvenance provenance;

  /// The proposed cues.
  final List<SubtitleCueDraft> cues;

  @override
  String get label => 'Auto captions';

  @override
  void _apply(_Draft d) {
    if (cues.isEmpty) d.reject(const InvalidValue('cues'));
    var dropped = 0;
    final grid = _fitCues(d, _gridCues(d, cues, () => dropped++), const [], () => dropped++);
    if (grid.isEmpty) d.reject(const InvalidValue('cues'));
    final lane = d.createTrack(
      TrackKind.subtitle,
      name: trackName,
      subtitle: SubtitleTrackData(language: language, provenance: provenance),
    );
    final created = [for (final c in grid) _newCue(d, c.k0, c.k1, c.text, origin: CueOrigin.generated)];
    d.addItems(lane, created);
    if (dropped > 0) d.notices.add(EditNotice(SubtitleNoticeCodes.cuesSkipped, count: dropped));
    d.selection = SelectionHint(const {}, lane: lane);
  }

  @override
  String toString() => 'AddGeneratedCaptionTrack($trackName, $language, ${cues.length} cues)';
}

/// Replaces the captions of a subtitle lane (label "Regenerate captions"): one history entry.
///
/// With [range] null every cue of the lane is replaced; with a range only the cues that overlap
/// it (`start < range.end` and `range.start < end`) are replaced and the others stay. The new cues
/// are fitted around the cues that stay (they start after the previous one and stop where the next
/// begins). The lane's provenance becomes [provenance]; its language is set from the provenance
/// when the lane had none.
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `IncompatibleTrack` (not a subtitle lane),
/// `InvalidValue('cues')` (no drafts), `InvalidValue('range')` (empty or reversed).
final class ReplaceGeneratedCaptions extends EditCommand {
  /// Creates the command.
  ReplaceGeneratedCaptions({
    required this.track,
    this.range,
    required this.provenance,
    required List<SubtitleCueDraft> cues,
  }) : cues = List.unmodifiable(cues);

  /// The lane.
  final TrackId track;

  /// What to replace, or null for the whole lane.
  final TimeRange? range;

  /// What produced the new captions.
  final CaptionProvenance provenance;

  /// The proposed cues.
  final List<SubtitleCueDraft> cues;

  @override
  String get label => 'Regenerate captions';

  @override
  void _apply(_Draft d) {
    final lane = _subtitleLane(d, track);
    if (cues.isEmpty) d.reject(const InvalidValue('cues'));
    final r = range;
    if (r != null && r.end <= r.start) d.reject(const InvalidValue('range'));
    final kept = <TimelineItem>[];
    final removed = <TimelineItem>[];
    for (final c in lane.items) {
      final replaced = r == null || (c.start < r.end && r.start < c.end);
      (replaced ? removed : kept).add(c);
    }
    var dropped = 0;
    final grid = _fitCues(d, _gridCues(d, cues, () => dropped++), kept, () => dropped++);
    final created = [for (final c in grid) _newCue(d, c.k0, c.k1, c.text, origin: CueOrigin.generated)];
    final data = lane.subtitle ?? const SubtitleTrackData();
    d.affected.addAll([for (final c in removed) c.id]);
    d.setItems(lane.id, [...kept, ...created]);
    d.putTrack(d.track(lane.id).copyWith(
          subtitle: data.copyWith(provenance: provenance, language: data.language ?? provenance.language),
        ));
    d.affected.addAll([for (final c in created) c.id]);
    if (dropped > 0) d.notices.add(EditNotice(SubtitleNoticeCodes.cuesSkipped, count: dropped));
    d.selection = SelectionHint(const {}, lane: lane.id);
  }

  @override
  String toString() => 'ReplaceGeneratedCaptions($track, range: $range, ${cues.length} cues)';
}
