// OWNER: CORE-34
//
// The action generator of the model fuzzer: one random session action per step, drawn from a
// `Choices` stream against the current project.
//
// Actions are `apply` of a command from every command group (clips, clipboard, speed,
// properties, keyframes, text, subtitles, captions, transitions, tracks, markers, project,
// composites and raw framework edits), undo, redo, jump, transactions (gestures that commit,
// cancel or stay open), undoable pool edits (relink, remove), sticky pool changes (engine
// job updates, imports), view toggles and full history walks.
//
// Targets are mostly valid: existing items, real cuts, existing keys, item edges and gaps.
// Sometimes they are not (unknown ids, odd times, out-of-range values), so rejections are
// exercised too.

import 'dart:math' as math;

import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';

import 'fuzz_choices.dart';

// ---------------------------------------------------------------------------------------------
// Actions.
// ---------------------------------------------------------------------------------------------

/// What the fuzzer does in one step.
sealed class FuzzAction {
  const FuzzAction();

  /// A one-line description for failure reports (no user content beyond the fuzz samples).
  String describe();
}

/// What the runner expects from an [ApplyAction].
enum ApplyExpectation {
  /// Any outcome except `InternalInconsistency`.
  normal,

  /// A deliberately invalid raw edit: the post-step validation must refuse it with
  /// `InternalInconsistency` and leave the project unchanged.
  internalInconsistency,
}

/// `session.apply(command)`, after the sticky pool changes in [before] (e.g. the pending still
/// a freeze needs).
final class ApplyAction extends FuzzAction {
  /// Creates the action.
  const ApplyAction(this.command, {this.coalesceKey, this.before = const [], this.expect = ApplyExpectation.normal});

  /// The command.
  final EditCommand command;

  /// The coalescing key passed to `apply` (typing), or null.
  final String? coalesceKey;

  /// Sticky pool changes applied first.
  final List<PoolChange> before;

  /// The expected kind of outcome.
  final ApplyExpectation expect;

  @override
  String describe() => 'apply $command${coalesceKey == null ? '' : ' (coalesce $coalesceKey)'}'
      '${before.isEmpty ? '' : ' after ${before.length} pool change(s)'}';
}

/// `session.undo()`.
final class UndoAction extends FuzzAction {
  /// Creates the action.
  const UndoAction();

  @override
  String describe() => 'undo';
}

/// `session.redo()`.
final class RedoAction extends FuzzAction {
  /// Creates the action.
  const RedoAction();

  @override
  String describe() => 'redo';
}

/// `session.jump(steps)`.
final class JumpAction extends FuzzAction {
  /// Creates the action.
  const JumpAction(this.steps);

  /// Entries to move (negative: back).
  final int steps;

  @override
  String describe() => 'jump $steps';
}

/// How a [TransactionAction] ends.
enum TransactionEnd {
  /// `commit()`.
  commit,

  /// `cancel()`.
  cancel,

  /// Left open: the next step's action (or the end of the run) closes it.
  leaveOpen,
}

/// `begin`, one `update` per command, then [end].
final class TransactionAction extends FuzzAction {
  /// Creates the action.
  const TransactionAction(this.updates, this.end);

  /// The gesture's successive commands.
  final List<EditCommand> updates;

  /// How the transaction ends.
  final TransactionEnd end;

  @override
  String describe() => 'transaction ${end.name} $updates';
}

/// `session.applyPoolEdit(edit, adjust: adjust)`.
final class PoolEditAction extends FuzzAction {
  /// Creates the action.
  const PoolEditAction(this.edit, {this.adjust});

  /// The undoable pool edit.
  final PoolEdit edit;

  /// The command run in the same entry, or null.
  final EditCommand? adjust;

  @override
  String describe() => switch (edit) {
        RelinkAssets(:final replacements) => 'relink ${replacements.keys.toList()}${adjust == null ? '' : ' + $adjust'}',
        RemoveAssets(:final ids) => 'remove assets ${ids.toList()}',
      };
}

/// `session.applyPoolChange(change)` (sticky: imports and engine job updates).
final class PoolChangeAction extends FuzzAction {
  /// Creates the action.
  const PoolChangeAction(this.change);

  /// The change.
  final PoolChange change;

  @override
  String describe() => switch (change) {
        AddAssets(:final assets) => 'import ${[for (final a in assets) a.id]}',
        UpdateAsset(:final asset) => 'update asset ${asset.id} status ${asset.status.runtimeType}',
      };
}

/// `session.updateView(...)`: ripple and snapping toggles, playhead.
final class ViewAction extends FuzzAction {
  /// Creates the action.
  const ViewAction({this.ripple, this.snapping, this.playhead});

  /// New ripple mode, or null.
  final bool? ripple;

  /// New snapping mode, or null.
  final bool? snapping;

  /// New playhead, or null.
  final TimeUs? playhead;

  /// The update for `session.updateView`.
  ViewState apply(ViewState v) => v.copyWith(rippleEnabled: ripple, snappingEnabled: snapping, playhead: playhead);

  @override
  String describe() => 'view ripple=$ripple snapping=$snapping playhead=$playhead';
}

/// Undo every entry, then redo every entry, checking each position against the model.
final class HistoryWalkAction extends FuzzAction {
  /// Creates the action.
  const HistoryWalkAction();

  @override
  String describe() => 'history walk';
}

// ---------------------------------------------------------------------------------------------
// Generator.
// ---------------------------------------------------------------------------------------------

/// Samples for text items, cues and names (scripts, emoji, combining marks, line breaks).
const List<String> fuzzTexts = [
  'Hello',
  'Two\nlines',
  'Crème brûlée',
  '東京タワー',
  'مرحبا',
  '👨‍👩‍👧‍👦 family',
  'नमस्ते',
  '<i>markup</i> here',
  '  padded  ',
  'A much longer caption line that keeps going past the space-join limit of forty-two graphemes',
];

/// Builtin look preset ids the fuzz resolver knows (plus one it does not).
const List<String> fuzzLookPresets = ['tealOrange', 'warm', 'mono', 'noSuchLook'];

/// Draws random [FuzzAction]s. Deterministic for a given choice stream, project and history of
/// calls (the only state is a counter for the media ids it mints).
final class ActionGenerator {
  /// Creates a generator. [foreign] returns a project to copy from for cross-project pastes.
  ActionGenerator({required this.foreign});

