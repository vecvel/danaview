// OWNER: CORE-12
//
// Speed, reverse and freeze-frame commands (ARCH §6.3–6.4, §7.2, domain.md §6.2 and §6.4):
// `SetSpeed`, `SetReversed`, `FreezeFrame`, plus the ramp presets of the speed panel.
//
// **Duration authority (ARCH §6.3).** A clip stores `(sourceIn, duration, speed)`. `SetSpeed` keeps
// the source range and recomputes `duration = max(1 frame, quantizeNearest(T(range)))` with
// `ClipTimeMap.durationFor`; the clip's keys scale by `newDuration / oldDuration` (keys stay on
// their content). Re-timing to the grid changes the derived source end by up to half a frame of
// source, so the source range is pulled back (`sourceIn`) or the clip loses a frame when the media
// would otherwise be overrun (I4).
//
// **Linked audio.** A video clip and its extracted audio share one time map (same media, start,
// duration, source range, speed and direction). `SetSpeed` and `SetReversed` act on every such
// partner so the pair stays in sync at every frame; link partners that do not share the map
// (a freeze-frame still, a different media) are left alone.
//
// **Following items.** With ripple on (the project's ripple setting, or the explicit `ripple`
// argument) the items after the edited clip shift by the duration change, partners following
// (D-10, ripple.dart). With ripple off a slow-down cannot grow into the next item: the clip is
// shortened at the neighbour (content attached, like a tail trim), `EditPreview.clampedTo` reports
// the result and a `trimmedToFit` notice is added.
//
// **Derived media (domain.md §6.4).** `SetReversed` flips the flag and references a reversed
// rendition of the clip's source range in the pool, creating a *pending* `ReversedSpec` asset when
// no usable one exists (the session starts the engine job and updates the asset; undo leaves the
// rendition in the pool, GC reclaims it later). `FreezeFrame` takes a still asset the session
// created beforehand (pending until the engine job finishes).

part of '../edit_command.dart';

/// Notice codes of the reverse command.
abstract final class ReverseNoticeCodes {
  /// A pending reversed rendition was added to the pool: the session must start the engine job
  /// ([EditNotice.count] renditions, [EditNotice.items] the clips that wait for it).
  static const String renditionPending = 'reversePending';
}

/// Source time kept on each side of a clip when its reversed rendition is made, so trimming the
/// clip out afterwards still finds a rendition that covers it (domain.md §6.4).
const TimeUs reverseHandleUs = 2 * microsPerSecond;

/// The job id of a pending asset whose engine job has not been started yet (the session replaces
/// the status with the real job id).
const String unstartedJobId = '';

/// The bundled speed-ramp presets of the speed panel (ux.md §10.3): `montage`, `hero`, `bullet`,
/// `jumpCut`, `flashIn`, `flashOut`. A ramp is speed over the **normalized source position**; each
/// preset keeps `presetId` set, editing a point makes the curve custom (`presetId: null`).
abstract final class SpeedRampPresets {
  /// Slow, fast and slow again, ending at normal speed.
  static const String montage = 'montage';

  /// Fast, a slow-motion hero moment in the middle, fast again.
  static const String hero = 'hero';

  /// Fast with an extreme slow-down in the middle.
  static const String bullet = 'bullet';

  /// Normal speed with a short burst of fast forward.
  static const String jumpCut = 'jumpCut';

  /// Starts very fast and settles to normal speed.
  static const String flashIn = 'flashIn';

  /// Normal speed that accelerates away at the end.
  static const String flashOut = 'flashOut';

  /// Every preset id, in the order of the speed panel.
  static const List<String> ids = [montage, hero, bullet, jumpCut, flashIn, flashOut];

  /// The ramp of preset [id], or null for an unknown id. Every call returns an equal ramp.
  static SpeedRamp? byId(String id) {
    final points = _points[id];
    if (points == null) return null;
    return SpeedRamp([for (final p in points) SpeedPoint(p.$1, p.$2)], presetId: id);
  }

  static const Map<String, List<(double, double)>> _points = {
    montage: [(0, 1), (0.2, 0.3), (0.4, 3), (0.6, 0.3), (0.8, 3), (1, 1)],
    hero: [(0, 1), (0.3, 3), (0.45, 0.3), (0.65, 0.3), (0.8, 3), (1, 1)],
    bullet: [(0, 3), (0.35, 3), (0.5, 0.1), (0.65, 3), (1, 3)],
    jumpCut: [(0, 1), (0.3, 1), (0.35, 6), (0.65, 6), (0.7, 1), (1, 1)],
    flashIn: [(0, 8), (0.2, 1), (1, 1)],
    flashOut: [(0, 1), (0.8, 1), (1, 8)],
  };
}

