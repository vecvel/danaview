// OWNER: CORE-09
//
// The command framework (ARCH §7.1, domain.md §6.1).
//
// **Self-dispatching commands.** `EditCommand` is sealed; every command lives in one of this
// library's `part` files (one per command group, owners in each file's header) and implements
// `_apply(_Draft)`. There is no central switch: `applyTo`/`previewOn` (and the public
// `applyCommand`/`dryRun` in dry_run.dart) run every command through [_CommandRunner], so apply and
// dry run share **one code path**:
//
// 1. the command edits a [_Draft] — a mutable working copy over the immutable project — or refuses
//    with `d.reject(...)` (rejections are data for callers; inside the library they unwind the
//    command through the private [_Rejected] signal and are never seen as exceptions outside);
// 2. `finish()` normalizes the changed lanes generically: transitions whose clips no longer touch
//    are dropped and the rest re-clamped to `TransitionBounds` (ARCH §7.2), audio fades are clamped
//    to half of their clip, link groups left with one member are dissolved (I7);
// 3. no-op detection: a result equal to the input is `noop` (no history entry);
// 4. `LayerLimits` (limits.dart, D-14) checks items, duration and both layer caps;
// 5. post-step validation of the changed lanes (CORE-08 `validate(only:)`): any violation the
//    command introduced turns the result into `InternalInconsistency` and leaves the project
//    unchanged (violations that already existed before the command do not block edits);
// 6. any exception thrown by a command becomes `InternalInconsistency` (never rethrown).
//
// Group tickets add commands to their part files only; this file never changes for them.

library;

// The imports serve every part file. Parts cannot declare imports and group tickets never edit
// this file (BUILD_PLAN §2), so libraries that parts still waiting for their owner will need are
// imported up front; some are therefore unused until those parts land.
// ignore_for_file: unused_import

import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../eval/clip_time_map.dart';
import '../eval/evaluate.dart';
import '../eval/geometry.dart';
import '../eval/speed_math.dart';
import '../eval/text_animation_eval.dart';
import '../eval/text_layout_spec.dart';
import '../eval/transition_limits.dart';
import '../ids/ids.dart';
import '../model/audio_props.dart';
import '../model/items.dart';
import '../model/keyframes/keyframes.dart';
import '../model/marker.dart';
import '../model/pool/pool.dart';
import '../model/project.dart';
import '../model/settings.dart';
import '../model/speed_spec.dart';
import '../model/subtitle.dart';
import '../model/text_style.dart';
import '../model/timeline.dart';
import '../model/track.dart';
import '../model/transition.dart';
import '../model/view_state.dart';
import '../model/visual_props.dart';
import '../time/time.dart';
import '../validate/transition_bounds.dart';
import '../validate/validator.dart';
import '../validate/violation.dart';
import 'clipboard.dart';
import 'edit_context.dart';
import 'outcome.dart';
import 'placement.dart';
import 'rejections.dart';
import 'requantize.dart';

part 'commands/composite.dart';
part 'commands/clip_commands.dart';
part 'commands/ripple.dart';
part 'commands/clipboard_commands.dart';
part 'commands/speed_commands.dart';
part 'commands/property_commands.dart';
part 'commands/keyframe_commands.dart';
part 'commands/text_commands.dart';
part 'commands/subtitle_commands.dart';
part 'commands/caption_commands.dart';
part 'commands/transition_commands.dart';
part 'commands/track_commands.dart';
part 'commands/marker_commands.dart';
part 'commands/project_commands.dart';

/// An editing command (ARCH §7.1). Sealed: every command lives in one of this library's parts.
///
/// Commands are pure values: [applyTo] and [previewOn] never mutate their inputs, never throw and
/// return the same result for the same project and context (with a seeded id generator in the
/// same state).
@immutable
sealed class EditCommand {
  const EditCommand();

  /// History label ("Split", "Move clip", …).
  String get label;

  /// Applies the command to [project] (ARCH §7.1 `applyCommand`).
  EditOutcome applyTo(EditProject project, EditContext ctx) => _CommandRunner.run(this, project, ctx).outcome();