  /// Another project (by index 0..2) for cross-project pastes.
  final EditProject Function(int index) foreign;

  int _minted = 0;

  MediaId _newMediaId() => MediaId('md_Fg${base62(_minted++, 10)}');

  /// The next action for [p]. [txOpen] tells whether a transaction is open (only a few actions
  /// keep it open).
  FuzzAction next(EditProject p, Choices c) {
    final g = _Step(this, p, c);
    return switch (c.weighted(const [760, 70, 40, 20, 50, 15, 15, 15, 5])) {
      0 => g.apply(),
      1 => const UndoAction(),
      2 => const RedoAction(),
      3 => JumpAction(c.below(9) - 4),
      4 => g.transaction(),
      5 => g.poolEdit(),
      6 => g.poolChange(),
      7 => ViewAction(
          ripple: c.chance(1, 2) ? c.flip() : null,
          snapping: c.chance(1, 3) ? c.flip() : null,
          playhead: c.chance(1, 2) ? g.time() : null,
        ),
      _ => const HistoryWalkAction(),
    };
  }

  /// A random command for [p] (no pool changes needed): used for transactions and composites.
  EditCommand command(EditProject p, Choices c) => _Step(this, p, c).command(allowComposite: false);
}

/// Per-step helper: the project's targets and the drawing helpers.
final class _Step {
  _Step(this.gen, this.p, this.c)
      : rate = p.settings.frameRate,
        tracks = p.tracks,
        items = [for (final t in p.tracks) ...t.items];

  final ActionGenerator gen;
  final EditProject p;
  final Choices c;
  final FrameRate rate;
  final List<Track> tracks;
  final List<TimelineItem> items;

  late final List<MediaClip> clips = [for (final i in items) if (i is MediaClip) i];
  late final List<MediaClip> visualClips = [for (final i in clips) if (i.visual != null) i];
  late final List<TextItem> texts = [for (final i in items) if (i is TextItem) i];
  late final List<SubtitleCue> cues = [for (final i in items) if (i is SubtitleCue) i];
  late final List<TimelineItem> keyed = [for (final i in items) if (i is! SubtitleCue && !keyframesOf(i).isEmpty) i];
  late final List<MediaId> media = p.pool.assets.keys.toList();

  static const ItemId unknownItem = ItemId('it_FzUnknown00');
  static const TrackId unknownTrack = TrackId('tr_FzUnknown00');
  static const MediaId unknownMedia = MediaId('md_FzUnknown00');

  // ----- basic draws -----

  T? maybe<T>(T Function() f, {int num = 1, int den = 2}) => c.chance(num, den) ? f() : null;

  TimeUs get end => p.duration;

  /// A frame time near the project (mostly on the grid; sometimes an item edge, off-grid, negative
  /// or far away).
  TimeUs time() {
    switch (c.weighted(const [55, 25, 10, 5, 3, 2])) {
      case 0:
        final frames = rate.frameIndexOf(end <= 0 ? 10 * microsPerSecond : end) + rate.num;
        return rate.timeOfFrame(c.below(frames + 1));
      case 1:
        if (items.isEmpty) return 0;
        final i = c.pick(items);
        return c.flip() ? i.end : i.start;
      case 2:
        return c.below(math.max(end, microsPerSecond) + microsPerSecond);
      case 3:
        return 0;
      case 4:
        return -c.below(3 * microsPerSecond) - 1;
      default:
        return maxProjectDurationUs - c.below(10 * microsPerSecond);
    }
  }

  /// A time inside [item] (on the grid most of the time).
  TimeUs timeIn(TimelineItem item) {
    final k0 = rate.frameIndexOf(item.start);
    final k1 = rate.frameIndexOf(item.end);
    if (c.chance(1, 8)) return item.start + c.below(math.max(1, item.duration));
    return rate.timeOfFrame(k0 + c.below(math.max(1, k1 - k0)));
  }

  /// A signed delta: whole frames most of the time.
  TimeUs delta() {
    final sign = c.flip() ? -1 : 1;
    if (c.chance(1, 6)) return sign * c.below(3 * microsPerSecond);
    return sign * rate.timeOfFrame(c.below(4 * rate.num));
  }

  /// A duration (sometimes zero or negative).
  TimeUs length() => switch (c.weighted(const [70, 20, 5, 5])) {
        0 => rate.timeOfFrame(1 + c.below(5 * rate.num)),
        1 => c.below(4 * microsPerSecond),
        2 => 0,
        _ => -c.below(microsPerSecond) - 1,
      };

  ItemId item([List<TimelineItem>? from]) {
    final pool = from ?? items;
    if (pool.isEmpty || c.chance(1, 25)) return unknownItem;
    return c.pick(pool).id;
  }

  Set<ItemId> itemSet([List<TimelineItem>? from]) => {for (var i = 0; i < 1 + c.below(3); i++) item(from)};

  /// Items close in time to a random anchor (realistic multi-selections).
  Set<ItemId> nearbySet() {
    if (items.isEmpty) return {unknownItem};
    final anchor = c.pick(items);
    final near = [for (final i in items) if ((i.start - anchor.start).abs() < 5 * microsPerSecond) i];
    return {anchor.id, for (var i = 0; i < c.below(3); i++) c.pick(near).id};
  }

  TrackId lane([bool Function(Track t)? where]) {
    final pool = where == null ? tracks : tracks.where(where).toList();
    if (pool.isEmpty || c.chance(1, 30)) return unknownTrack;
    return c.pick(pool).id;
  }

  TrackId? laneOrNull([bool Function(Track t)? where]) => c.chance(1, 3) ? null : lane(where);

  MediaId mediaOf(bool Function(MediaAsset a) where) {
    final pool = [for (final a in p.pool.assets.values) if (where(a)) a.id];
    if (pool.isEmpty || c.chance(1, 20)) return media.isEmpty || c.flip() ? unknownMedia : c.pick(media);
    return c.pick(pool);
  }

  String text() => c.chance(1, 12) ? (c.flip() ? '' : '   ') : c.pick(fuzzTexts);

  int color() => (0xFF << 24) | c.below(1 << 24);