/// Whether [spec] is a valid speed: a constant rate in [0.1, 10] or a ramp of 2–16 valid points
/// (D-15).
bool _validSpeedSpec(SpeedSpec spec) => switch (spec) {
      ConstantSpeed(:final rate) => rate.isFinite && rate >= minClipSpeed && rate <= maxClipSpeed,
      SpeedRamp() => speedRampIssues(spec).isEmpty,
    };

/// Refuses clips that are not time-based media: images and stills have no speed, reverse or freeze.
void _requireTimeBased(_Draft d, MediaClip clip) {
  final a = d.assetOf(clip);
  if (a == null) d.reject(MediaUnavailable(clip.media));
  if (!_timeBased(a.kind)) d.reject(UnsupportedForKind(a.kind.name));
}

/// [loc] plus its link partners that share its time map (see the file header).
List<_Loc> _syncedTargets(_Draft d, _Loc loc) {
  final main = loc.item as MediaClip;
  final out = <_Loc>[loc];
  for (final pid in d.partnersOf(main)) {
    final p = d.locate(pid);
    final c = p.item;
    if (c is MediaClip &&
        c.media == main.media &&
        c.start == main.start &&
        c.duration == main.duration &&
        c.sourceIn == main.sourceIn &&
        c.speed == main.speed &&
        c.reversed == main.reversed &&
        d.isTimeBased(c)) {
      out.add(p);
    }
  }
  return out;
}

// -------------------------------------------------------------------------------------------
// SetSpeed
// -------------------------------------------------------------------------------------------

/// Sets the speed of a video or audio clip (and its in-sync link partners): a constant rate in
/// [0.1, 10] (presets 0.25 … 4) or a ramp of 2–16 points. Keeps the source range and recomputes the
/// duration; keys scale; see the file header for ripple and clamping.
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind` (images, stills, text, cues),
/// `MediaUnavailable`, `InvalidValue('speed')` (outside [0.1, 10], malformed ramp),
/// `OutOfSourceRange` (nothing of the source fits), `RippleBlockedByLinkedItem` / `WouldOverlap`
/// (ripple).
final class SetSpeed extends EditCommand {
  /// Creates the command. [maintainPitch] null keeps the clip's setting; [ripple] null follows the
  /// project's ripple mode.
  const SetSpeed(this.item, this.spec, {this.maintainPitch, this.ripple});

  /// The clip.
  final ItemId item;

  /// The new speed.
  final SpeedSpec spec;

  /// Keep the audio pitch (time-stretch) instead of varispeed; null keeps the current setting.
  final bool? maintainPitch;

  /// Ripple the following items; null follows `ViewState.rippleEnabled`.
  final bool? ripple;

  @override
  String get label => 'Change speed';

  @override
  void _apply(_Draft d) {
    final loc = d.locate(item);
    final main = loc.item;
    if (main is! MediaClip) d.reject(UnsupportedForKind(main is TextItem ? 'text' : 'subtitle'));
    _requireTimeBased(d, main);
    if (!_validSpeedSpec(spec)) d.reject(const InvalidValue('speed'));
    final targets = _syncedTargets(d, loc);
    for (final t in targets) {
      if (t.track.locked) d.reject(TrackLocked(t.track.id));
    }
    final pitch = maintainPitch ?? main.maintainPitch;
    if (spec == main.speed) {
      d.replaceItems([
        for (final t in targets)
          if ((t.item as MediaClip).maintainPitch != pitch) (t.item as MediaClip).copyWith(maintainPitch: pitch),
      ]);
      return;
    }

    final asset = d.assetOf(main)!;
    final k0 = d.frameOf(main.start);
    final oldFrames = d.framesOf(main);
    var n = d.frameOf(ClipTimeMap.durationFor(main.sourceRange, spec, d.rate));
    List<MediaClip>? built;
    for (; n >= 1; n--) {
      built = _respeed(d, targets, asset, k0, n, pitch);
      if (built != null) break;
    }
    if (built == null) d.reject(const OutOfSourceRange());

    // Without ripple the clip cannot grow into the next item: shorten it at the neighbour.
    final doRipple = ripple ?? d.view.rippleEnabled;
    var frames = n;
    var clamped = false;
    if (!doRipple && n > oldFrames) {
      int? cap;
      for (final t in targets) {
        final next = t.itemIndex + 1 < t.track.items.length ? t.track.items[t.itemIndex + 1] : null;
        if (next == null) continue;
        final room = d.frameOf(next.start) - k0;
        if (cap == null || room < cap) cap = room;
      }
      if (cap != null && n > cap) {
        frames = cap;
        clamped = true;
        built = [for (final c in built) d.trimEnd(c, d.timeOf(k0 + frames)) as MediaClip];
      }
    }

    final delta = frames - oldFrames;
    if (doRipple && delta != 0) {
      final points = [for (final t in targets) (lane: t.track.id, at: t.item.end, frames: delta)];
      if (delta < 0) {
        d.replaceItems(built);
        d.ripple(points);
      } else {
        d.ripple(points);
        d.replaceItems(built);
      }
    } else {
      d.replaceItems(built);
    }
    if (clamped) {
      d.clampedTo = d.locate(item).item.range;
      d.notices.add(EditNotice(EditNoticeCodes.trimmedToFit, items: {for (final c in built) c.id}));
    }
  }

  /// The targets with speed [spec] over [n] frames from frame [k0]; null when the source range
  /// cannot be kept inside the media.
  List<MediaClip>? _respeed(_Draft d, List<_Loc> targets, MediaAsset asset, int k0, int n, bool pitch) {
    final dur = d.timeOf(k0 + n) - d.timeOf(k0);
    final out = <MediaClip>[];
    for (final t in targets) {
      final c = t.item as MediaClip;
      var sourceIn = c.sourceIn;
      final over = sourceIn + ClipTimeMap.sourceLengthOf(dur, spec) - asset.probe.duration;
      if (over > 0) {
        if (over > sourceIn) return null;
        sourceIn -= over;
      }
      out.add(c.copyWith(
        speed: spec,
        maintainPitch: pitch,
        duration: dur,
        sourceIn: sourceIn,
        keyframes:
            KeyframeOps.scale(c.keyframes, oldDuration: c.duration, newDuration: dur, rate: d.rate, itemStart: c.start),
      ));
    }
    return out;
  }

  @override
  String toString() => 'SetSpeed($item, $spec, maintainPitch: $maintainPitch, ripple: $ripple)';
}

// -------------------------------------------------------------------------------------------
// SetReversed
// -------------------------------------------------------------------------------------------

/// Plays a clip (and its in-sync link partners) backwards or forwards again. Only the flag flips
/// (range, speed, fades and keys stay); turning reverse **on** also references a reversed rendition
/// of the source range in the pool and adds a pending `ReversedSpec` asset when none covers it
/// (`reversePending` notice). Reverse twice is the original clip.
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind` (images, stills, text, cues),
/// `MediaUnavailable`.
final class SetReversed extends EditCommand {
  /// Creates the command.
  const SetReversed(this.item, this.on);