  /// Dry-runs the command on [project] (ARCH §7.1 `dryRun`): the same code path as [applyTo],
  /// including the limits, reported as placements for drag ghosts.
  EditPreview previewOn(EditProject project, EditContext ctx) =>
      _CommandRunner.run(this, project, ctx, preview: true).preview();

  /// The command logic: edits [d] or refuses with `d.reject(...)`.
  void _apply(_Draft d);
}

/// Internal signal carrying a rejection out of a command. Never escapes this library.
final class _Rejected implements Exception {
  _Rejected(this.rejection);
  final EditRejection rejection;
}

// -------------------------------------------------------------------------------------------
// The runner: one code path for apply and dry run.
// -------------------------------------------------------------------------------------------

/// Whether dry runs also run the post-step validation (they do: dry run and apply must agree).
const bool _validateInPreview = true;

final class _Run {
  _Run._(this.base, this.result, this.draft, this.finished, this.rejection, this.noop);

  factory _Run.rejected(EditProject base, EditRejection r) => _Run._(base, base, null, null, r, false);

  final EditProject base;
  final EditProject result;
  final _Draft? draft;
  final _Finished? finished;
  final EditRejection? rejection;
  final bool noop;

  EditOutcome outcome() {
    final r = rejection;
    if (r != null) return EditOutcome.rejected(base, r);
    final d = draft!;
    if (noop) return EditOutcome(project: base, noop: true, selection: d.selection, notices: d.notices);
    final f = finished!;
    return EditOutcome(
      project: result,
      affected: d.affected,
      changedTracks: f.changed,
      createdTracks: f.created,
      selection: d.selection,
      notices: d.notices,
    );
  }

  EditPreview preview() {
    final r = rejection;
    if (r != null) return EditPreview.rejected(r);
    final d = draft!;
    final created = finished?.created ?? const <TrackId>{};
    final tracks = result.tracks;
    final newTracks = <TrackId, NewTrack>{};
    for (var i = 0; i < tracks.length; i++) {
      final t = tracks[i];
      if (created.contains(t.id)) newTracks[t.id] = NewTrack(id: t.id, kind: t.kind, index: i);
    }
    final placements = <ItemId, Placement>{};
    final index = result.index;
    for (final id in d.affected) {
      final loc = index.locate(id);
      if (loc == null) continue;
      placements[id] = Placement(loc.track.id, loc.item.range, newTrack: newTracks[loc.track.id]);
    }
    return EditPreview(placements: placements, createsTracks: newTracks.values.toList(), clampedTo: d.clampedTo);
  }
}

abstract final class _CommandRunner {
  static _Run run(EditCommand command, EditProject project, EditContext ctx, {bool preview = false}) {
    var base = project;
    final livePool = ctx.pool;
    if (livePool != null && !identical(livePool, base.pool)) base = base.copyWith(pool: livePool);
    final _Draft d;
    final _Finished f;
    try {
      d = _Draft(base, ctx);
      command._apply(d);
      f = d.finish();
    } on _Rejected catch (e) {
      return _Run.rejected(base, e.rejection);
    } catch (e) {
      return _Run.rejected(base, InternalInconsistency(const [], detail: e.runtimeType.toString()));
    }
    if (f.noop) return _Run._(base, base, d, f, null, true);
    final after = f.project;
    try {
      final limit = ctx.limits.check(base, after, ctx.policy);
      if (limit != null) return _Run.rejected(base, limit);
    } catch (e) {
      final v = _newViolations(base, after, f.changed);
      return _Run.rejected(base, InternalInconsistency(v, detail: v.isEmpty ? e.runtimeType.toString() : ''));
    }
    if (!preview || _validateInPreview) {
      final v = _newViolations(base, after, f.changed);
      if (v.isNotEmpty) return _Run.rejected(base, InternalInconsistency(v));
    }
    final stamp = ctx.stamp;
    final result = stamp == null ? after : _stamped(after, f.changed, stamp);
    return _Run._(base, result, d, f, null, false);
  }

