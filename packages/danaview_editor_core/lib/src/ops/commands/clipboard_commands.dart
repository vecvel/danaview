// OWNER: CORE-11
//
// Clipboard and media commands (ARCH §7.2, domain.md §6.2): `DuplicateItems`, `PasteItems`,
// `ReplaceMedia`, `ExtractAudio`, `LinkItems`, `UnlinkItems`. Cut is `cutItems` in
// ops/clipboard.dart (copy + `DeleteItems` in one `CompositeCommand`, D-16).
//
// * Duplicates and pastes get fresh item, link and transition ids; link groups and transitions
//   between copied clips are kept among the copies.
// * Occupied space follows D-11 (nearest free lane of the kind, creating one); with ripple on
//   (the command's flag, or the project's ripple mode when null) an occupied target opens space
//   instead (ripple insert; partners follow, D-10).
// * A cross-project paste adds the payload's assets the target pool lacks — matched by content
//   (kind + quickHash + size, or the derived spec), so pasting twice imports nothing the second
//   time — re-minting a media id only when the source id is taken by other content. A paste into
//   a project of another frame rate re-quantizes offsets, lengths, keys, fades and text animation
//   lengths onto the target grid.

part of '../edit_command.dart';

// -------------------------------------------------------------------------------------------
// DuplicateItems
// -------------------------------------------------------------------------------------------

/// Copies items (plus link partners) right after the selection's end on their own lanes, keeping
/// relative offsets (ux.md §14.4). Occupied: ripple when on, else the nearest free lane (D-11);
/// `NoRoom` when the policy may not use another lane.
final class DuplicateItems extends EditCommand {
  /// Creates the command; [ripple] null uses the project's ripple mode.
  DuplicateItems(Set<ItemId> ids, {this.ripple}) : ids = Set.unmodifiable(ids);

  /// Items to duplicate.
  final Set<ItemId> ids;

  /// Ripple when the target space is occupied (null: `ViewState.rippleEnabled`).
  final bool? ripple;

  @override
  String get label => 'Duplicate';

  @override
  void _apply(_Draft d) {
    if (ids.isEmpty) d.reject(const InvalidValue('ids'));
    for (final id in ids) {
      d.locate(id);
    }
    final all = d.withPartners(ids);
    final locs = [for (final id in all) d.locate(id)]..sort((a, b) => a.trackIndex != b.trackIndex
        ? a.trackIndex.compareTo(b.trackIndex)
        : a.item.start.compareTo(b.item.start));
    for (final l in locs) {
      if (l.track.locked) d.reject(TrackLocked(l.track.id));
    }
    var minK = 1 << 40;
    var maxK = -(1 << 40);
    for (final l in locs) {
      final s = d.frameOf(l.item.start);
      final e = d.frameOf(l.item.end);
      if (s < minK) minK = s;
      if (e > maxK) maxK = e;
    }
    final offset = maxK - minK;
    final newIds = <ItemId, ItemId>{for (final l in locs) l.item.id: d.ids.itemId()};
    final newLinks = <LinkId, LinkId>{};
    final groups = <TrackId, List<TimelineItem>>{};
    for (final l in locs) {
      final link = l.item.link;
      final copy = _withLink(_withId(l.item, newIds[l.item.id]!), link == null ? null : newLinks.putIfAbsent(link, d.ids.linkId));
      (groups[l.track.id] ??= <TimelineItem>[]).add(d.shiftFrames(copy, offset));
    }
    final transitions = <TrackId, List<Transition>>{
      for (final laneId in groups.keys)
        laneId: [
          for (final tr in d.track(laneId).transitions)
            if (newIds[tr.left] case final l?)
              if (newIds[tr.right] case final r?)
                Transition(id: d.ids.transitionId(), left: l, right: r, kind: tr.kind, durationFrames: tr.durationFrames, direction: tr.direction),
        ],
    };
    final occupied = groups.entries.any((e) => !LanePlacement.isFree(d.track(e.key), [for (final i in e.value) i.range]));
    final rippleOn = ripple ?? d.view.rippleEnabled;
    if (occupied && rippleOn) {
      d.openGap(groups.keys, d.timeOf(maxK), offset);
    } else if (occupied && d.policy.overlap == OverlapPolicy.reject) {
      d.reject(const NoRoom());
    }
    for (final e in groups.entries) {
      final lane = d.track(e.key);
      final used = d.placeGroup(e.value, kind: lane.kind, preferred: lane.id, role: lane.audioRole);
      _addTransitions(d, used, transitions[e.key]!);
    }
    _checkLinksOnDistinctLanes(d, newIds.values.toSet());
    final first = newIds[ids.first]!;
    d.selection = SelectionHint({for (final id in ids) newIds[id]!}, primary: first);
  }

