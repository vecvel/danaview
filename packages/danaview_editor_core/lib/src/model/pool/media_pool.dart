// OWNER: CORE-04
//
// The media pool and its change types (ARCH §6.8, §7.3). Imports are sticky (undo never empties
// the bin); relink and remove are undoable deltas.

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../../ids/ids.dart';
import 'media_asset.dart';

/// All assets of a project, insertion-ordered.
@immutable
final class MediaPool {
  /// Creates a pool (the map is copied and made unmodifiable, preserving order).
  MediaPool(Map<MediaId, MediaAsset> assets) : assets = Map.unmodifiable(assets);

  const MediaPool._empty() : assets = const {};

  /// The empty pool.
  static const MediaPool empty = MediaPool._empty();

  /// Assets by id.
  final Map<MediaId, MediaAsset> assets;

  /// Number of assets.
  int get length => assets.length;

  /// Whether the pool has no assets.
  bool get isEmpty => assets.isEmpty;

  /// A pool with [assets] (default: this pool's assets).
  MediaPool copyWith({Map<MediaId, MediaAsset>? assets}) => assets == null ? this : MediaPool(assets);

  /// The asset [id], if present.
  MediaAsset? operator [](MediaId id) => assets[id];

  /// Whether [id] exists.
  bool contains(MediaId id) => assets.containsKey(id);

  /// A pool with [asset] added or replaced.
  MediaPool upsert(MediaAsset asset) => MediaPool({...assets, asset.id: asset});

  /// A pool without [ids].
  MediaPool without(Set<MediaId> ids) =>
      MediaPool({for (final e in assets.entries) if (!ids.contains(e.key)) e.key: e.value});

  @override
  bool operator ==(Object other) =>
      other is MediaPool && const MapEquality<MediaId, MediaAsset>().equals(other.assets, assets);

  @override
  int get hashCode => const MapEquality<MediaId, MediaAsset>().hash(assets);
}

/// A sticky (non-undoable) pool change: imports and probe/proxy/status updates.
@immutable
sealed class PoolChange {
  const PoolChange();
}

/// Adds imported assets.
final class AddAssets extends PoolChange {
  /// Creates the change.
  AddAssets(List<MediaAsset> assets) : assets = List.unmodifiable(assets);

  /// Assets to add.
  final List<MediaAsset> assets;

  /// A copy with the given assets.
  AddAssets copyWith({List<MediaAsset>? assets}) => AddAssets(assets ?? this.assets);

  @override
  bool operator ==(Object other) =>
      other is AddAssets && const ListEquality<MediaAsset>().equals(other.assets, assets);

  @override
  int get hashCode => Object.hashAll(assets);
}

/// Replaces one asset's probe, proxy or status (engine job results).
final class UpdateAsset extends PoolChange {
  /// Creates the change.
  const UpdateAsset(this.asset);

  /// The updated asset (same id).
  final MediaAsset asset;

  /// A copy with the given asset.
  UpdateAsset copyWith({MediaAsset? asset}) => UpdateAsset(asset ?? this.asset);

  @override
  bool operator ==(Object other) => other is UpdateAsset && other.asset == asset;

  @override
  int get hashCode => asset.hashCode;
}

/// An undoable pool edit.
@immutable
sealed class PoolEdit {
  const PoolEdit();

  /// History label.
  String get label;
}

/// Replaces assets by relinked versions (one history entry "Relink media").
final class RelinkAssets extends PoolEdit {
  /// Creates the edit.
  RelinkAssets(Map<MediaId, MediaAsset> replacements) : replacements = Map.unmodifiable(replacements);

  /// New asset values by id.
  final Map<MediaId, MediaAsset> replacements;

  /// A copy with the given replacements.
  RelinkAssets copyWith({Map<MediaId, MediaAsset>? replacements}) => RelinkAssets(replacements ?? this.replacements);

  @override
  String get label => 'Relink media';

  @override
  bool operator ==(Object other) =>
      other is RelinkAssets && const MapEquality<MediaId, MediaAsset>().equals(other.replacements, replacements);

  @override
  int get hashCode => const MapEquality<MediaId, MediaAsset>().hash(replacements);
}

/// Removes assets that the current timeline does not use.
final class RemoveAssets extends PoolEdit {
  /// Creates the edit.
  RemoveAssets(Set<MediaId> ids) : ids = Set.unmodifiable(ids);

  /// Assets to remove.
  final Set<MediaId> ids;

  /// A copy with the given ids.
  RemoveAssets copyWith({Set<MediaId>? ids}) => RemoveAssets(ids ?? this.ids);

  @override
  String get label => 'Remove from project';

  @override
  bool operator ==(Object other) =>
      other is RemoveAssets && const SetEquality<MediaId>().equals(other.ids, ids);

  @override
  int get hashCode => const SetEquality<MediaId>().hash(ids);
}

/// Before/after asset values recorded by a history entry for a [PoolEdit] (null = absent).
@immutable
final class PoolDelta {
  /// Creates a delta.
  PoolDelta({required Map<MediaId, MediaAsset?> before, required Map<MediaId, MediaAsset?> after})
      : before = Map.unmodifiable(before),
        after = Map.unmodifiable(after);

  /// Values before the edit.
  final Map<MediaId, MediaAsset?> before;

  /// Values after the edit.
  final Map<MediaId, MediaAsset?> after;

  /// A copy with the given maps.
  PoolDelta copyWith({Map<MediaId, MediaAsset?>? before, Map<MediaId, MediaAsset?>? after}) =>
      PoolDelta(before: before ?? this.before, after: after ?? this.after);

  @override
  bool operator ==(Object other) =>
      other is PoolDelta &&
      const MapEquality<MediaId, MediaAsset?>().equals(other.before, before) &&
      const MapEquality<MediaId, MediaAsset?>().equals(other.after, after);

  @override
  int get hashCode =>
      Object.hash(const MapEquality<MediaId, MediaAsset?>().hash(before), const MapEquality<MediaId, MediaAsset?>().hash(after));
}