  /// The violations of [after] on [changed] lanes (plus project-level ones) that [before] did not
  /// already have (compared by code, track and subject).
  static List<Violation> _newViolations(EditProject before, EditProject after, Set<TrackId> changed) {
    final now = validate(after, only: changed);
    if (now.isEmpty) return const [];
    final had = {for (final v in validate(before, only: changed)) (v.code, v.track, v.subject)};
    return [for (final v in now) if (!had.contains((v.code, v.track, v.subject))) v];
  }

  static EditProject _stamped(EditProject p, Set<TrackId> changed, int stamp) {
    final tl = p.timeline;
    return p.copyWith(
      timeline: Timeline(
        settings: tl.settings,
        tracks: [for (final t in tl.tracks) changed.contains(t.id) ? t.copyWith(changedAt: stamp) : t],
        markers: tl.markers,
        revision: stamp,
      ),
    );
  }
}

// -------------------------------------------------------------------------------------------
// The draft: a working copy commands edit.
// -------------------------------------------------------------------------------------------

/// Where an item is in a [_Draft].
typedef _Loc = ({Track track, int trackIndex, int itemIndex, TimelineItem item});

final class _Finished {
  _Finished(this.project, this.changed, this.created, {required this.noop});
  final EditProject project;
  final Set<TrackId> changed;
  final Set<TrackId> created;
  final bool noop;
}

/// A mutable working copy of a project for one command run. Lanes are replaced wholesale
/// (unchanged lanes stay the identical objects, so caches keyed by identity keep working).
final class _Draft {
  _Draft(this.base, this.ctx)
      : tracks = List.of(base.tracks),
        pool = base.pool,
        settings = base.settings,
        markers = base.markers;

  /// The project the command started from.
  final EditProject base;

  /// The command context.
  final EditContext ctx;

  /// Working lanes in canonical order.
  final List<Track> tracks;

  /// Working pool.
  MediaPool pool;

  /// Working settings.
  ProjectSettings settings;

  /// Working markers (sorted by time).
  List<Marker> markers;

  /// Items created, changed or removed.
  final Set<ItemId> affected = {};

  /// Lanes replaced or created.
  final Set<TrackId> changed = {};

  /// Lanes created.
  final Set<TrackId> created = {};

  /// Notices for the user.
  final List<EditNotice> notices = [];

  /// Selection suggestion.
  SelectionHint? selection;

  /// Clamped range for `clamp: true` gestures.
  TimeRange? clampedTo;

  /// Links whose groups may have lost members (checked by [finish]).
  final Set<LinkId> _looseLinks = {};

  FrameRate get rate => settings.frameRate;
  EditPolicy get policy => ctx.policy;
  IdGenerator get ids => ctx.ids;
  ViewState get view => base.view;

  /// Refuses the command.
  Never reject(EditRejection r) => throw _Rejected(r);

  // ----- frames -----

  int frameOf(TimeUs t) => rate.frameIndexOf(t);
  TimeUs timeOf(int k) => rate.timeOfFrame(k);
  int framesOf(TimelineItem item) => frameOf(item.end) - frameOf(item.start);

  /// A µs delta as whole frames (nearest, symmetric for negative deltas).
  int deltaFrames(TimeUs delta) => delta < 0 ? -rate.frameIndexNearest(-delta) : rate.frameIndexNearest(delta);

  /// The grid frame count nearest to a µs length (≥ [min]).
  int lengthFrames(TimeUs length, {int min = 1}) {
    final n = rate.frameIndexNearest(length);
    return n < min ? min : n;
  }

  // ----- lanes -----

  Map<TrackId, int>? _trackIndex;

  int indexOfTrack(TrackId id) {
    final m = _trackIndex ??= {for (var i = 0; i < tracks.length; i++) tracks[i].id: i};
    return m[id] ?? -1;
  }

  Track? trackOrNull(TrackId id) {
    final i = indexOfTrack(id);
    return i < 0 ? null : tracks[i];
  }

  /// The lane [id] or `ItemNotFound`.
  Track track(TrackId id) => trackOrNull(id) ?? reject(ItemNotFound(id));

  /// The lane [id], refusing with `TrackLocked` when it is locked.
  Track editableTrack(TrackId id) {
    final t = track(id);
    if (t.locked) reject(TrackLocked(id));
    return t;
  }