  @override
  String toString() => 'DuplicateItems($ids, ripple: $ripple)';
}

void _addTransitions(_Draft d, TrackId lane, List<Transition> transitions) {
  if (transitions.isEmpty) return;
  final t = d.track(lane);
  d.putTrack(t.copyWith(transitions: [...t.transitions, ...transitions]));
}

// -------------------------------------------------------------------------------------------
// PasteItems
// -------------------------------------------------------------------------------------------

/// Pastes a [payload] at [at] (ux.md §14.4): items keep their relative offsets and lane kinds;
/// the first group whose kind fits [preferTrack] goes there, the others to the first free lane of
/// their kind (created as needed). Missing media is added to the pool (see the file header).
final class PasteItems extends EditCommand {
  /// Creates the command; [ripple] null uses the project's ripple mode.
  PasteItems(this.payload, this.at, {this.preferTrack, this.ripple});

  /// What to paste.
  final ClipboardPayload payload;

  /// Where the earliest item starts (nearest frame, ≥ 0).
  final TimeUs at;

  /// The selected lane, if any.
  final TrackId? preferTrack;

  /// Ripple when the target space is occupied (null: `ViewState.rippleEnabled`).
  final bool? ripple;

  @override
  String get label => 'Paste';

  @override
  void _apply(_Draft d) {
    if (payload.isEmpty) d.reject(const InvalidValue('payload'));
    final media = _importMedia(d);
    final sameRate = payload.rate == d.rate;
    final atF = d.frameOf(d.rate.quantizeNearest(at < 0 ? 0 : at));
    final newIds = <ItemId, ItemId>{for (final ci in payload.items) ci.item.id: d.ids.itemId()};
    final newLinks = <LinkId, LinkId>{};
    final groups = <int, List<TimelineItem>>{};
    for (final ci in payload.items) {
      final link = ci.item.link;
      var item = _remapMedia(_withLink(_withId(ci.item, newIds[ci.item.id]!), link == null ? null : newLinks.putIfAbsent(link, d.ids.linkId)), media);
      final offF = d.rate.frameIndexNearest(ci.offset);
      final nF = d.lengthFrames(ci.item.duration);
      item = d.placeAt(item, atF + offF, nF);
      if (!sameRate) item = _requantizeLocal(d, item);
      if (item is MediaClip && !d.sourceFits(item)) {
        final fitted = _shortenToFit(d, item);
        if (fitted == null) d.reject(OutOfSourceRange(item.start));
        item = fitted;
      }
      (groups[ci.lane] ??= <TimelineItem>[]).add(item);
    }
    final transitions = <int, List<Transition>>{};
    for (final ct in payload.transitions) {
      final tr = ct.transition;
      final l = newIds[tr.left];
      final r = newIds[tr.right];
      if (l == null || r == null) continue;
      // Same length in time on another grid (the framework re-clamps it to the clips' limits).
      final n = sameRate ? tr.durationFrames : (tr.durationFrames * d.rate.fps / payload.rate.fps).round();
      (transitions[ct.lane] ??= <Transition>[]).add(
        Transition(id: d.ids.transitionId(), left: l, right: r, kind: tr.kind, durationFrames: n < 1 ? 1 : n, direction: tr.direction),
      );
    }

    // Lanes: the selected lane for the first compatible group, else the first lane of the kind.
    final prefer = preferTrack == null ? null : d.trackOrNull(preferTrack!);
    var preferUsed = false;
    final preferred = <int, TrackId?>{};
    for (final laneIdx in groups.keys) {
      final kind = payload.lanes[laneIdx].kind;
      if (!preferUsed && prefer != null && !prefer.locked && LanePlacement.compatibleKinds(kind, prefer.kind)) {
        preferred[laneIdx] = prefer.id;
        preferUsed = true;
      } else {
        preferred[laneIdx] = null;
      }
    }
    final rippleOn = ripple ?? d.view.rippleEnabled;
    if (rippleOn) {
      // Ripple: each group's lane is fixed up front. The paste position snaps like an insert (the
      // nearest cut on the main lane, out of an item elsewhere, measured on the lane of the
      // earliest item); occupied lanes then open space at the paste range (D-10). A group that
      // still meets an item straddling the opening falls back to D-11.
      final targets = <int, TrackId>{};
      for (final laneIdx in groups.keys) {
        final lane = payload.lanes[laneIdx];
        targets[laneIdx] = preferred[laneIdx] ?? _firstLaneOf(d, lane.kind) ?? d.createTrack(lane.kind, role: lane.role);
      }
      final anchorLane = payload.items.firstWhere((ci) => ci.offset == 0, orElse: () => payload.items.first).lane;
      final pl = d.track(targets[anchorLane]!);
      final at0 = d.timeOf(atF);
      final snap = d.frameOf(pl.isMain ? d.nearestCut(pl, at0) : d.cutAt(pl, at0)) - atF;
      if (snap != 0) {
        for (final e in groups.entries) {
          groups[e.key] = [for (final i in e.value) d.shiftFrames(i, snap)];
        }
      }
      final occupied = groups.entries.any((e) => !LanePlacement.isFree(d.track(targets[e.key]!), [for (final i in e.value) i.range]));
      if (occupied) {
        var minK = 1 << 40;
        var maxK = -(1 << 40);
        for (final g in groups.values) {
          for (final i in g) {
            if (d.frameOf(i.start) < minK) minK = d.frameOf(i.start);
            if (d.frameOf(i.end) > maxK) maxK = d.frameOf(i.end);
          }
        }
        d.openGap({for (final e in groups.entries) targets[e.key]!}, d.timeOf(minK), maxK - minK);
      }
      for (final laneIdx in groups.keys) {
        preferred[laneIdx] = targets[laneIdx];
      }
    }
    final pasted = <ItemId>{};
    for (final e in groups.entries) {
      final lane = payload.lanes[e.key];
      final pref = preferred[e.key];
      final kind = pref == null ? lane.kind : d.track(pref).kind;
      final used = d.placeGroup(e.value, kind: kind, preferred: pref, role: lane.role);
      _addTransitions(d, used, transitions[e.key] ?? const []);
      pasted.addAll(e.value.map((i) => i.id));
    }
    _checkLinksOnDistinctLanes(d, pasted);
    d.selection = SelectionHint(pasted, primary: newIds[payload.items.first.item.id]);
  }