  double inRange(PropertyKey<Object?> k) {
    if (c.chance(1, 40)) return c.flip() ? k.max + 1 + c.below(10) : double.nan;
    return c.between(k.min, k.max);
  }

  Vec2 vecIn(PropertyKey<Object?> k) => Vec2(c.between(k.min, k.max), c.between(k.min, k.max));

  // ----- actions -----

  FuzzAction apply() {
    final group = c.weighted(const [26, 12, 9, 12, 9, 8, 11, 3, 6, 7, 4, 3, 3, 2]);
    switch (group) {
      case 2:
        if (c.chance(1, 3)) return freeze();
        return ApplyAction(speed());
      case 6:
        final cmd = subtitle();
        final key = cmd is SetCueText && c.chance(2, 3) ? SetCueText.coalesceKey(cmd.cue) : null;
        return ApplyAction(cmd, coalesceKey: key);
      case 5:
        final cmd = textCommand();
        final key = cmd is SetText && c.chance(2, 3) ? cmd.coalesceKey : null;
        return ApplyAction(cmd, coalesceKey: key);
      case 13:
        return raw();
      default:
        return ApplyAction(command(group: group));
    }
  }

  EditCommand command({int? group, bool allowComposite = true}) {
    final g = group ?? c.weighted(const [26, 12, 9, 12, 9, 8, 11, 3, 6, 7, 4, 3, 3]);
    return switch (g) {
      0 => clip(),
      1 => clipboard(),
      2 => speed(),
      3 => property(),
      4 => keyframe(),
      5 => textCommand(),
      6 => subtitle(),
      7 => caption(),
      8 => transition(),
      9 => track(),
      10 => marker(),
      11 => project(),
      _ => allowComposite ? composite() : clip(),
    };
  }

  // ----- CORE-10 clips -----

  EditCommand clip() {
    switch (c.weighted(const [14, 22, 18, 16, 12, 8])) {
      case 0:
        final n = 1 + c.below(2);
        return InsertMedia(
          [for (var i = 0; i < n; i++) mediaOf((a) => a.kind != MediaKind.lut && a.derived == null)],
          time(),
          track: laneOrNull(),
          mode: c.pick(InsertMode.values),
        );
      case 1:
        return MoveItems(c.chance(2, 3) ? nearbySet() : itemSet(), delta(),
            toTrack: c.chance(1, 3) ? lane() : null, ripple: c.flip(), clamp: c.flip());
      case 2:
        if (items.isEmpty) return TrimItem(unknownItem, TrimEdge.start, time());
        final target = c.pick(items);
        final edge = c.flip() ? TrimEdge.end : TrimEdge.start;
        final at = (edge == TrimEdge.start ? target.start : target.end) + delta();
        return TrimItem(c.chance(1, 25) ? unknownItem : target.id, edge, c.chance(1, 10) ? time() : at,
            ripple: c.flip(), clamp: c.flip());
      case 3:
        if (items.isEmpty || c.chance(1, 6)) return SplitItems(c.flip() ? const {} : itemSet(), time());
        final target = c.pick(items);
        return SplitItems(c.chance(1, 3) ? const {} : {target.id, if (c.chance(1, 4)) item()}, timeIn(target));
      case 4:
        return DeleteItems(c.chance(1, 2) ? {item()} : nearbySet(), ripple: c.flip());
      default:
        return DeleteGap(gap());
    }
  }

  GapRef gap() {
    final lanes = [for (final t in tracks) if (t.items.isNotEmpty) t];
    if (lanes.isEmpty || c.chance(1, 8)) {
      final t0 = time();
      return GapRef(lane(), TimeRange(t0, t0 + c.below(2 * microsPerSecond)));
    }
    final t = c.pick(lanes);
    final gaps = <TimeRange>[
      if (t.items.first.start > 0) TimeRange(0, t.items.first.start),
      for (var i = 0; i + 1 < t.items.length; i++)
        if (t.items[i].end < t.items[i + 1].start) TimeRange(t.items[i].end, t.items[i + 1].start),
    ];
    if (gaps.isEmpty) return GapRef(t.id, TimeRange(t.items.last.end, t.items.last.end + rate.timeOfFrame(1 + c.below(30))));
    final g = c.pick(gaps);
    if (c.chance(1, 4)) {
      final cut = g.start + c.below(math.max(1, g.end - g.start));
      return GapRef(t.id, TimeRange(rate.quantize(cut) < g.start ? g.start : rate.quantize(cut), g.end));
    }
    return GapRef(t.id, g);
  }

  // ----- CORE-11 clipboard and links -----

  EditCommand clipboard() {
    switch (c.weighted(const [20, 26, 12, 12, 10, 10, 10])) {
      case 0:
        return DuplicateItems(c.flip() ? {item()} : nearbySet(), ripple: c.chance(1, 2) ? c.flip() : null);
      case 1:
        final source = c.chance(1, 4) ? gen.foreign(c.below(3)) : p;
        final sourceItems = [for (final t in source.tracks) ...t.items];
        final picked = sourceItems.isEmpty
            ? <ItemId>{}
            : {for (var i = 0; i < 1 + c.below(3); i++) c.pick(sourceItems).id};
        return PasteItems(copyItems(source, picked), time(),
            preferTrack: c.chance(1, 2) ? lane() : null, ripple: c.chance(1, 2) ? c.flip() : null);
      case 2:
        final target = item(clips.isEmpty ? null : clips);
        return ReplaceMedia(target, mediaOf((a) => a.kind != MediaKind.lut));
      case 3:
        return ExtractAudio(item(visualClips.isEmpty ? null : visualClips));
      case 4:
        final a = item();
        final b = item();
        return LinkItems({a, b, if (c.chance(1, 4)) item()});
      case 5:
        return UnlinkItems(itemSet());
      default:
        return cutItems(p, nearbySet(), ripple: c.flip()).command;
    }
  }

  // ----- CORE-12 speed -----