  /// The main lane, if any.
  Track? get mainTrack => TrackOrder.mainTrack(tracks);

  void _invalidate() {
    _trackIndex = null;
    _itemPos = null;
    _links = null;
  }

  /// Replaces the lane with the same id.
  void putTrack(Track t) {
    final i = indexOfTrack(t.id);
    if (i < 0) throw StateError('unknown lane');
    tracks[i] = t;
    changed.add(t.id);
    _itemPos = null;
    _links = null;
  }

  /// Replaces the items (and optionally the transitions) of lane [id]; items are sorted by start.
  void setItems(TrackId id, List<TimelineItem> items, {List<Transition>? transitions}) {
    final t = track(id);
    final sorted = List<TimelineItem>.of(items)..sort(_byStart);
    putTrack(t.copyWith(items: sorted, transitions: transitions));
  }

  /// Creates a lane of [kind] at the top of the kind's group (`TrackOrder.insertIndexFor`) and
  /// returns its id. The first video lane becomes the main lane.
  TrackId createTrack(TrackKind kind, {AudioRole? role, String name = '', SubtitleTrackData? subtitle}) {
    final id = ids.trackId();
    final index = TrackOrder.insertIndexFor(tracks, kind);
    final isMain = kind == TrackKind.video && TrackOrder.mainTrack(tracks) == null;
    tracks.insert(
      index,
      Track(
        id: id,
        kind: kind,
        name: name,
        isMain: isMain,
        audioRole: kind == TrackKind.audio ? role : null,
        subtitle: kind == TrackKind.subtitle ? (subtitle ?? const SubtitleTrackData()) : null,
      ),
    );
    _invalidate();
    created.add(id);
    changed.add(id);
    return id;
  }

  // ----- items -----

  Map<ItemId, (int, int)>? _itemPos;

  Map<ItemId, (int, int)> get _positions {
    final cached = _itemPos;
    if (cached != null) return cached;
    final m = <ItemId, (int, int)>{};
    for (var ti = 0; ti < tracks.length; ti++) {
      final items = tracks[ti].items;
      for (var ii = 0; ii < items.length; ii++) {
        m.putIfAbsent(items[ii].id, () => (ti, ii));
      }
    }
    return _itemPos = m;
  }

  /// Where item [id] is, or null.
  _Loc? find(ItemId id) {
    final p = _positions[id];
    if (p == null) return null;
    final t = tracks[p.$1];
    return (track: t, trackIndex: p.$1, itemIndex: p.$2, item: t.items[p.$2]);
  }

  /// Where item [id] is, or `ItemNotFound`.
  _Loc locate(ItemId id) => find(id) ?? reject(ItemNotFound(id));

  /// The item [id] or `ItemNotFound`.
  TimelineItem item(ItemId id) => locate(id).item;

  Map<LinkId, List<ItemId>>? _links;

  /// Link groups of the working state.
  Map<LinkId, List<ItemId>> get linkGroups {
    final cached = _links;
    if (cached != null) return cached;
    final m = <LinkId, List<ItemId>>{};
    for (final t in tracks) {
      for (final i in t.items) {
        final l = i.link;
        if (l != null) (m[l] ??= <ItemId>[]).add(i.id);
      }
    }
    return _links = m;
  }

  /// [ids] plus every member of their link groups (links move, split, delete and duplicate
  /// together). Unknown ids are kept (callers locate them and refuse).
  Set<ItemId> withPartners(Iterable<ItemId> ids) {
    final out = <ItemId>{};
    for (final id in ids) {
      out.add(id);
      final link = find(id)?.item.link;
      if (link != null) out.addAll(linkGroups[link] ?? const []);
    }
    return out;
  }

  /// The other members of [item]'s link group.
  List<ItemId> partnersOf(TimelineItem item) {
    final l = item.link;
    if (l == null) return const [];
    return [for (final id in linkGroups[l] ?? const <ItemId>[]) if (id != item.id) id];
  }