  /// Adds the payload's assets that the pool lacks; returns source id → pool id.
  Map<MediaId, MediaId> _importMedia(_Draft d) {
    final map = <MediaId, MediaId>{};
    var imported = 0;
    final ordered = [
      for (final a in payload.media.values) if (a.derived == null) a,
      for (final a in payload.media.values) if (a.derived != null) a,
    ];
    for (final asset in ordered) {
      final existing = d.pool[asset.id];
      if (existing != null && _sameContent(existing, asset)) {
        map[asset.id] = asset.id;
        continue;
      }
      final match = d.pool.assets.values.firstWhereOrNull((a) => _sameContent(a, asset));
      if (match != null) {
        map[asset.id] = match.id;
        continue;
      }
      final id = existing == null ? asset.id : d.ids.mediaId();
      final derived = switch (asset.derived) {
        ReversedSpec(:final media) && final s => s.copyWith(media: map[media] ?? media),
        StillSpec(:final media) && final s => s.copyWith(media: map[media] ?? media),
        null => null,
      };
      d.pool = d.pool.upsert(asset.copyWith(id: id, derived: derived, addedAt: d.ctx.now));
      map[asset.id] = id;
      imported++;
    }
    if (imported > 0) d.notices.add(EditNotice(EditNoticeCodes.mediaImported, count: imported));
    return map;
  }

