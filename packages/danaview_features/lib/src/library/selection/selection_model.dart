// OWNER: HOM-12
//
// The multi-select model of the Files & Media Home (ARCH v1.2 V2-107, D-92; BUILD_PLAN HOM-12).
// One selection spans every tab: an item picked in Photos stays picked in All or Videos, so a
// montage can mix sources. The selection keeps the order the user picked items in — every action
// of the bar (montage, batch edit, play, add to playlist, HOM-22's file actions) receives the items
// in that order. Items compare by id (V2-09), so the same file reached from two tabs is one entry.

import 'dart:collection';

import 'package:danaview_library/danaview_library.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What kinds of item a selection holds; decides which action groups the bar shows.
enum SelectionMix {
  /// Nothing selected.
  empty,

  /// Only photos.
  photos,

  /// Only videos.
  videos,

  /// Photos and videos, no documents.
  media,

  /// Only documents.
  documents,

  /// Documents together with photos or videos.
  mixedWithDocuments,
}

/// An ordered, duplicate-free multi-selection of library items.
@immutable
final class HomeSelection {
  HomeSelection._(List<MediaItem> items)
      : items = List.unmodifiable(items),
        _ids = LinkedHashMap.fromIterables(items.map((i) => i.id), List.generate(items.length, (i) => i));

  /// No selection.
  static final HomeSelection empty = HomeSelection._(const []);

  /// [items] in order; later duplicates (same id) are dropped.
  factory HomeSelection.of(Iterable<MediaItem> items) {
    final seen = <ItemId>{};
    return HomeSelection._([for (final item in items) if (seen.add(item.id)) item]);
  }

  /// The selected items in the order they were picked.
  final List<MediaItem> items;

  final Map<ItemId, int> _ids;

  /// Whether nothing is selected.
  bool get isEmpty => items.isEmpty;

  /// Whether the Home is in selection mode (something is selected).
  bool get isActive => items.isNotEmpty;

  /// How many items are selected.
  int get length => items.length;

  /// Whether [item] is selected.
  bool contains(MediaItem item) => _ids.containsKey(item.id);

  /// Whether the item with [id] is selected.
  bool containsId(ItemId id) => _ids.containsKey(id);

  /// The 1-based pick order of [item], or null when it isn't selected.
  int? orderOf(MediaItem item) {
    final i = _ids[item.id];
    return i == null ? null : i + 1;
  }

  /// Whether every item of [group] is selected (false for an empty group).
  bool containsAll(Iterable<MediaItem> group) {
    var any = false;
    for (final item in group) {
      if (!contains(item)) return false;
      any = true;
    }
    return any;
  }

  /// The selected photos, in selection order.
  List<PhotoMediaItem> get photos => List.unmodifiable(items.whereType<PhotoMediaItem>());

  /// The selected videos, in selection order.
  List<VideoMediaItem> get videos => List.unmodifiable(items.whereType<VideoMediaItem>());

  /// The selected documents, in selection order.
  List<DocumentMediaItem> get documents => List.unmodifiable(items.whereType<DocumentMediaItem>());

  /// The selected photos and videos (no documents), in selection order.
  List<MediaItem> get media => List.unmodifiable(items.where((i) => i is! DocumentMediaItem));

  /// The kinds this selection holds.
  SelectionMix get mix {
    var photos = false, videos = false, documents = false;
    for (final item in items) {
      switch (item) {
        case PhotoMediaItem():
          photos = true;
        case VideoMediaItem():
          videos = true;
        case DocumentMediaItem():
          documents = true;
      }
    }
    if (documents) return photos || videos ? SelectionMix.mixedWithDocuments : SelectionMix.documents;
    if (photos && videos) return SelectionMix.media;
    if (photos) return SelectionMix.photos;
    if (videos) return SelectionMix.videos;
    return SelectionMix.empty;
  }

  /// This selection with [item] appended (unchanged when already selected).
  HomeSelection adding(MediaItem item) => contains(item) ? this : HomeSelection._([...items, item]);