  EditCommand speed() {
    if (c.chance(1, 3)) return SetReversed(item(clips.isEmpty ? null : clips), c.chance(2, 3));
    final SpeedSpec spec = switch (c.weighted(const [40, 20, 20, 15, 5])) {
      0 => ConstantSpeed(c.pick(speedPresets)),
      1 => ConstantSpeed(0.1 + c.unit() * 9.9),
      2 => SpeedRampPresets.byId(c.pick(SpeedRampPresets.ids))!,
      3 => SpeedRamp([
          const SpeedPoint(0, 1),
          for (var i = 1; i < 1 + c.below(4); i++) SpeedPoint(i / 5, 0.1 + c.unit() * 9.9),
          SpeedPoint(1, 0.1 + c.unit() * 3),
        ]),
      _ => ConstantSpeed(c.flip() ? 0 : 50),
    };
    return SetSpeed(item(clips.isEmpty ? null : clips), spec,
        maintainPitch: c.chance(1, 2) ? c.flip() : null, ripple: c.chance(1, 2) ? c.flip() : null);
  }

  /// A freeze of a visual clip, with the pending still the session makes first.
  FuzzAction freeze() {
    if (visualClips.isEmpty) return ApplyAction(FreezeFrame(unknownItem, time(), length(), unknownMedia));
    final target = c.pick(visualClips);
    final at = c.chance(1, 8) ? time() : timeIn(target);
    final source = p.pool[target.media];
    final duration = c.chance(1, 10) ? length() : rate.timeOfFrame(1 + c.below(3 * rate.num));
    if (source == null || source.kind != MediaKind.video || c.chance(1, 15)) {
      return ApplyAction(FreezeFrame(target.id, at, duration, c.flip() ? unknownMedia : mediaOf((a) => true)));
    }
    final id = gen._newMediaId();
    final spec = StillSpec(target.media, FreezeFrame.sourceTimeAt(target, at, rate), sourceQuickHash: source.fingerprint.quickHash);
    final still = MediaAsset(
      id: id,
      kind: MediaKind.still,
      displayName: '${source.displayName} (still)',
      locator: AppRelativeLocator(AppRoot.support, 'vwish/editor/derived/${spec.specHash}.png'),
      ownership: MediaOwnership.projectOwned,
      fingerprint: const MediaFingerprint(sizeBytes: 0, quickHash: ''),
      probe: MediaProbe(kind: MediaKind.still, hasVideo: true, width: source.probe.width, height: source.probe.height),
      origin: MediaOrigin.derived,
      derived: spec,
      status: c.chance(1, 10) ? const FailedStatus('decode') : PendingStatus('job_$id'),
      addedAt: DateTime.utc(2026, 10, 10),
    );
    return ApplyAction(FreezeFrame(target.id, at, duration, id), before: [AddAssets([still])]);
  }

  // ----- CORE-13 properties -----

  List<ItemId> targets(List<TimelineItem> preferred) {
    final from = preferred.isEmpty || c.chance(1, 10) ? items : preferred;
    return [item(from), if (c.chance(1, 4)) item(from)];
  }

  Object? valueFor(PropertyKey<Object?> k) => switch (k.valueKind) {
        PropertyValueKind.number => inRange(k),
        PropertyValueKind.vec2 => c.chance(1, 30) ? Vec2(k.max + 1, k.min) : vecIn(k),
        PropertyValueKind.toggle => c.flip(),
        PropertyValueKind.color => color(),
        PropertyValueKind.duration => c.below(3 * microsPerSecond),
        PropertyValueKind.text => c.pick(const ['figtree', 'inter', 'playfair', 'noSuchFont', '']),
        PropertyValueKind.rect => crop(),
        PropertyValueKind.choice => switch (k.id) {
            'visual.fit' => c.pick(FitMode.values),
            'mask.shape' => c.pick(MaskShape.values),
            'text.align' => c.pick(TextAlignH.values),
            _ => k.defaultValue,
          },
      };

  CropRect crop() {
    if (c.chance(1, 20)) return const CropRect(left: 0.6, right: 0.4);
    final l = c.between(0, 0.4), t = c.between(0, 0.4);
    return CropRect(left: l, top: t, right: c.between(l + 0.1, 1), bottom: c.between(t + 0.1, 1));
  }

  VisualProps visual(VisualProps base) => base.copyWith(
        transform: Transform2D(
          position: c.chance(1, 2) ? vecIn(PropertyKeys.position) : Vec2.zero,
          scale: c.chance(1, 2) ? inRange(PropertyKeys.scale) : 1,
          rotationDeg: c.chance(1, 3) ? inRange(PropertyKeys.rotation) : 0,
          flipH: c.chance(1, 5),
          flipV: c.chance(1, 8),
          opacity: c.chance(1, 3) ? inRange(PropertyKeys.opacity) : 1,
        ),
        fit: c.pick(FitMode.values),
        crop: c.chance(1, 3) ? crop() : CropRect.full,
        adjust: c.chance(1, 3) ? ColorAdjust(exposure: inRange(PropertyKeys.exposure), saturation: inRange(PropertyKeys.saturation)) : ColorAdjust.neutral,
        detail: c.chance(1, 4) ? DetailFx(blur: inRange(PropertyKeys.blur), vignette: inRange(PropertyKeys.vignette)) : DetailFx.none,
      );

  LookRef? look() => switch (c.weighted(const [3, 4, 2])) {
        0 => null,
        1 => BuiltinLook(c.pick(fuzzLookPresets), intensity: inRange(PropertyKeys.lookIntensity)),
        _ => ImportedLut(mediaOf((a) => a.kind == MediaKind.lut), intensity: inRange(PropertyKeys.lookIntensity)),
      };