  @override
  String toString() => 'PasteItems(${payload.items.length} items, at: $at, preferTrack: $preferTrack, ripple: $ripple)';
}

/// Whether two assets hold the same content (so a paste reuses the pool's asset).
bool _sameContent(MediaAsset a, MediaAsset b) {
  if (a.kind != b.kind) return false;
  final da = a.derived;
  final db = b.derived;
  if (da != null || db != null) {
    return da != null && db != null && da.runtimeType == db.runtimeType && da.specHash == db.specHash;
  }
  return a.fingerprint.quickHash == b.fingerprint.quickHash && a.fingerprint.sizeBytes == b.fingerprint.sizeBytes;
}

/// [item] with its media and imported-LUT references mapped through [media].
TimelineItem _remapMedia(TimelineItem item, Map<MediaId, MediaId> media) {
  if (item is! MediaClip) return item;
  var c = item.copyWith(media: media[item.media] ?? item.media);
  final look = c.visual?.look;
  if (look is ImportedLut) {
    final lut = media[look.lut];
    if (lut != null && lut != look.lut) c = c.copyWith(visual: c.visual!.copyWith(look: look.copyWith(lut: lut)));
  }
  return c;
}

/// The first unlocked lane of [kind], if any.
TrackId? _firstLaneOf(_Draft d, TrackKind kind) {
  for (final t in d.tracks) {
    if (t.kind == kind && !t.locked) return t.id;
  }
  return null;
}

/// [item]'s item-local lengths (keys, fades, text animation lengths) snapped to the nearest
/// frames of the draft's grid (a paste from a project of another frame rate).
TimelineItem _requantizeLocal(_Draft d, TimelineItem item) {
  final rate = d.rate;
  final start = item.start;
  KeyframeSet keys(KeyframeSet set) {
    if (set.isEmpty) return set;
    final out = <String, KeyframeTrack>{};
    for (final e in set.byChannel.entries) {
      final byTime = <TimeUs, double>{};
      for (final k in e.value.keys) {
        byTime[rate.quantizeNearest(start + k.t) - start] = k.v;
      }
      final sorted = byTime.keys.toList()..sort();
      out[e.key] = KeyframeTrack([for (final t in sorted) Keyframe(t, byTime[t]!)]);
    }
    return KeyframeSet(out);
  }

  TimeUs fromStart(TimeUs len) => len <= 0 ? len : rate.quantizeNearest(start + len) - start;
  TimeUs fromEnd(TimeUs len) => len <= 0 ? len : item.end - rate.quantizeNearest(item.end - len);
  return switch (item) {
    MediaClip() => item.copyWith(
        keyframes: keys(item.keyframes),
        audio: item.audio.copyWith(fadeIn: fromStart(item.audio.fadeIn), fadeOut: fromEnd(item.audio.fadeOut)),
      ),
    TextItem() => item.copyWith(
        keyframes: keys(item.keyframes),
        animation: item.animation.copyWith(
          inDuration: fromStart(item.animation.inDuration),
          outDuration: fromEnd(item.animation.outDuration),
        ),
      ),
    SubtitleCue() => item,
  };
}

// -------------------------------------------------------------------------------------------
// ReplaceMedia
// -------------------------------------------------------------------------------------------