  /// Removes [ids] from their lanes (their transitions are dropped by [finish]). Returns the
  /// removed items by lane, in lane order.
  Map<TrackId, List<TimelineItem>> removeItems(Set<ItemId> ids) {
    final removed = <TrackId, List<TimelineItem>>{};
    for (final t in List<Track>.of(tracks)) {
      if (!t.items.any((i) => ids.contains(i.id))) continue;
      final keep = <TimelineItem>[];
      final gone = <TimelineItem>[];
      for (final i in t.items) {
        (ids.contains(i.id) ? gone : keep).add(i);
      }
      for (final i in gone) {
        final l = i.link;
        if (l != null) _looseLinks.add(l);
      }
      removed[t.id] = gone;
      putTrack(t.copyWith(items: keep));
    }
    affected.addAll(ids);
    return removed;
  }

  /// Adds [items] to lane [lane] (kept sorted).
  void addItems(TrackId lane, List<TimelineItem> items) {
    if (items.isEmpty) return;
    final t = track(lane);
    setItems(lane, [...t.items, ...items]);
    for (final i in items) {
      affected.add(i.id);
    }
  }

  /// Replaces items by id in place (same lane), re-sorting the lanes that changed.
  void replaceItems(Iterable<TimelineItem> items) {
    final byLane = <TrackId, Map<ItemId, TimelineItem>>{};
    for (final item in items) {
      final loc = locate(item.id);
      (byLane[loc.track.id] ??= {})[item.id] = item;
    }
    for (final e in byLane.entries) {
      final t = track(e.key);
      setItems(e.key, [for (final i in t.items) e.value[i.id] ?? i]);
      for (final i in e.value.values) {
        affected.add(i.id);
        final l = i.link;
        if (l != null) _looseLinks.add(l);
      }
      for (final i in t.items) {
        if (e.value.containsKey(i.id)) {
          final l = i.link;
          if (l != null) _looseLinks.add(l);
        }
      }
    }
  }

  /// Places [items] (already timed, one source lane's group) per D-11: on [preferred] when it is
  /// unlocked and every range is free there; otherwise on the nearest free unlocked lane of
  /// [kind] (order of `LanePlacement.candidates`, filtered by [accept]); otherwise on a new lane of
  /// [kind] with [role]. With `OverlapPolicy.reject` an occupied [preferred] lane refuses with
  /// `WouldOverlap` instead (and `NoRoom` when no lane is preferred and none is free). Returns the
  /// lane used.
  TrackId placeGroup(
    List<TimelineItem> items, {
    required TrackKind kind,
    TrackId? preferred,
    AudioRole? role,
    bool Function(Track track)? accept,
  }) {
    final ranges = [for (final i in items) i.range];
    final pIndex = preferred == null ? -1 : indexOfTrack(preferred);
    if (pIndex >= 0) {
      final p = tracks[pIndex];
      if (!p.locked && LanePlacement.isFree(p, ranges)) {
        addItems(p.id, items);
        return p.id;
      }
      if (policy.overlap == OverlapPolicy.reject) {
        if (p.locked) reject(TrackLocked(p.id));
        for (final r in ranges) {
          final hit = LanePlacement.firstOverlap(p, r);
          if (hit != null) reject(WouldOverlap(p.id, hit.range.intersect(r) ?? r));
        }
      }
    }
    final i = LanePlacement.nearestFree(
      tracks,
      kind: kind,
      preferred: pIndex >= 0 ? pIndex : null,
      ranges: ranges,
      accept: accept,
    );
    final TrackId lane;
    if (i != null) {
      lane = tracks[i].id;
    } else {
      if (policy.overlap == OverlapPolicy.reject) reject(const NoRoom());
      lane = createTrack(kind, role: role);
    }
    addItems(lane, items);
    if (preferred != null && lane != preferred) {
      notices.add(EditNotice(EditNoticeCodes.placedOnOtherLane, items: {for (final i in items) i.id}));
    }
    return lane;
  }

  /// Moves [transitions] from lane [from] to lane [to] (a group of touching clips changed lanes).
  void transferTransitions(TrackId from, TrackId to, List<Transition> transitions) {
    if (transitions.isEmpty || from == to) return;
    final ids = {for (final t in transitions) t.id};
    final src = track(from);
    putTrack(src.copyWith(transitions: [for (final t in src.transitions) if (!ids.contains(t.id)) t]));
    final dst = track(to);
    putTrack(dst.copyWith(transitions: [...dst.transitions, ...transitions]));
  }