  EditCommand property() {
    switch (c.weighted(const [40, 10, 10, 8, 6, 8, 8, 6])) {
      case 0:
        final target = items.isEmpty || c.chance(1, 20) ? null : c.pick(items);
        final keys = target == null ? PropertyKeys.all : PropertyKeys.forItem(target);
        final k = keys.isEmpty || c.chance(1, 20) ? c.pick(PropertyKeys.all) : c.pick(keys);
        final at = target == null ? time() : (c.chance(1, 10) ? time() : timeIn(target));
        return SetProperty<Object?>([target?.id ?? unknownItem, if (c.chance(1, 5)) item()], k, valueFor(k),
            at: k.keyframable || c.chance(1, 5) ? (c.chance(1, 12) ? null : at) : null);
      case 1:
        final ids = targets(visualClips);
        final first = p.index.item(ids.first);
        final base = (first is MediaClip ? first.visual : null) ?? VisualProps.neutral;
        return SetVisual(ids, visual(base));
      case 2:
        return SetAudio(targets(clips), AudioProps(
          volume: c.chance(1, 30) ? 3 : inRange(PropertyKeys.volume),
          muted: c.chance(1, 6),
          fadeIn: c.chance(1, 3) ? c.below(2 * microsPerSecond) : 0,
          fadeOut: c.chance(1, 3) ? c.below(2 * microsPerSecond) : 0,
        ));
      case 3:
        return SetLook(targets(visualClips), look());
      case 4:
        return SetChroma(targets(visualClips), ChromaKey(
          enabled: c.flip(),
          color: color() & 0xFFFFFF,
          similarity: inRange(PropertyKeys.chromaSimilarity),
          smoothness: inRange(PropertyKeys.chromaSmoothness),
          spill: inRange(PropertyKeys.chromaSpill),
        ));
      case 5:
        return SetMask(targets(visualClips), MaskSpec(
          shape: c.pick(MaskShape.values),
          center: vecIn(PropertyKeys.maskCenter),
          size: vecIn(PropertyKeys.maskSize),
          rotationDeg: inRange(PropertyKeys.maskRotation),
          cornerRadius: inRange(PropertyKeys.maskCornerRadius),
          feather: inRange(PropertyKeys.maskFeather),
          opacity: inRange(PropertyKeys.maskOpacity),
          invert: c.flip(),
        ));
      case 6:
        return SetCrop(targets(visualClips), crop());
      default:
        return ResetTransform(targets([...visualClips, ...texts]));
    }
  }

  // ----- CORE-13 keyframes -----

  /// An existing key: (item, channel id, item-local t), or null when no item has keys.
  (TimelineItem, String, TimeUs)? existingKey() {
    if (keyed.isEmpty) return null;
    final i = c.pick(keyed);
    final set = keyframesOf(i);
    final channel = c.pick(set.byChannel.keys.toList()..sort());
    final keys = set.byChannel[channel]!.keys;
    return (i, channel, c.pick(keys).t);
  }

  Object keyValue(String property) {
    final k = PropertyKeys.lookup(property) ?? PropertyKeys.byChannel[property] ?? PropertyKeys.opacity;
    if (k.channels.length == 2) return c.chance(1, 30) ? 7 : vecIn(k);
    return c.chance(1, 30) ? Vec2.zero : inRange(k);
  }

  EditCommand keyframe() {
    final roll = c.weighted(const [30, 18, 14, 18, 12]);
    final existing = roll == 0 || c.chance(1, 12) ? null : existingKey();
    switch (roll) {
      case 1 when existing != null:
        return RemoveKeyframe(KeyframeRef(existing.$1.id, existing.$2, existing.$3));
      case 2 when existing != null:
        return MoveKeyframe(KeyframeRef(existing.$1.id, existing.$2, existing.$3), timeIn(existing.$1) - existing.$1.start);
      case 3 when existing != null:
        return SetKeyframeValue(KeyframeRef(existing.$1.id, existing.$2, existing.$3), keyValue(existing.$2));
      case 4:
        final ids = targets(keyed.isEmpty ? items : keyed);
        final prop = c.chance(1, 2) ? null : c.pick(PropertyKeys.keyframable).id;
        return ClearKeyframes(ids, property: c.chance(1, 20) ? 'visual.crop' : prop, at: c.chance(1, 2) ? time() : null);
      default:
        final pool = [...visualClips, ...texts, ...clips.where((x) => x.visual == null)];
        if (pool.isEmpty) return AddKeyframe(KeyframeRef(unknownItem, 'transform.opacity', 0));
        final target = c.pick(pool);
        final keys = PropertyKeys.keyframable.where((k) => k.appliesToItem(target)).toList();
        final k = keys.isEmpty || c.chance(1, 20) ? c.pick(PropertyKeys.all) : c.pick(keys);
        final property = k.channels.length == 2 && c.chance(1, 3) ? c.pick(k.channels) : k.id;
        final t = c.chance(1, 15) ? target.duration + c.below(microsPerSecond) : timeIn(target) - target.start;
        return AddKeyframe(KeyframeRef(c.chance(1, 25) ? unknownItem : target.id, property, t),
            value: c.chance(1, 2) ? null : keyValue(property));
    }
  }

  // ----- CORE-14 text -----

  TextStyleSpec style() => TextStyleSpec(
        fontFamily: c.pick(const ['figtree', 'inter', 'playfair']),
        fontSizePt: c.chance(1, 30) ? 400 : inRange(PropertyKeys.fontSize),
        bold: c.flip(),
        italic: c.chance(1, 4),
        align: c.pick(TextAlignH.values),
        color: color(),
        letterSpacing: inRange(PropertyKeys.letterSpacing),
        lineHeight: inRange(PropertyKeys.lineHeight),
        maxWidth: inRange(PropertyKeys.maxWidth),
        background: c.chance(1, 3) ? BoxStyle(color: color(), opacity: c.unit()) : null,
        stroke: c.chance(1, 4) ? StrokeStyle(color: color(), widthPt: c.between(0, 8)) : null,
        shadow: c.chance(1, 4) ? ShadowStyle(color: color(), opacity: c.unit(), blurPt: c.between(0, 20)) : null,
      );