/// Replaces a clip's media, keeping its range, effects and keys (domain.md §6.2): `sourceIn` is
/// kept when the new media covers it, else 0; a clip longer than the new media is shortened to
/// fit (notice `trimmedToFit`). Visual lanes take video, images and stills; audio lanes audio,
/// recordings and video with audio. Images and stills play at normal speed, forwards.
final class ReplaceMedia extends EditCommand {
  /// Creates the command.
  const ReplaceMedia(this.item, this.media);

  /// The clip.
  final ItemId item;

  /// The new asset.
  final MediaId media;

  @override
  String get label => 'Replace clip';

  @override
  void _apply(_Draft d) {
    final loc = d.locate(item);
    if (loc.track.locked) d.reject(TrackLocked(loc.track.id));
    final c = loc.item;
    if (c is! MediaClip) d.reject(UnsupportedForKind(c is TextItem ? 'text' : 'subtitle'));
    final asset = d.pool[media];
    if (asset == null || asset.status is FailedStatus) d.reject(MediaUnavailable(media));
    if (!_mediaFitsLane(asset, loc.track.kind)) d.reject(UnsupportedForKind(asset.kind.name));
    final stream = c.audioStream;
    var next = c.copyWith(
      media: media,
      audioStream: stream != null && stream < asset.probe.audioStreams ? stream : null,
    );
    if (!_timeBased(asset.kind)) {
      next = next.copyWith(sourceIn: 0, speed: SpeedSpec.normal, reversed: false);
    } else if (!d.sourceFits(next)) {
      next = next.copyWith(sourceIn: 0);
      if (!d.sourceFits(next)) {
        final fitted = _shortenToFit(d, next);
        if (fitted == null) d.reject(const BelowMinDuration());
        next = fitted;
        d.notices.add(EditNotice(EditNoticeCodes.trimmedToFit, items: {c.id}));
      }
    }
    d.replaceItems([next]);
    d.selection = SelectionHint({c.id}, primary: c.id);
  }

  @override
  String toString() => 'ReplaceMedia($item, $media)';
}

