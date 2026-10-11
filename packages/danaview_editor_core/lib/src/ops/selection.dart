// OWNER: CORE-11
//
// Selection rules (ARCH §7.2, domain.md §6.3, ux.md §8.8–8.9). Selection itself is UI state, not
// a command; these pure helpers say what a selection means before UX builds a command from it:
//
// * [SelectionRules.expand] adds link partners (links move, split, delete and duplicate together)
//   and drops items on locked lanes — UX calls it before building commands;
// * split targeting, "select all on track", items under the playhead, and restoring a
//   `SelectionHint` after undo/redo (only ids that still exist).

import '../ids/ids.dart';
import '../model/items.dart';
import '../model/project.dart';
import '../model/track.dart';
import '../time/time.dart';
import 'outcome.dart';

/// Pure selection helpers.
abstract final class SelectionRules {
  /// [ids] plus the other members of their link groups, without unknown ids and without items on
  /// locked lanes (a partner on a locked lane is dropped too; a command that needs the whole group
  /// then refuses with `TrackLocked`). Order: the given ids first, then partners in lane order.
  static Set<ItemId> expand(EditProject project, Iterable<ItemId> ids) {
    final index = project.index;
    final out = <ItemId>{};
    final links = <LinkId>{};
    for (final id in ids) {
      final loc = index.locate(id);
      if (loc == null) continue;
      out.add(id);
      final l = loc.item.link;
      if (l != null) links.add(l);
    }
    if (links.isNotEmpty) {
      for (final t in project.tracks) {
        for (final i in t.items) {
          final l = i.link;
          if (l != null && links.contains(l)) out.add(i.id);
        }
      }
    }
    out.removeWhere((id) => index.locate(id)!.track.locked);
    return out;
  }

  /// Every item on [lane] ("Select all on track"); empty when the lane is locked or unknown.
  static Set<ItemId> allOnLane(EditProject project, TrackId lane) {
    for (final t in project.tracks) {
      if (t.id == lane) return t.locked ? const {} : {for (final i in t.items) i.id};
    }
    return const {};
  }

  /// Every item of the project on unlocked lanes ("Select all").
  static Set<ItemId> all(EditProject project) => {
        for (final t in project.tracks)
          if (!t.locked)
            for (final i in t.items) i.id,
      };

  /// Items whose range contains [t] (`start ≤ t < end`), in canonical lane order; only on [lane]
  /// when given. Locked lanes are skipped unless [includeLocked].
  static List<ItemId> itemsAt(EditProject project, TimeUs t, {TrackId? lane, bool includeLocked = false}) => [
        for (final track in project.tracks)
          if ((lane == null || track.id == lane) && (includeLocked || !track.locked))
            for (final i in track.items)
              if (i.start <= t && t < i.end) i.id,
      ];

  /// What "Split" acts on at [at] (ux.md §8.9): the [selected] items strictly containing [at]
  /// (with link partners, on unlocked lanes); if none, the unlocked main-lane item strictly
  /// containing [at]; else empty (the UI shows "Move the playhead over a clip to split it.").
  static Set<ItemId> splitTargets(EditProject project, TimeUs at, Set<ItemId> selected) {
    final t = project.settings.frameRate.quantize(at);
    bool inside(TimelineItem i) => i.start < t && t < i.end;
    final index = project.index;
    final chosen = <ItemId>{
      for (final id in expand(project, selected))
        if (index.item(id) case final i? when inside(i) && i is! SubtitleCue) id,
    };
    if (chosen.isNotEmpty) return chosen;
    final main = TrackOrder.mainTrack(project.tracks);
    if (main == null || main.locked) return const {};
    for (final i in main.items) {
      if (inside(i)) return {i.id};
    }
    return const {};
  }

  /// The lanes holding [ids] (unknown ids ignored), in canonical order.
  static List<TrackId> lanesOf(EditProject project, Iterable<ItemId> ids) {
    final set = ids.toSet();
    return [
      for (final t in project.tracks)
        if (t.items.any((i) => set.contains(i.id))) t.id,
    ];
  }

  /// Whether [ids] all sit on one lane (vertical moves and "Move to track…" need this).
  static bool isSingleLane(EditProject project, Iterable<ItemId> ids) => lanesOf(project, ids).length == 1;

  /// The lanes a single-lane selection of [ids] may move to: unlocked lanes of a compatible kind
  /// (video ↔ overlay, otherwise the same kind), excluding its own lane. Empty for multi-lane
  /// selections.
  static List<TrackId> moveTargets(EditProject project, Iterable<ItemId> ids) {
    final lanes = lanesOf(project, ids);
    if (lanes.length != 1) return const [];
    final from = project.tracks.firstWhere((t) => t.id == lanes.single);
    bool compatible(TrackKind k) =>
        k == from.kind ||
        ((k == TrackKind.video || k == TrackKind.overlay) && (from.kind == TrackKind.video || from.kind == TrackKind.overlay));
    return [
      for (final t in project.tracks)
        if (t.id != from.id && !t.locked && compatible(t.kind)) t.id,
    ];
  }

  /// The ids of [ids] that still exist in [project] (restoring a selection after undo/redo).
  static Set<ItemId> surviving(EditProject project, Iterable<ItemId> ids) {
    final index = project.index;
    return {for (final id in ids) if (index.locate(id) != null) id};
  }

  /// The selection to show after [outcome]: its hint restricted to existing items (null when the
  /// command suggested nothing, was refused or changed nothing).
  static SelectionHint? hintAfter(EditOutcome outcome) {
    final hint = outcome.selection;
    if (hint == null || !outcome.changed) return null;
    final items = surviving(outcome.project, hint.items);
    final primary = hint.primary;
    return SelectionHint(items, primary: primary != null && items.contains(primary) ? primary : null, lane: hint.lane);
  }
}