  /// Marks [link] for the singleton check of [finish].
  void noteLink(LinkId? link) {
    if (link != null) _looseLinks.add(link);
  }

  /// The media of [clip] in the working pool, if present.
  MediaAsset? assetOf(MediaClip clip) => pool[clip.media];

  /// Whether [clip] plays time-based media (video, audio, recording): trims are limited by the
  /// source range.
  bool isTimeBased(MediaClip clip) {
    final a = assetOf(clip);
    return a != null && _timeBased(a.kind);
  }

  /// [item] moved by [df] frames (edges stay on the grid). Media clips keep their source range
  /// within the media (a ±1 µs duration change on the grid is absorbed by `sourceIn`).
  TimelineItem shiftFrames(TimelineItem item, int df) {
    if (df == 0) return item;
    final s = timeOf(frameOf(item.start) + df);
    final e = timeOf(frameOf(item.end) + df);
    final moved = _retimed(item, s, e - s);
    return moved is MediaClip ? fitSource(moved) : moved;
  }

  /// [item] placed at frame [startFrame] with [frames] frames.
  TimelineItem placeAt(TimelineItem item, int startFrame, int frames) {
    final s = timeOf(startFrame);
    final e = timeOf(startFrame + frames);
    final moved = _retimed(item, s, e - s);
    return moved is MediaClip ? fitSource(moved) : moved;
  }

  /// [clip] with `sourceIn` pulled back by the few µs its derived source end may overrun the media
  /// after a grid re-timing (no-op otherwise).
  MediaClip fitSource(MediaClip clip) {
    final asset = assetOf(clip);
    if (asset == null || !_timeBased(asset.kind) || !TransitionBounds.speedValid(clip.speed)) return clip;
    final over = clip.sourceIn + ClipTimeMap.sourceLengthOf(clip.duration, clip.speed) - asset.probe.duration;
    if (over <= 0 || over > clip.sourceIn) return clip;
    return clip.copyWith(sourceIn: clip.sourceIn - over);
  }

  // ----- finishing -----

  /// The working state as a project (no normalization). Returns [base] when nothing changed.
  EditProject snapshot() {
    if (changed.isEmpty && identical(pool, base.pool) && identical(settings, base.settings) && identical(markers, base.markers)) {
      return base;
    }
    return base.copyWith(
      timeline: Timeline(settings: settings, tracks: tracks, markers: markers, revision: base.revision),
      pool: pool,
    );
  }

  /// Adopts the finished result of a child draft (composite commands).
  void absorb(_Draft child, _Finished f) {
    tracks
      ..clear()
      ..addAll(f.project.tracks);
    pool = f.project.pool;
    settings = f.project.settings;
    markers = f.project.markers;
    _invalidate();
    if (!f.noop) {
      affected.addAll(child.affected);
      changed.addAll(f.changed);
      created.addAll(f.created);
    }
    notices.addAll(child.notices);
    selection = child.selection ?? selection;
    clampedTo = child.clampedTo ?? clampedTo;
  }