/// [clip] shortened (start, `sourceIn` and speed kept) to the most whole frames whose source fits
/// its media, or null when not even one frame fits.
MediaClip? _shortenToFit(_Draft d, MediaClip clip) {
  final k0 = d.frameOf(clip.start);
  var lo = 0; // fits (0: nothing fits)
  var hi = d.framesOf(clip); // does not fit
  while (hi - lo > 1) {
    final mid = (lo + hi) >> 1;
    if (d.sourceFits(clip.copyWith(duration: d.timeOf(k0 + mid) - clip.start))) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  if (lo < 1 || !d.sourceFits(clip.copyWith(duration: d.timeOf(k0 + lo) - clip.start))) return null;
  return clip.copyWith(duration: d.timeOf(k0 + lo) - clip.start);
}

// -------------------------------------------------------------------------------------------
// ExtractAudio
// -------------------------------------------------------------------------------------------

/// Extracts a video clip's audio (ARCH §6.6): a linked audio clip with the same media, range,
/// speed, direction and audio properties — so both share one `ClipTimeMap` and stay in sync at
/// every frame — on a free lane with `AudioRole.original` (created when needed); the volume keys
/// move to it, and the video clip gets `detachedAudio` (its own audio is no longer rendered).
final class ExtractAudio extends EditCommand {
  /// Creates the command.
  const ExtractAudio(this.item);

  /// The video clip.
  final ItemId item;

  @override
  String get label => 'Extract audio';

  @override
  void _apply(_Draft d) {
    final loc = d.locate(item);
    if (loc.track.locked) d.reject(TrackLocked(loc.track.id));
    final c = loc.item;
    if (c is! MediaClip || c.visual == null) d.reject(UnsupportedForKind(c is MediaClip ? 'audio' : 'text'));
    final asset = d.pool[c.media];
    if (asset == null) d.reject(MediaUnavailable(c.media));
    if (asset.kind != MediaKind.video || !asset.probe.hasAudio) d.reject(const UnsupportedForKind('noAudio'));
    if (c.detachedAudio) d.reject(const UnsupportedForKind('detachedAudio'));

    final link = c.link ?? d.ids.linkId();
    final volume = PropertyKeys.volume.channels.toSet();
    final audioKeys = <String, KeyframeTrack>{};
    final videoKeys = <String, KeyframeTrack>{};
    for (final e in c.keyframes.byChannel.entries) {
      (volume.contains(e.key) ? audioKeys : videoKeys)[e.key] = e.value;
    }
    final audio = MediaClip(
      id: d.ids.itemId(),
      start: c.start,
      duration: c.duration,
      link: link,
      label: c.label,
      media: c.media,
      sourceIn: c.sourceIn,
      speed: c.speed,
      maintainPitch: c.maintainPitch,
      reversed: c.reversed,
      audioStream: c.audioStream,
      audio: c.audio,
      keyframes: audioKeys.isEmpty ? KeyframeSet.empty : KeyframeSet(audioKeys),
    );
    final video = c.copyWith(
      link: link,
      detachedAudio: true,
      keyframes: videoKeys.isEmpty ? KeyframeSet.empty : KeyframeSet(videoKeys),
    );
    d.replaceItems([video]);
    d.placeGroup(
      [audio],
      kind: TrackKind.audio,
      role: AudioRole.original,
      accept: (t) => t.audioRole == AudioRole.original && !t.items.any((i) => i.link == link),
    );
    d.noteLink(link);
    d.selection = SelectionHint({audio.id}, primary: audio.id);
  }

  @override
  String toString() => 'ExtractAudio($item)';
}

// -------------------------------------------------------------------------------------------
// LinkItems, UnlinkItems
// -------------------------------------------------------------------------------------------

/// Links items (and the members of their existing groups) into one new group: they then move,
/// split, delete and duplicate together. Members must be on different lanes (I7).
final class LinkItems extends EditCommand {
  /// Creates the command.
  LinkItems(Set<ItemId> ids) : ids = Set.unmodifiable(ids);

  /// Items to link (at least two).
  final Set<ItemId> ids;

  @override
  String get label => 'Link';

  @override
  void _apply(_Draft d) {
    if (ids.length < 2) d.reject(const InvalidValue('ids'));
    for (final id in ids) {
      d.locate(id);
    }
    final members = d.withPartners(ids);
    final lanes = <TrackId>{};
    final links = <LinkId?>{};
    final items = <TimelineItem>[];
    for (final id in members) {
      final l = d.locate(id);
      if (l.track.locked) d.reject(TrackLocked(l.track.id));
      if (!lanes.add(l.track.id)) d.reject(IncompatibleTrack(l.track.id));
      links.add(l.item.link);
      items.add(l.item);
    }
    if (links.length == 1 && links.first != null) return; // already one group
    final link = d.ids.linkId();
    d.replaceItems([for (final i in items) _withLink(i, link)]);
    d.noteLink(link);
    d.selection = SelectionHint(members, primary: ids.first);
  }

  @override
  String toString() => 'LinkItems($ids)';
}

/// Removes [ids] from their link groups; a group left with one member is dissolved.
final class UnlinkItems extends EditCommand {
  /// Creates the command.
  UnlinkItems(Set<ItemId> ids) : ids = Set.unmodifiable(ids);

  /// Items to unlink.
  final Set<ItemId> ids;

  @override
  String get label => 'Unlink';

  @override
  void _apply(_Draft d) {
    if (ids.isEmpty) d.reject(const InvalidValue('ids'));
    final changed = <TimelineItem>[];
    for (final id in ids) {
      final l = d.locate(id);
      if (l.item.link == null) continue;
      if (l.track.locked) d.reject(TrackLocked(l.track.id));
      changed.add(_withLink(l.item, null));
    }
    if (changed.isEmpty) return;
    d.replaceItems(changed);
  }

  @override
  String toString() => 'UnlinkItems($ids)';
}