  /// The clip.
  final ItemId item;

  /// Reversed on or off.
  final bool on;

  @override
  String get label => on ? 'Reverse' : 'Play forward';

  @override
  void _apply(_Draft d) {
    final loc = d.locate(item);
    final main = loc.item;
    if (main is! MediaClip) d.reject(UnsupportedForKind(main is TextItem ? 'text' : 'subtitle'));
    _requireTimeBased(d, main);
    final targets = _syncedTargets(d, loc);
    for (final t in targets) {
      if (t.track.locked) d.reject(TrackLocked(t.track.id));
    }
    if (main.reversed == on) return;
    if (on) _ensureRendition(d, main, {for (final t in targets) t.item.id});
    d.replaceItems([for (final t in targets) (t.item as MediaClip).copyWith(reversed: on)]);
  }

  /// Makes sure a reversed rendition covering [clip]'s source range exists in the draft pool.
  void _ensureRendition(_Draft d, MediaClip clip, Set<ItemId> waiting) {
    final source = d.assetOf(clip)!;
    final range = clip.sourceRange;
    final quick = source.fingerprint.quickHash;
    MediaAsset? failedSame;
    final wanted = _handleRange(range, source.probe.duration);
    for (final a in d.pool.assets.values) {
      final spec = a.derived;
      if (spec is! ReversedSpec || spec.media != clip.media || spec.sourceQuickHash != quick) continue;
      if (a.status is FailedStatus) {
        if (spec.range == wanted) failedSame = a;
        continue;
      }
      if (spec.range.start <= range.start && spec.range.end >= range.end) return;
    }
    if (failedSame != null) {
      d.pool = d.pool.upsert(failedSame.copyWith(status: const PendingStatus(unstartedJobId)));
    } else {
      final spec = ReversedSpec(clip.media, wanted, sourceQuickHash: quick);
      final id = d.ids.mediaId();
      d.pool = d.pool.upsert(MediaAsset(
        id: id,
        kind: source.kind,
        displayName: '${source.displayName} (reversed)',
        locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/derived/${spec.specHash}.mp4'),
        ownership: MediaOwnership.projectOwned,
        fingerprint: MediaFingerprint(sizeBytes: 0, quickHash: '', duration: wanted.duration),
        probe: source.probe.copyWith(duration: wanted.duration, issues: const [], sizeBytes: 0),
        origin: MediaOrigin.derived,
        derived: spec,
        status: const PendingStatus(unstartedJobId),
        addedAt: d.ctx.now,
      ));
    }
    d.notices.add(EditNotice(ReverseNoticeCodes.renditionPending, items: waiting, count: 1));
  }