  /// This selection with every item of [more] that isn't selected yet appended, in [more]'s order.
  HomeSelection addingAll(Iterable<MediaItem> more) {
    final added = [for (final item in more) if (!contains(item)) item];
    return added.isEmpty ? this : HomeSelection.of([...items, ...added]);
  }

  /// This selection without [item].
  HomeSelection removing(MediaItem item) => !contains(item) ? this : HomeSelection._([
        for (final i in items)
          if (i.id != item.id) i,
      ]);

  /// This selection without the items whose id is in [ids].
  HomeSelection removingIds(Set<ItemId> ids) {
    if (!ids.any(containsId)) return this;
    return HomeSelection._([for (final i in items) if (!ids.contains(i.id)) i]);
  }

  @override
  bool operator ==(Object other) => other is HomeSelection && listEquals(other.items, items);

  @override
  int get hashCode => Object.hashAll(items);

  // Never prints names, ids or paths (ARCH rule 30).
  @override
  String toString() => 'HomeSelection(${items.length}, ${mix.name})';
}

/// The Home's selection: tap to toggle, select all in a group, drag-select ([DragSelectSession]).
class HomeSelectionController extends StateNotifier<HomeSelection> {
  /// An empty selection.
  HomeSelectionController() : super(HomeSelection.empty);

  /// Selects [item] when it isn't selected, otherwise deselects it.
  void toggle(MediaItem item) => state = state.contains(item) ? state.removing(item) : state.adding(item);

  /// Selects [item] (appended to the order).
  void select(MediaItem item) => state = state.adding(item);

  /// Deselects [item].
  void deselect(MediaItem item) => state = state.removing(item);

  /// "Select all" of a date group, folder or section: selects every item of [group] that isn't
  /// selected yet (in [group]'s order); when all of them already are, deselects them all.
  void toggleAll(Iterable<MediaItem> group) {
    final list = group.toList(growable: false);
    if (list.isEmpty) return;
    state = state.containsAll(list) ? state.removingIds({for (final i in list) i.id}) : state.addingAll(list);
  }

  /// Drops items that no longer exist (deleted, trashed or no longer readable).
  void removeIds(Set<ItemId> ids) => state = state.removingIds(ids);

  /// Replaces the whole selection (drag-select writes through this).
  void replace(HomeSelection selection) => state = selection;

  /// Leaves selection mode.
  void clear() {
    if (state.isActive) state = HomeSelection.empty;
  }
}

/// The Home's one selection across every tab.
final homeSelectionProvider =
    StateNotifierProvider<HomeSelectionController, HomeSelection>((ref) => HomeSelectionController());

/// One drag-select gesture over an ordered run of items (a grid or a list).
///
/// The item under the finger when the drag starts is the anchor: if it wasn't selected the drag
/// selects, otherwise it deselects. Every item between the anchor and the item under the finger is
/// affected; moving back restores what the selection was before the drag. Newly selected items are
/// appended in the order the drag reaches them (anchor first).
final class DragSelectSession {
  /// A drag over [items] that started on [anchor] while [base] was selected.
  DragSelectSession({required this.base, required List<MediaItem> items, required this.anchor})
      : items = List.unmodifiable(items),
        selecting = !base.contains(items[anchor]) {
    RangeError.checkValidIndex(anchor, items, 'anchor');
  }

  /// The selection when the drag started.
  final HomeSelection base;

  /// The items the drag runs over, in display order.
  final List<MediaItem> items;

  /// The index where the drag started.
  final int anchor;

  /// True when the drag selects, false when it deselects.
  final bool selecting;

  /// The selection with the drag reaching [index] (clamped to the items).
  HomeSelection update(int index) {
    final end = index.clamp(0, items.length - 1);
    final step = end >= anchor ? 1 : -1;
    final range = [for (var i = anchor; i != end + step; i += step) items[i]];
    return selecting ? base.addingAll(range) : base.removingIds({for (final i in range) i.id});
  }
}