  EditCommand textCommand() {
    switch (c.weighted(const [24, 26, 26, 24])) {
      case 0:
        return AddText(time(),
            text: c.chance(1, 4) ? AddText.placeholder : text(),
            duration: c.chance(1, 2) ? length() : null,
            style: c.chance(1, 3) ? style() : null,
            track: c.chance(1, 3) ? lane() : null);
      case 1:
        return SetText(item(texts.isEmpty ? null : texts), text());
      case 2:
        final ids = targets(texts);
        if (c.chance(1, 4)) return SetTextStyle.replace(ids, style());
        return SetTextStyle(
          ids,
          fontFamily: maybe(() => c.pick(const ['figtree', 'inter'])),
          fontSizePt: maybe(() => inRange(PropertyKeys.fontSize)),
          bold: maybe(c.flip),
          italic: maybe(c.flip),
          align: maybe(() => c.pick(TextAlignH.values)),
          color: maybe(color),
          letterSpacing: maybe(() => inRange(PropertyKeys.letterSpacing), den: 4),
          lineHeight: maybe(() => inRange(PropertyKeys.lineHeight), den: 4),
          maxWidth: maybe(() => inRange(PropertyKeys.maxWidth), den: 4),
          background: maybe(() => BoxStyle(color: color(), opacity: c.unit()), den: 4),
          removeBackground: c.chance(1, 6),
          stroke: maybe(() => StrokeStyle(color: color(), widthPt: c.between(0, 8)), den: 4),
          removeStroke: c.chance(1, 6),
          shadow: maybe(() => ShadowStyle(color: color(), opacity: c.unit()), den: 4),
          removeShadow: c.chance(1, 6),
        );
      default:
        final inKind = c.pick(TextAnimKind.values);
        final outKind = c.pick(TextAnimKind.values);
        return SetTextAnimation(
          targets(texts),
          TextAnimation(
            inKind: inKind,
            inDirection: c.pick(TextSlideDirection.values),
            inDuration: inKind == TextAnimKind.none ? 0 : length(),
            outKind: outKind,
            outDirection: c.pick(TextSlideDirection.values),
            outDuration: outKind == TextAnimKind.none ? 0 : length(),
          ),
        );
    }
  }

  // ----- CORE-15 subtitles -----

  List<Track> get subtitleLanes => [for (final t in tracks) if (t.kind == TrackKind.subtitle) t];

  List<SubtitleCueDraft> drafts() {
    final n = c.below(12);
    var t = c.below(5 * microsPerSecond);
    return [
      for (var i = 0; i < n; i++)
        () {
          final s = c.chance(1, 8) ? t - c.below(microsPerSecond) : t + c.below(microsPerSecond);
          final e = s + (c.chance(1, 15) ? 0 : 1 + c.below(3 * microsPerSecond));
          t = e;
          return SubtitleCueDraft(TimeRange(math.max(0, s), math.max(0, math.max(s, e))), text());
        }(),
    ];
  }

  SubtitleStyle subtitleStyle() => SubtitleStyle(
        fontFamily: c.pick(const ['figtree', 'inter']),
        fontSizePt: c.chance(1, 20) ? 4 : c.between(8, 200),
        bold: c.flip(),
        italic: c.chance(1, 4),
        color: color(),
        maxLines: c.chance(1, 20) ? 0 : 1 + c.below(3),
        maxWidth: c.chance(1, 20) ? 1.5 : c.between(0.05, 1),
        align: c.pick(TextAlignH.values),
      );

  EditCommand subtitle() {
    final cueItems = cues;
    switch (c.weighted(const [14, 14, 10, 10, 9, 8, 7, 8, 5, 5, 5, 5])) {
      case 0:
        return AddCue(time(), text(), track: c.chance(1, 2) ? lane((t) => t.kind == TrackKind.subtitle) : null,
            duration: c.chance(1, 2) ? length() : null);
      case 1:
        return SetCueText(item(cueItems.isEmpty ? null : cueItems), text());
      case 2:
        if (cueItems.isEmpty) return SetCueRange(unknownItem, 0, microsPerSecond);
        final cue = c.pick(cueItems);
        return SetCueRange(cue.id, cue.start + delta(), cue.end + delta(), clamp: c.flip());
      case 3:
        if (cueItems.isEmpty) return SplitCue(unknownItem, time());
        final cue = c.pick(cueItems);
        return SplitCue(cue.id, timeIn(cue), textSplit: c.chance(1, 3) ? c.below(cue.text.length + 2) : null);
      case 4:
        final lanes = [for (final t in subtitleLanes) if (t.items.length >= 2) t];
        if (lanes.isEmpty) return MergeCues(itemSet(cueItems.isEmpty ? null : cueItems));
        final t = c.pick(lanes);
        final i = c.below(t.items.length - 1);
        return MergeCues({t.items[i].id, t.items[i + 1].id, if (c.chance(1, 4) && i + 2 < t.items.length) t.items[i + 2].id});
      case 5:
        return DeleteCues(itemSet(cueItems.isEmpty ? null : cueItems));
      case 6:
        final from = time();
        return ShiftCues(lane((t) => t.kind == TrackKind.subtitle), delta(),
            range: c.chance(1, 2) ? TimeRange(from, from + c.below(10 * microsPerSecond)) : null);
      case 7:
        final replace = c.chance(1, 3);
        return ImportSubtitles(drafts(),
            mode: replace ? SubtitleImportMode.replace : SubtitleImportMode.newTrack,
            track: replace ? lane((t) => t.kind == TrackKind.subtitle) : null,
            name: c.pick(const ['', 'Imported', 'English']),
            language: c.pick(const [null, 'en', 'fr', 'pt-BR']));
      case 8:
        return SetSubtitleStyle(lane((t) => t.kind == TrackKind.subtitle), subtitleStyle());
      case 9:
        return SetSubtitlePosition(
          lane((t) => t.kind == TrackKind.subtitle),
          switch (c.below(3)) {
            0 => SubtitlePosition.bottom,
            1 => SubtitlePosition.top,
            _ => CustomSubtitlePosition(c.chance(1, 20) ? 1.5 : c.unit()),
          },
        );
      case 10:
        return SetBurnIn(lane((t) => t.kind == TrackKind.subtitle), c.flip());
      default:
        return SetSubtitleLanguage(lane((t) => t.kind == TrackKind.subtitle), c.pick(const [null, 'en', 'fr', 'zh-Hant', 'x']));
    }
  }

  // ----- CORE-15 captions -----

  CaptionProvenance provenance(String language) => CaptionProvenance(
        generator: 'whisper.cpp',
        engineVersion: '1.9.4',
        modelId: 'whisper-base-q5_1',
        modelSha256: 'abc123',
        language: language,
        languageDetected: c.flip(),
        segmentation: const SegmentationSettings(),
        scope: CaptionScopeData(),
        generatedAt: DateTime.utc(2026, 10, 10, 9),
      );