  /// [range] widened by the rendition handles and limited to the media.
  static TimeRange _handleRange(TimeRange range, TimeUs mediaDuration) {
    final s = range.start - reverseHandleUs;
    final e = range.end + reverseHandleUs;
    return TimeRange(s < 0 ? 0 : s, e > mediaDuration ? mediaDuration : e);
  }

  @override
  String toString() => 'SetReversed($item, $on)';
}

// -------------------------------------------------------------------------------------------
// FreezeFrame
// -------------------------------------------------------------------------------------------

/// Freezes the frame under [at]: splits the clip there (link partners split too) and inserts a still
/// of [duration] at the cut with ripple on the edited lane (domain.md §6.4); later items shift
/// right by the still's length and linked partners follow (D-10). [at] at the clip's first frame
/// inserts the still before the clip without splitting.
///
/// [stillMedia] is the pool asset the session created beforehand as a pending `StillSpec`
/// asset of the clip's media (`FreezeFrame.sourceTimeAt` gives the source time to freeze). The
/// still copies the clip's visual properties with keyframed values baked at the cut and has no
/// audio.
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind` (audio clips, images, stills,
/// text, cues), `NothingAtTime` (`at` is not inside the clip), `InvalidValue('duration')`,
/// `InvalidValue('stillMedia')` (the still is derived from other media), `MediaUnavailable`
/// (missing or failed still) and the ripple rejections.
final class FreezeFrame extends EditCommand {
  /// Creates the command.
  const FreezeFrame(this.item, this.at, this.duration, this.stillMedia);

  /// The video clip.
  final ItemId item;

  /// The time to freeze (floored to its frame start).
  final TimeUs at;

  /// Length of the still (quantized to whole frames, at least one).
  final TimeUs duration;

  /// The pending still asset the session made for this freeze.
  final MediaId stillMedia;

  @override
  String get label => 'Freeze frame';

  /// The source time the frame at timeline time [at] shows: what the session freezes into the
  /// still (`StillSpec.sourceTime`). [at] is floored to its frame start and limited to the clip.
  static TimeUs sourceTimeAt(MediaClip clip, TimeUs at, FrameRate rate) {
    final t = rate.quantize(at);
    final clamped = t < clip.start ? clip.start : (t >= clip.end ? clip.end - 1 : t);
    return ClipTimeMap.forClip(clip, rate).toSource(clamped);
  }

  @override
  void _apply(_Draft d) {
    final loc = d.locate(item);
    final clip = loc.item;
    if (clip is! MediaClip) d.reject(UnsupportedForKind(clip is TextItem ? 'text' : 'subtitle'));
    final source = d.assetOf(clip);
    if (source == null) d.reject(MediaUnavailable(clip.media));
    if (source.kind != MediaKind.video) d.reject(UnsupportedForKind(source.kind.name));
    if (clip.visual == null) d.reject(const UnsupportedForKind('audio'));
    final still = d.pool[stillMedia];
    if (still == null || still.kind != MediaKind.still || still.status is FailedStatus) {
      d.reject(MediaUnavailable(stillMedia));
    }
    final spec = still.derived;
    if (spec is StillSpec && spec.media != clip.media) d.reject(const InvalidValue('stillMedia'));
    if (duration <= 0) d.reject(const InvalidValue('duration'));
    final t = d.rate.quantize(at);
    if (t < clip.start || t >= clip.end) d.reject(NothingAtTime(t));
    d.editableTrack(loc.track.id);

    final baked = _bake(clip, t - clip.start);
    if (t > clip.start) SplitItems({item}, t)._apply(d);
    final laneId = loc.track.id;
    final frames = d.lengthFrames(duration);
    d.openGap([laneId], t, frames);
    final k = d.frameOf(t);
    final freeze = MediaClip(
      id: d.ids.itemId(),
      start: t,
      duration: d.timeOf(k + frames) - t,
      media: stillMedia,
      visual: baked.visual,
    );
    d.addItems(laneId, [freeze]);
    d.selection = SelectionHint({freeze.id}, primary: freeze.id, lane: laneId);
  }

  /// [clip] with every keyframed property written as the static value at item-local [local] and
  /// the keys removed (the still has no animation of its own).
  static MediaClip _bake(MediaClip clip, TimeUs local) {
    var out = clip;
    for (final key in PropertyKeys.keyframable) {
      if (!key.appliesToItem(clip) || !KeyframeOps.isAnimated(clip.keyframes, key)) continue;
      if (key.appliesTo.contains(ItemKindTag.audioClip)) continue;
      out = key.write(out, evaluate<Object?>(clip, key, local)) as MediaClip;
    }
    return out.copyWith(keyframes: KeyframeSet.empty);
  }

  @override
  String toString() => 'FreezeFrame($item, $at, $duration, $stillMedia)';
}