  /// Normalizes the changed lanes and builds the result (see the file header).
  _Finished finish() {
    _dissolveSingletonLinks();
    var removedTransitions = 0;
    var shortenedTransitions = 0;
    for (var ti = 0; ti < tracks.length; ti++) {
      final t = tracks[ti];
      if (!changed.contains(t.id)) continue;
      var items = t.items;
      // Fades fit their clip (each ≤ half of the clip).
      if (affected.isNotEmpty) {
        List<TimelineItem>? fixed;
        for (var i = 0; i < items.length; i++) {
          final item = items[i];
          if (item is! MediaClip || !affected.contains(item.id)) continue;
          final c = _clampFades(item, rate);
          if (!identical(c, item)) (fixed ??= List.of(items))[i] = c;
        }
        if (fixed != null) items = fixed;
      }
      final (transitions, removed, shortened) = _normalizedTransitions(t, items);
      removedTransitions += removed;
      shortenedTransitions += shortened;
      if (!identical(items, t.items) || !identical(transitions, t.transitions)) {
        tracks[ti] = t.copyWith(items: items, transitions: transitions);
      }
    }
    if (removedTransitions > 0) {
      notices.add(EditNotice(EditNoticeCodes.transitionsRemoved, count: removedTransitions));
    }
    if (shortenedTransitions > 0) {
      notices.add(EditNotice(EditNoticeCodes.transitionsShortened, count: shortenedTransitions));
    }
    _invalidate();

    final existing = {for (final t in tracks) t.id};
    final changedNow = {for (final id in changed) if (existing.contains(id)) id};
    final createdNow = {for (final id in created) if (existing.contains(id)) id};
    final noop = _isNoop();
    if (noop) return _Finished(base, const {}, const {}, noop: true);
    final project = base.copyWith(
      timeline: Timeline(settings: settings, tracks: tracks, markers: markers, revision: base.revision),
      pool: pool,
    );
    // Deleted lanes still count as changed for validation of the project-level structure.
    return _Finished(project, {...changedNow, ...changed.where((id) => !existing.contains(id))}, createdNow, noop: false);
  }

  bool _isNoop() {
    if (!identical(pool, base.pool) && pool != base.pool) return false;
    if (!identical(settings, base.settings) && settings != base.settings) return false;
    if (!identical(markers, base.markers) && !const ListEquality<Marker>().equals(markers, base.markers)) return false;
    final before = base.tracks;
    if (before.length != tracks.length) return false;
    for (var i = 0; i < tracks.length; i++) {
      final a = tracks[i];
      final b = before[i];
      if (identical(a, b)) continue;
      if (a != b) return false;
    }
    return true;
  }

  /// Clears the link of members left alone in their group (I7: groups have ≥ 2 members).
  void _dissolveSingletonLinks() {
    if (_looseLinks.isEmpty) return;
    final groups = <LinkId, List<ItemId>>{};
    for (final t in tracks) {
      for (final i in t.items) {
        final l = i.link;
        if (l != null && _looseLinks.contains(l)) (groups[l] ??= <ItemId>[]).add(i.id);
      }
    }
    final lonely = <ItemId>{
      for (final g in groups.values)
        if (g.length == 1) g.first,
    };
    if (lonely.isEmpty) return;
    for (var ti = 0; ti < tracks.length; ti++) {
      final t = tracks[ti];
      if (!t.items.any((i) => lonely.contains(i.id))) continue;
      tracks[ti] = t.copyWith(items: [for (final i in t.items) lonely.contains(i.id) ? _withLink(i, null) : i]);
      changed.add(t.id);
      affected.addAll(t.items.where((i) => lonely.contains(i.id)).map((i) => i.id));
    }
    _invalidate();
  }

  /// The transitions of [track] (with [items]) that still join touching clips, one per cut,
  /// sorted by cut and clamped to their limits; plus the counts removed and shortened.
  (List<Transition>, int, int) _normalizedTransitions(Track track, List<TimelineItem> items) {
    final trs = track.transitions;
    if (trs.isEmpty) return (trs, 0, 0);
    final visual = track.kind == TrackKind.video || track.kind == TrackKind.overlay;
    final position = <ItemId, int>{for (var i = 0; i < items.length; i++) items[i].id: i};
    final kept = <Transition>[];
    final lefts = <ItemId>{};
    final rights = <ItemId>{};
    var removed = 0;
    for (final tr in trs) {
      final li = position[tr.left];
      final ri = position[tr.right];
      final ok = visual &&
          li != null &&
          ri != null &&
          ri == li + 1 &&
          items[li] is MediaClip &&
          items[ri] is MediaClip &&
          items[li].end == items[ri].start &&
          tr.durationFrames >= 1 &&
          !lefts.contains(tr.left) &&
          !rights.contains(tr.right);
      if (!ok) {
        removed++;
        continue;
      }
      lefts.add(tr.left);
      rights.add(tr.right);
      kept.add(tr);
    }
    kept.sort((a, b) => position[a.left]!.compareTo(position[b.left]!));
    var shortened = 0;
    for (var i = 0; i < kept.length; i++) {
      final tr = kept[i];
      final left = items[position[tr.left]!] as MediaClip;
      final right = items[position[tr.right]!] as MediaClip;
      final prev = i > 0 && kept[i - 1].right == tr.left ? kept[i - 1] : null;
      final next = i + 1 < kept.length && kept[i + 1].left == tr.right ? kept[i + 1] : null;
      final max = TransitionBounds.maxFramesBetween(
        left: left,
        right: right,
        kind: tr.kind,
        rate: rate,
        pool: pool,
        framesBeforeInLeft: prev == null ? 0 : (prev.durationFrames + 1) ~/ 2,
        framesAfterInRight: next == null ? 0 : next.durationFrames ~/ 2,
      );
      if (tr.durationFrames <= max) continue;
      if (max < 1) {
        kept.removeAt(i);
        i--;
        removed++;
      } else {
        kept[i] = tr.copyWith(durationFrames: max);
        shortened++;
      }
    }
    if (removed == 0 && shortened == 0 && const ListEquality<Transition>().equals(kept, trs)) return (trs, 0, 0);
    return (kept, removed, shortened);
  }
}