  EditCommand caption() {
    final language = c.pick(const ['en', 'fr', 'es']);
    final generated = [
      for (final t in subtitleLanes)
        if (t.subtitle?.provenance != null) t,
    ];
    if (c.chance(1, 2) || subtitleLanes.isEmpty) {
      return AddGeneratedCaptionTrack(trackName: 'Captions', language: language, provenance: provenance(language), cues: drafts());
    }
    final from = time();
    return ReplaceGeneratedCaptions(
      track: generated.isNotEmpty && c.chance(3, 4) ? c.pick(generated).id : lane((t) => t.kind == TrackKind.subtitle),
      range: c.chance(1, 2) ? TimeRange(from, from + c.below(20 * microsPerSecond)) : null,
      provenance: provenance(language),
      cues: drafts(),
    );
  }

  // ----- CORE-16 transitions -----

  TransitionSpec? transitionSpec() {
    if (c.chance(1, 8)) return null;
    final kind = c.pick(TransitionKind.values);
    final dirs = TransitionSpec.directionsOf(kind);
    final direction = switch (c.below(4)) {
      0 => null,
      1 => c.pick(TransitionDirection.values),
      _ => dirs.isEmpty ? null : c.pick(dirs),
    };
    return TransitionSpec(kind, c.chance(1, 20) ? c.below(3) - 1 : 1 + c.below(2 * rate.num), direction: direction);
  }

  EditCommand transition() {
    final visualLanes = [for (final t in tracks) if (t.kind == TrackKind.video || t.kind == TrackKind.overlay) t];
    if (c.chance(1, 4)) {
      return ApplyTransitionToAll(transitionSpec(), track: c.chance(1, 2) ? null : lane((t) => t.kind.isVisual));
    }
    final cuts = [for (final t in visualLanes) ...TransitionLimits.cutsOf(t)];
    final TransitionRef ref;
    if (cuts.isEmpty || c.chance(1, 10)) {
      ref = TransitionRef(lane(), item(), item());
    } else {
      ref = c.pick(cuts);
    }
    return SetTransition(ref, transitionSpec(), clamp: c.chance(2, 3));
  }

  // ----- CORE-17 tracks, markers, project -----

  EditCommand track() {
    switch (c.weighted(const [14, 6, 14, 10, 40, 8])) {
      case 0:
        final kind = c.pick(TrackKind.values);
        return AddTrack(kind,
            name: c.chance(1, 3) ? c.pick(fuzzTexts) : '',
            audioRole: kind == TrackKind.audio || c.chance(1, 10) ? c.pick(AudioRole.values) : null,
            language: kind == TrackKind.subtitle && c.flip() ? 'en' : null);
      case 1:
        return DeleteTrack(lane());
      case 2:
        if (tracks.isEmpty) return MoveTrack(unknownTrack, 0);
        final t = c.pick(tracks);
        final same = [for (var i = 0; i < tracks.length; i++) if (tracks[i].kind == t.kind) i];
        return MoveTrack(t.id, c.chance(1, 5) ? c.below(tracks.length + 2) - 1 : c.pick(same));
      case 3:
        return RenameTrack(lane(), c.chance(1, 10) ? 'x' * 61 : c.pick(fuzzTexts));
      case 4:
        final locked = tracks.any((t) => t.locked);
        return SetTrackFlags(
          lane(locked && c.chance(1, 2) ? (t) => t.locked : null),
          // Locks are sticky and block most edits: lock rarely, unlock often.
          locked: c.chance(1, 8) ? c.chance(1, 4) : (locked && c.chance(1, 2) ? false : null),
          hidden: maybe(c.flip, den: 3),
          muted: maybe(c.flip, den: 3),
          solo: maybe(() => c.chance(1, 3), den: 4),
        );
      default:
        return SetAudioRole(lane((t) => t.kind == TrackKind.audio), c.pick(AudioRole.values));
    }
  }

  MarkerId markerId() {
    if (p.markers.isEmpty || c.chance(1, 15)) return const MarkerId('mk_FzUnknown00');
    return c.pick(p.markers).id;
  }

  EditCommand marker() {
    switch (c.weighted(const [45, 35, 20])) {
      case 0:
        return AddMarker(time(),
            name: c.chance(1, 2) ? c.pick(fuzzTexts) : '',
            colorIndex: c.chance(1, 20) ? 9 : c.below(6),
            note: c.chance(1, 4) ? (c.chance(1, 20) ? 'n' * 1001 : 'A note') : null);
      case 1:
        final id = markerId();
        final Object? note = switch (c.below(4)) {
          0 => null,
          1 => 'Changed note',
          _ => const _Keep(),
        };
        return note is _Keep
            ? UpdateMarker(id, time: maybe(time), name: maybe(() => c.pick(fuzzTexts)), colorIndex: maybe(() => c.below(7)))
            : UpdateMarker(id, time: maybe(time), name: maybe(() => c.pick(fuzzTexts)), colorIndex: maybe(() => c.below(7)), note: note);
      default:
        return DeleteMarker(markerId());
    }
  }

  EditCommand project() {
    switch (c.weighted(const [40, 20, 40])) {
      case 0:
        return SetCanvas(
          aspect: maybe(() => c.chance(1, 15) ? const AspectRatio(5, 1) : c.pick(AspectRatio.standard)),
          baseShortSide: maybe(() => c.chance(1, 15) ? 1000 : c.pick(CanvasSpec.supportedShortSides)),
        );
      case 1:
        return SetFrameRate(FrameRate(c.pick(FrameRate.supportedProjectRates), 1));
      default:
        return SetBackground(c.flip() ? SolidBackground(c.below(1 << 32)) : BlurOfMainBackground(c.chance(1, 15) ? 2 : c.unit()));
    }
  }

  // ----- CORE-09 composites and raw edits -----

  EditCommand composite() {
    final n = 2 + c.below(2);
    return CompositeCommand('Fuzz composite', [for (var i = 0; i < n; i++) command(allowComposite: false)]);
  }