// -------------------------------------------------------------------------------------------
// Item helpers shared by the command parts.
// -------------------------------------------------------------------------------------------

int _byStart(TimelineItem a, TimelineItem b) => a.start.compareTo(b.start);

bool _timeBased(MediaKind k) => k == MediaKind.video || k == MediaKind.audio || k == MediaKind.recording;

/// [item] with a new start and duration (nothing else changes).
TimelineItem _retimed(TimelineItem item, TimeUs start, TimeUs duration) => switch (item) {
      MediaClip() => item.copyWith(start: start, duration: duration),
      TextItem() => item.copyWith(start: start, duration: duration),
      SubtitleCue() => item.copyWith(start: start, duration: duration),
    };

/// [item] with a new id.
TimelineItem _withId(TimelineItem item, ItemId id) => switch (item) {
      MediaClip() => item.withId(id),
      TextItem() => TextItem(
          id: id,
          start: item.start,
          duration: item.duration,
          link: item.link,
          label: item.label,
          text: item.text,
          style: item.style,
          animation: item.animation,
          transform: item.transform,
          keyframes: item.keyframes,
        ),
      SubtitleCue() => SubtitleCue(
          id: id,
          start: item.start,
          duration: item.duration,
          link: item.link,
          label: item.label,
          text: item.text,
          origin: item.origin,
          editedAfterGeneration: item.editedAfterGeneration,
        ),
    };

/// [item] with its link set to [link] (null clears it).
TimelineItem _withLink(TimelineItem item, LinkId? link) => switch (item) {
      MediaClip() => item.copyWith(link: link),
      TextItem() => item.copyWith(link: link),
      SubtitleCue() => SubtitleCue(
          id: item.id,
          start: item.start,
          duration: item.duration,
          link: link,
          label: item.label,
          text: item.text,
          origin: item.origin,
          editedAfterGeneration: item.editedAfterGeneration,
        ),
    };

/// [clip] with fades shortened so each is at most half of the clip (in frames, I9).
MediaClip _clampFades(MediaClip clip, FrameRate rate) {
  final a = clip.audio;
  if (a.fadeIn == 0 && a.fadeOut == 0) return clip;
  final k0 = rate.frameIndexOf(clip.start);
  final k1 = rate.frameIndexOf(clip.end);
  final half = (k1 - k0) ~/ 2;
  var fadeIn = a.fadeIn;
  var fadeOut = a.fadeOut;
  if (fadeIn > 0 && itemLengthFrames(rate, clip, fadeIn, fromEnd: false) > half) {
    fadeIn = rate.timeOfFrame(k0 + half) - clip.start;
  }
  if (fadeOut > 0 && itemLengthFrames(rate, clip, fadeOut, fromEnd: true) > half) {
    fadeOut = clip.end - rate.timeOfFrame(k1 - half);
  }
  if (fadeIn == a.fadeIn && fadeOut == a.fadeOut) return clip;
  return clip.copyWith(audio: a.copyWith(fadeIn: fadeIn, fadeOut: fadeOut));
}