  /// A raw framework edit: an identity (no-op), a valid relabel, or a deliberate overlap that the
  /// post-step validation must refuse.
  FuzzAction raw() {
    switch (c.below(3)) {
      case 0:
        return ApplyAction(RawEditCommand('Fuzz identity', (x) => x));
      case 1:
        if (items.isEmpty) return ApplyAction(RawEditCommand('Fuzz identity', (x) => x));
        final id = c.pick(items).id;
        final label = c.pick(const ['Fuzz', 'Intro', 'B-roll']);
        return ApplyAction(RawEditCommand('Fuzz relabel', (x) => _relabel(x, id, label)));
      default:
        final lanes = [for (final t in tracks) if (t.items.length >= 2) t];
        if (lanes.isEmpty) return ApplyAction(RawEditCommand('Fuzz identity', (x) => x));
        final lane = c.pick(lanes).id;
        final i = c.below(lanes.firstWhere((t) => t.id == lane).items.length - 1);
        return ApplyAction(RawEditCommand('Fuzz overlap', (x) => _overlap(x, lane, i)), expect: ApplyExpectation.internalInconsistency);
    }
  }

  // ----- session actions -----

  FuzzAction transaction() {
    final n = 1 + c.below(3);
    // A gesture repeats one kind of command with growing parameters; drawing each update
    // independently is a superset of that.
    final updates = [for (var i = 0; i < n; i++) command(allowComposite: false)];
    return TransactionAction(updates, TransactionEnd.values[c.weighted(const [6, 3, 2])]);
  }

  FuzzAction poolEdit() {
    final assets = p.pool.assets.values.toList();
    if (assets.isEmpty) return const UndoAction();
    final a = c.pick(assets);
    if (c.chance(1, 2)) return PoolEditAction(RemoveAssets({a.id, if (c.chance(1, 4)) c.pick(assets).id}));
    // Relink: same id and kind, new locator and fingerprint; sometimes another duration (CORE-28
    // refuses kind changes before it calls the session), sometimes a changed id (refused).
    final MediaAsset replacement;
    switch (c.weighted(const [70, 20, 10])) {
      case 0:
        replacement = a.copyWith(
          locator: AppRelativeLocator(AppRoot.documents, 'relinked/${a.id}'),
          fingerprint: MediaFingerprint(sizeBytes: a.fingerprint.sizeBytes + 1, quickHash: 'q${a.fingerprint.quickHash}', duration: a.fingerprint.duration),
          status: AssetStatus.ready,
        );
      case 1:
        final d = (a.probe.duration * (0.3 + c.unit())).round();
        replacement = a.copyWith(probe: a.probe.copyWith(duration: d), fingerprint: MediaFingerprint(sizeBytes: 1, quickHash: 'short', duration: d));
      default:
        replacement = a.copyWith(id: const MediaId('md_FzOtherId00'));
    }
    EditCommand? adjust;
    if (c.chance(1, 4)) {
      final users = [for (final x in clips) if (x.media == a.id) x];
      if (users.isNotEmpty) {
        final u = c.pick(users);
        adjust = TrimItem(u.id, TrimEdge.end, u.end - rate.timeOfFrame(1 + c.below(10)), clamp: true);
      }
    }
    return PoolEditAction(RelinkAssets({a.id: replacement}), adjust: adjust);
  }

  FuzzAction poolChange() {
    final pending = [for (final a in p.pool.assets.values) if (a.status is PendingStatus) a];
    if (pending.isNotEmpty && c.chance(3, 4)) {
      final a = c.pick(pending);
      final AssetStatus status = switch (c.weighted(const [5, 3, 2])) {
        0 => AssetStatus.ready,
        1 => PendingStatus('job_${a.id.value.substring(3)}'),
        _ => const FailedStatus('engine'),
      };
      return PoolChangeAction(UpdateAsset(a.copyWith(status: status)));
    }
    if (c.chance(1, 3) && p.pool.assets.isNotEmpty) {
      final a = c.pick(p.pool.assets.values.toList());
      return PoolChangeAction(UpdateAsset(a.copyWith(proxy: c.pick(ProxyState.values))));
    }
    final id = gen._newMediaId();
    final video = c.flip();
    final duration = video ? (c.between(1, 120) * microsPerSecond).round() : 0;
    return PoolChangeAction(AddAssets([
      MediaAsset(
        id: id,
        kind: video ? MediaKind.video : MediaKind.image,
        displayName: 'import ${id.value.substring(3)}',
        locator: AppRelativeLocator(AppRoot.documents, 'media/$id'),
        ownership: MediaOwnership.managedCopy,
        fingerprint: MediaFingerprint(sizeBytes: 1000 + c.below(1 << 20), quickHash: id.value.padRight(40, '0'), duration: duration),
        probe: MediaProbe(kind: video ? MediaKind.video : MediaKind.image, duration: duration, hasVideo: true, hasAudio: video && c.flip(), width: 1920, height: 1080),
        origin: MediaOrigin.files,
        addedAt: DateTime.utc(2026, 10, 10),
      ),
    ]));
  }
}

final class _Keep {
  const _Keep();
}

/// [p] with item [id] relabelled (a valid raw edit).
EditProject _relabel(EditProject p, ItemId id, String label) {
  final tl = p.timeline;
  return p.copyWith(
    timeline: tl.copyWith(tracks: [
      for (final t in tl.tracks)
        t.items.any((i) => i.id == id)
            ? t.copyWith(items: [
                for (final i in t.items)
                  i.id != id
                      ? i
                      : switch (i) {
                          MediaClip() => i.copyWith(label: label),
                          TextItem() => i.copyWith(label: label),
                          SubtitleCue() => SubtitleCue(
                              id: i.id,
                              start: i.start,
                              duration: i.duration,
                              link: i.link,
                              label: label,
                              text: i.text,
                              origin: i.origin,
                              editedAfterGeneration: i.editedAfterGeneration,
                            ),
                        },
              ])
            : t,
    ]),
  );
}

/// [p] with item [index] + 1 of lane [lane] moved onto item [index] (an I2 violation).
EditProject _overlap(EditProject p, TrackId lane, int index) {
  final tl = p.timeline;
  return p.copyWith(
    timeline: tl.copyWith(tracks: [
      for (final t in tl.tracks)
        if (t.id != lane)
          t
        else
          t.copyWith(items: [
            for (var i = 0; i < t.items.length; i++)
              i == index + 1
                  ? switch (t.items[i]) {
                      MediaClip() && final x => x.copyWith(start: t.items[index].start),
                      TextItem() && final x => x.copyWith(start: t.items[index].start),
                      SubtitleCue() && final x => x.copyWith(start: t.items[index].start),
                    }
                  : t.items[i],
          ]),
    ]),
  );
}
