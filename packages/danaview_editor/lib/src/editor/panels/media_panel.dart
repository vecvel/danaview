// OWNER: UX-36
//
// The media panel, a.k.a. the bin (ux.md §10.1). Constructor contract: `MediaPanel({Key? key,
// required MediaInspector route})` (InspectorHost builds panels with it).
//
// * Header: `Photos`/`Gallery` and `Files` buttons run the engine's pickers and import the picks
//   through UX-06's ImportMediaSheet (free-space preflight, progress, cancel). With "Add to
//   timeline" on (the default while the timeline is empty) the new media is also placed at the
//   playhead, like the card's "+".
// * Bin: a grid of cards (thumbnail, type, duration, "Used ×N", badges Missing / Processing /
//   Optimizing / Proxy ready). Filters All, Video, Photos, Audio (and LUT when the project has
//   one); search shows when the bin has more than 12 items. Reversed renditions are made by the
//   engine for a clip and are not listed.
// * Card: tap previews it in place (a strip with a large poster, its facts and every action; no
//   timeline change); "+" adds at the playhead (a ripple insert on the main lane while ripple is
//   on, else a new lane); the menu has Add as overlay, Replace selected clip, Relink…, Info and
//   Remove from project (only when unused; undoable); a long press (touch) or a drag (pointer)
//   starts a `MediaDragData` drag onto the timeline (`TimelineDropTarget`, ux.md §15.3).
// * Everything the cards do is a `MediaOperations` method (media_bindings.dart), so the panel only
//   decides what to offer and why something is unavailable.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart' show Icons, Theme;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' hide AspectRatio;
import 'package:danaview_editor_core/store.dart' show MediaAvailability;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart'
    show MediaPickKind, MediaPickRequest, MediaPickSource, ThumbPriority, ThumbnailHandle, ThumbnailRequest;
import 'package:danaview_features/storage.dart' show formatDataSize;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/media_strings.dart';
import '../actions/bindings/media_bindings.dart';
import '../actions/editor_action_registry.dart';
import '../contracts/contracts.dart';
import '../editor_scope.dart';
import '../flows/import_media_sheet.dart';
import '../state/edit_transaction.dart' show EditApplied;
import '../state/editor_state.dart' show SavePhase;
import '../state/media_health_controller.dart';
import '../timeline/timeline_drop_target.dart' show MediaDragData;
import '../timeline/timeline_semantics.dart' show editorAnnounce;

// =================================================================================================
// Bin model
// =================================================================================================

/// The bin's filter chips (ux.md §10.1).
enum MediaBinFilter {
  /// Everything.
  all,

  /// Videos.
  video,

  /// Photos and freeze frames.
  photos,

  /// Music files and recordings.
  audio,

  /// Colour lookup tables.
  lut;

  /// The chip label.
  String get label => switch (this) {
        MediaBinFilter.all => MediaStrings.filterAll,
        MediaBinFilter.video => MediaStrings.filterVideo,
        MediaBinFilter.photos => MediaStrings.filterPhotos,
        MediaBinFilter.audio => MediaStrings.filterAudio,
        MediaBinFilter.lut => MediaStrings.filterLut,
      };

  /// Whether media of [kind] shows under this filter.
  bool matches(MediaKind kind) => switch (this) {
        MediaBinFilter.all => true,
        MediaBinFilter.video => kind == MediaKind.video,
        MediaBinFilter.photos => kind == MediaKind.image || kind == MediaKind.still,
        MediaBinFilter.audio => kind == MediaKind.audio || kind == MediaKind.recording,
        MediaBinFilter.lut => kind == MediaKind.lut,
      };
}

/// What the bin lists and in which order (pure; tests use it directly).
abstract final class MediaBin {
  /// The search field shows when the bin has more items than this.
  static const int searchThreshold = 12;

  /// Whether [asset] is listed: reversed renditions belong to their clip, not to the bin.
  static bool listed(MediaAsset asset) => asset.derived is! ReversedSpec;

  /// The bin's assets of [pool], newest first.
  static List<MediaAsset> assets(MediaPool pool) {
    final all = [
      for (final a in pool.assets.values)
        if (listed(a)) a
    ];
    final order = {for (final (i, a) in all.indexed) a.id: i};
    all.sort((a, b) {
      final byTime = b.addedAt.compareTo(a.addedAt);
      return byTime != 0 ? byTime : order[b.id]!.compareTo(order[a.id]!);
    });
    return all;
  }

  /// [bin] narrowed by [filter] and the search [query] (case-insensitive part of the name).
  static List<MediaAsset> filtered(List<MediaAsset> bin, MediaBinFilter filter, String query) {
    final q = query.trim().toLowerCase();
    return [
      for (final a in bin)
        if (filter.matches(a.kind) && (q.isEmpty || a.displayName.toLowerCase().contains(q))) a,
    ];
  }

  /// The filters worth showing for [bin]: LUT only when the project has one.
  static List<MediaBinFilter> filtersOf(List<MediaAsset> bin) => [
        for (final f in MediaBinFilter.values)
          if (f != MediaBinFilter.lut || bin.any((a) => a.kind == MediaKind.lut)) f,
      ];

  /// "0:12" for media with a length, else null (photos, LUTs).
  static String? durationLabel(MediaAsset asset) =>
      (asset.kind == MediaKind.video || asset.kind == MediaKind.audio || asset.kind == MediaKind.recording) && asset.probe.duration > 0
          ? Timecode.clock(asset.probe.duration)
          : null;

  /// The icon of [kind].
  static IconData iconOf(MediaKind kind) => switch (kind) {
        MediaKind.video => Icons.movie_rounded,
        MediaKind.image || MediaKind.still => Icons.image_rounded,
        MediaKind.audio => Icons.music_note_rounded,
        MediaKind.recording => Icons.mic_rounded,
        MediaKind.lut => Icons.palette_rounded,
      };

  /// The facts line of the preview strip: "Video · 0:12 · 1920×1080 · 24 MB".
  static String describe(MediaAsset asset) {
    final p = asset.probe;
    final w = p.width, h = p.height;
    final swap = p.rotation % 180 != 0;
    return [
      MediaStrings.kindName(asset.kind),
      if (durationLabel(asset) case final d?) d,
      if (w != null && h != null && w > 0 && h > 0) '${swap ? h : w}×${swap ? w : h}',
      if (asset.fingerprint.sizeBytes > 0) formatDataSize(asset.fingerprint.sizeBytes),
    ].join(' · ');
  }
}

/// Why a card shows a badge, in priority order.
enum _Badge {
  missing,
  noAccess,
  changed,
  failed,
  processing,
  optimizing,
  proxyReady;

  String get label => switch (this) {
        _Badge.missing => MediaStrings.badgeMissing,
        _Badge.noAccess => MediaStrings.badgeNoAccess,
        _Badge.changed => MediaStrings.badgeChanged,
        _Badge.failed => MediaStrings.badgeFailed,
        _Badge.processing => MediaStrings.badgeProcessing,
        _Badge.optimizing => MediaStrings.badgeOptimizing,
        _Badge.proxyReady => MediaStrings.badgeProxyReady,
      };

  Color get color => switch (this) {
        _Badge.missing || _Badge.noAccess || _Badge.changed || _Badge.failed => DanaviewColors.errorLight,
        _Badge.processing => DanaviewColors.warning,
        _Badge.optimizing => DanaviewColors.primaryLight,
        _Badge.proxyReady => DanaviewColors.success,
      };

  IconData get icon => switch (this) {
        _Badge.missing || _Badge.noAccess || _Badge.changed || _Badge.failed => Icons.error_outline_rounded,
        _Badge.processing || _Badge.optimizing => Icons.hourglass_top_rounded,
        _Badge.proxyReady => Icons.bolt_rounded,
      };

  bool get offline => index <= _Badge.failed.index;

  static _Badge? of(MediaAsset asset, MediaAvailability? availability) {
    if (asset.status is FailedStatus) return _Badge.failed;
    switch (availability) {
      case MediaAvailability.missing:
        return _Badge.missing;
      case MediaAvailability.accessLost:
        return _Badge.noAccess;
      case MediaAvailability.changed:
        return _Badge.changed;
      case MediaAvailability.available || MediaAvailability.derivedMissing || null:
        break;
    }
    if (asset.status is PendingStatus) return _Badge.processing;
    return switch (asset.proxy) {
      ProxyState.pending => _Badge.optimizing,
      ProxyState.ready => _Badge.proxyReady,
      ProxyState.none || ProxyState.failed => null,
    };
  }
}

/// The usage counts of a project with value equality (a drag does not rebuild the bin).
@immutable
class _Usage {
  const _Usage(this.counts);

  final Map<MediaId, int> counts;

  @override
  bool operator ==(Object other) {
    if (other is! _Usage || other.counts.length != counts.length) return false;
    for (final e in counts.entries) {
      if (other.counts[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(counts.length, Object.hashAllUnordered(counts.values));
}

// =================================================================================================
// Panel
// =================================================================================================

/// The media panel (ux.md §10.1). See the file header.
class MediaPanel extends ConsumerStatefulWidget {
  /// Creates the panel.
  const MediaPanel({super.key, required this.route});

  /// What the panel edits.
  final MediaInspector route;

  @override
  ConsumerState<MediaPanel> createState() => _MediaPanelState();
}

class _MediaPanelState extends ConsumerState<MediaPanel> {
  MediaBinFilter _filter = MediaBinFilter.all;
  String _query = '';
  MediaId? _previewed;
  bool? _addToTimeline;
  bool _picking = false;
  final _ThumbStore _thumbs = _ThumbStore();
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  ProjectId get _id => EditorScope.idOf(context);

  MediaOperations get _ops => MediaOperations.forProject(_id, ref.read);

  WidgetActionContext get _actionContext => WidgetActionContext(projectId: _id, context: context, ref: ref);

  void _toast(String message, {IconData? icon, DanaviewToastKind kind = DanaviewToastKind.info}) {
    if (!mounted) return;
    DanaviewToast.show(context, message, icon: icon, kind: kind);
    editorAnnounce(context, message);
  }

  // ---- Header -----------------------------------------------------------------------------------

  Future<void> _pick(MediaPickSource source) async {
    if (_picking) return;
    final ops = _ops;
    if (!ops.canEdit || ops.readOnly) {
      _toast(MediaStrings.notEditable);
      return;
    }
    setState(() => _picking = true);
    try {
      final kinds = {
        MediaPickKind.video,
        MediaPickKind.image,
        MediaPickKind.audio,
        if (source == MediaPickSource.files) MediaPickKind.lut,
      };
      final picked = await ref.read(editorEngineProvider).picker.pick(MediaPickRequest(source: source, kinds: kinds));
      if (!mounted || picked.isEmpty) return;
      final edit = ops.session.editOrNull;
      if (edit == null) return;
      final job = ops.importJob(pool: ref.read(mediaPoolServiceProvider), edit: edit, place: _addToTimeline ?? false);
      await showImportMediaSheet(context, picks: picked, job: job, title: MediaStrings.importTitle);
    } on Object catch (e) {
      debugPrint('[MediaPanel] Picker failed: ${e.runtimeType}');
      _toast(MediaStrings.pickerFailed, icon: Icons.error_outline_rounded, kind: DanaviewToastKind.error);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  // ---- Card actions -----------------------------------------------------------------------------

  void _preview(MediaAsset asset) => setState(() => _previewed = _previewed == asset.id ? null : asset.id);

  void _add(MediaAsset asset) {
    final ops = _ops;
    final blocker = _placeBlocker(asset);
    if (blocker != null) return _toast(blocker);
    final result = ops.addAtPlayhead([asset.id]);
    if (result is EditApplied) {
      HapticFeedback.lightImpact();
      editorAnnounce(context, MediaStrings.dropped);
    }
  }

  void _overlay(MediaAsset asset) {
    final blocker = _placeBlocker(asset) ?? (isVisualMediaKind(asset.kind) ? null : MediaStrings.overlayNeedsVisual);
    if (blocker != null) return _toast(blocker);
    final result = _ops.addAsOverlay([asset.id]);
    if (result is EditApplied) {
      HapticFeedback.lightImpact();
      editorAnnounce(context, MediaStrings.dropped);
    } else if (result == null) {
      _toast(MediaStrings.overlayFailed);
    }
  }

  void _replace(MediaAsset asset) {
    final ops = _ops;
    final blocker = ops.replaceBlocker(asset);
    if (blocker != null) return _toast(blocker);
    final result = ops.replaceSelected(asset.id);
    if (result is EditApplied && result.notices.isEmpty) _toast(MediaStrings.replaced, icon: Icons.swap_horiz_rounded);
  }

  void _relink() => ref.actionRegistry(Theme.of(context).platform).invoke(EditorActionId.relink, _actionContext);

  void _info(MediaAsset asset, int used, MediaAvailability? availability) {
    showDanaviewSheet<void>(
      context,
      title: MediaStrings.infoTitle,
      builder: (_) => MediaInfoSheet(asset: asset, used: used, availability: availability),
    );
  }

  void _remove(MediaAsset asset) {
    final ops = _ops;
    final blocker = ops.removeBlocker(asset.id);
    if (blocker != null) return _toast(blocker);
    final result = ops.remove(asset.id);
    if (result is EditApplied) {
      if (_previewed == asset.id) setState(() => _previewed = null);
      _toast(MediaStrings.removed, icon: Icons.delete_outline_rounded);
    }
  }

  /// Why [asset] can't go on the timeline, or null.
  String? _placeBlocker(MediaAsset asset) {
    if (!_ops.canEdit) return MediaStrings.notEditable;
    if (asset.kind == MediaKind.lut) return MediaStrings.lutNotPlaceable;
    if (asset.status is FailedStatus) return MediaStrings.assetFailed;
    return null;
  }

  // ---- Build ------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final id = _id;
    final poolOrNull = ref.watch(editorControllerProvider(id).select((s) => s.project?.pool));
    final pool = poolOrNull ?? MediaPool.empty;
    final usage = ref
        .watch(editorControllerProvider(id).select((s) {
          final p = s.project;
          return _Usage(p == null ? const {} : mediaUsageOf(p));
        }))
        .counts;
    final editable = ref.watch(editorControllerProvider(id).select((s) => s.isReady && s.save.phase != SavePhase.readOnly));
    // The selected clip decides whether "Replace selected clip" is offered (the menus read it live).
    ref.watch(editorControllerProvider(id).select((s) {
      final primary = s.selection.primary;
      final loc = primary == null ? null : s.project?.index.locate(primary);
      return (primary, loc?.track.kind, loc?.track.locked, loc?.item is MediaClip);
    }));
    final health = ref.watch(mediaHealthControllerProvider(id).select((s) => s.byMedia));
    final platform = Theme.of(context).platform;

    // Picked media goes on the timeline by default while the timeline is empty (decided once, when
    // the project is there to look at; the user's choice sticks).
    if (_addToTimeline == null) {
      final timeline = ref.read(editorControllerProvider(id)).project?.timeline;
      if (timeline != null) _addToTimeline = timeline.tracks.every((t) => t.items.isEmpty);
    }

    final bin = MediaBin.assets(pool);
    final filters = MediaBin.filtersOf(bin);
    final filter = filters.contains(_filter) ? _filter : MediaBinFilter.all;
    final showSearch = bin.length > MediaBin.searchThreshold;
    final shown = MediaBin.filtered(bin, filter, showSearch ? _query : '');
    final previewed = _previewed == null ? null : pool[_previewed!];
    final ops = _ops;

    final scale = MediaQuery.textScalerOf(context).scale(1);
    // Thumbnail 16:9 at the card width, then the name and usage lines at the current text scale.
    final cardHeight = 78 + (13 + 12) * 1.35 * scale + 2 * DanaviewSpacing.sm + DanaviewSpacing.xs;

    if (poolOrNull == null) return const SizedBox.shrink(); // the editor is still opening

    return KeyedSubtree(
      key: const ValueKey('media-panel'),
      child: CustomScrollView(
        primary: false,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(DanaviewSpacing.md, DanaviewSpacing.md, DanaviewSpacing.md, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(
                      platform: platform,
                      picking: _picking,
                      editable: editable,
                      addToTimeline: _addToTimeline ?? false,
                      onPick: _pick,
                      onAddToTimeline: (v) => setState(() => _addToTimeline = v)),
                  if (bin.isNotEmpty) ...[
                    const SizedBox(height: DanaviewSpacing.sm),
                    _Filters(filters: filters, selected: filter, onSelected: (f) => setState(() => _filter = f)),
                  ],
                  if (showSearch) ...[
                    const SizedBox(height: DanaviewSpacing.sm),
                    DanaviewSearchField(
                      key: const ValueKey('media-search'),
                      controller: _search,
                      hint: MediaStrings.searchHint,
                      semanticLabel: MediaStrings.searchLabel,
                      onChanged: (q) => setState(() => _query = q),
                    ),
                  ],
                  if (previewed != null && MediaBin.listed(previewed)) ...[
                    const SizedBox(height: DanaviewSpacing.md),
                    _PreviewStrip(
                      key: const ValueKey('media-preview'),
                      projectId: id,
                      asset: previewed,
                      used: usage[previewed.id] ?? 0,
                      badge: _Badge.of(previewed, health[previewed.id]),
                      thumbs: _thumbs,
                      ops: ops,
                      actions: _CardActions(
                        add: () => _add(previewed),
                        overlay: () => _overlay(previewed),
                        replace: () => _replace(previewed),
                        relink: _relink,
                        info: () => _info(previewed, usage[previewed.id] ?? 0, health[previewed.id]),
                        remove: () => _remove(previewed),
                      ),
                      onClose: () => setState(() => _previewed = null),
                    ),
                  ],
                  const SizedBox(height: DanaviewSpacing.md),
                ],
              ),
            ),
          ),
          if (bin.isEmpty)
            const SliverToBoxAdapter(
              child: DanaviewEmptyState(
                key: ValueKey('media-empty'),
                icon: Icons.video_library_rounded,
                title: MediaStrings.emptyTitle,
                message: MediaStrings.emptyMessage,
              ),
            )
          else if (shown.isEmpty)
            const SliverToBoxAdapter(
              child: DanaviewEmptyState(
                key: ValueKey('media-no-match'),
                icon: Icons.search_off_rounded,
                title: MediaStrings.noMatchTitle,
                message: MediaStrings.noMatchMessage,
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(DanaviewSpacing.md, 0, DanaviewSpacing.md, DanaviewSpacing.lg),
              sliver: SliverGrid.builder(
                key: const ValueKey('media-grid'),
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 156,
                  mainAxisExtent: cardHeight,
                  mainAxisSpacing: DanaviewSpacing.sm,
                  crossAxisSpacing: DanaviewSpacing.sm,
                ),
                itemCount: shown.length,
                itemBuilder: (context, i) {
                  final asset = shown[i];
                  final used = usage[asset.id] ?? 0;
                  final availability = health[asset.id];
                  return _MediaCard(
                    key: ValueKey('media-card-${asset.id.value}'),
                    asset: asset,
                    used: used,
                    badge: _Badge.of(asset, availability),
                    previewed: asset.id == _previewed,
                    thumbs: _thumbs,
                    ops: ops,
                    projectId: id,
                    actions: _CardActions(
                      add: () => _add(asset),
                      overlay: () => _overlay(asset),
                      replace: () => _replace(asset),
                      relink: _relink,
                      info: () => _info(asset, used, availability),
                      remove: () => _remove(asset),
                    ),
                    onTap: () => _preview(asset),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// What a card (or the preview strip) can do; each callback explains itself when it refuses.
class _CardActions {
  const _CardActions({
    required this.add,
    required this.overlay,
    required this.replace,
    required this.relink,
    required this.info,
    required this.remove,
  });

  final VoidCallback add;
  final VoidCallback overlay;
  final VoidCallback replace;
  final VoidCallback relink;
  final VoidCallback info;
  final VoidCallback remove;
}

// =================================================================================================
// Header and filters
// =================================================================================================

class _Header extends StatelessWidget {
  const _Header({
    required this.platform,
    required this.picking,
    required this.editable,
    required this.addToTimeline,
    required this.onPick,
    required this.onAddToTimeline,
  });

  final TargetPlatform platform;
  final bool picking;
  final bool editable;
  final bool addToTimeline;
  final ValueChanged<MediaPickSource> onPick;
  final ValueChanged<bool> onAddToTimeline;

  @override
  Widget build(BuildContext context) {
    final enabled = editable && !picking;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: DanaviewSpacing.sm,
          runSpacing: DanaviewSpacing.sm,
          children: [
            DanaviewButton.tonal(
              key: const ValueKey('media-pick-photos'),
              label: MediaStrings.photosButton(platform),
              icon: Icons.photo_library_rounded,
              size: DanaviewButtonSize.sm,
              onPressed: enabled ? () => onPick(MediaPickSource.photos) : null,
            ),
            DanaviewButton.tonal(
              key: const ValueKey('media-pick-files'),
              label: MediaStrings.filesButton,
              icon: Icons.folder_open_rounded,
              size: DanaviewButtonSize.sm,
              onPressed: enabled ? () => onPick(MediaPickSource.files) : null,
            ),
          ],
        ),
        DanaviewSwitchRow(
          key: const ValueKey('media-add-to-timeline'),
          title: MediaStrings.addToTimeline,
          subtitle: MediaStrings.addToTimelineHint,
          value: addToTimeline,
          dense: true,
          onChanged: onAddToTimeline,
        ),
      ],
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({required this.filters, required this.selected, required this.onSelected});

  final List<MediaBinFilter> filters;
  final MediaBinFilter selected;
  final ValueChanged<MediaBinFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    return DanaviewChipGroup(
      spacing: DanaviewSpacing.sm,
      children: [
        for (final f in filters)
          DanaviewChoiceChip(
            key: ValueKey('media-filter-${f.name}'),
            label: f.label,
            selected: f == selected,
            onTap: () => onSelected(f),
          ),
      ],
    );
  }
}

// =================================================================================================
// Thumbnails
// =================================================================================================

/// Decoded poster bytes by asset and height, kept while the panel lives (cards scroll in and out).
final class _ThumbStore {
  final Map<String, Uint8List> _tiles = {};

  String keyOf(MediaAsset asset, int heightPx) => '${asset.fingerprint.quickHash}:${asset.id.value}:$heightPx';

  Uint8List? get(String key) => _tiles[key];

  void put(String key, Uint8List bytes) {
    if (_tiles.length >= 120) _tiles.remove(_tiles.keys.first);
    _tiles[key] = bytes;
  }
}

/// A poster of [asset] from the engine's thumbnail source, or [fallback] while it loads, when it
/// can't be made (offline, audio, a LUT) or when the engine returns nothing.
class _MediaThumb extends ConsumerStatefulWidget {
  const _MediaThumb({required this.projectId, required this.asset, required this.heightPx, required this.store, required this.fallback});

  final ProjectId projectId;
  final MediaAsset asset;
  final int heightPx;
  final _ThumbStore store;
  final Widget fallback;

  @override
  ConsumerState<_MediaThumb> createState() => _MediaThumbState();
}

class _MediaThumbState extends ConsumerState<_MediaThumb> {
  Uint8List? _bytes;
  ThumbnailHandle? _handle;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_MediaThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id ||
        oldWidget.asset.fingerprint.quickHash != widget.asset.fingerprint.quickHash ||
        oldWidget.heightPx != widget.heightPx) {
      _cancel();
      _bytes = null;
      _load();
    }
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  void _cancel() {
    _handle?.cancel();
    _handle = null;
  }

  void _load() {
    final asset = widget.asset;
    if (asset.kind == MediaKind.audio || asset.kind == MediaKind.recording || asset.kind == MediaKind.lut) return;
    final key = widget.store.keyOf(asset, widget.heightPx);
    final cached = widget.store.get(key);
    if (cached != null) {
      _bytes = cached;
      return;
    }
    try {
      final session = ref.read(editorSessionProvider(widget.projectId));
      final project = session.committedProject;
      final media = project == null ? null : session.compiler?.resolve(project, asset.id);
      if (media == null) return;
      final handle = ref.read(editorEngineProvider).thumbnails.request(
            ThumbnailRequest(media: media, intervalMs: 1000, tileIndex: 0, heightPx: widget.heightPx, framesPerTile: 1),
            priority: ThumbPriority.visible,
          );
      _handle = handle;
      unawaited(handle.result.then<void>((tile) {
        if (!mounted || !identical(_handle, handle)) return;
        if (tile.encoded.isEmpty) return;
        widget.store.put(key, tile.encoded);
        setState(() => _bytes = tile.encoded);
      }, onError: (Object _) {}));
    } on Object catch (e) {
      debugPrint('[MediaPanel] Thumbnail request failed: ${e.runtimeType}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return widget.fallback;
    return ExcludeSemantics(
      child: Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
        errorBuilder: (context, error, stack) => widget.fallback,
      ),
    );
  }
}

Widget _kindPlaceholder(MediaKind kind, {double size = 28}) => ColoredBox(
      color: DanaviewColors.surfaceElevatedHigher,
      child: Center(child: Icon(MediaBin.iconOf(kind), size: size, color: DanaviewColors.textMuted)),
    );

// =================================================================================================
// Card
// =================================================================================================

class _MediaCard extends StatelessWidget {
  const _MediaCard({
    super.key,
    required this.asset,
    required this.used,
    required this.badge,
    required this.previewed,
    required this.thumbs,
    required this.ops,
    required this.projectId,
    required this.actions,
    required this.onTap,
  });

  /// Height of the thumbnail area.
  static const double thumbHeight = 78;

  final MediaAsset asset;
  final int used;
  final _Badge? badge;
  final bool previewed;
  final _ThumbStore thumbs;
  final MediaOperations ops;
  final ProjectId projectId;
  final _CardActions actions;
  final VoidCallback onTap;

  List<DanaviewMenuEntry> _menu() {
    final visual = isVisualMediaKind(asset.kind);
    final placeable = asset.kind != MediaKind.lut && asset.status is! FailedStatus;
    final replace = ops.replaceBlocker(asset);
    final remove = ops.removeBlocker(asset.id);
    return [
      DanaviewMenuItem(
          label: MediaStrings.addAtPlayhead,
          icon: Icons.add_rounded,
          enabled: placeable,
          subtitle: placeable ? null : _placeReason(),
          onTap: actions.add),
      DanaviewMenuItem(
        label: MediaStrings.addAsOverlay,
        icon: Icons.layers_rounded,
        enabled: placeable && visual,
        subtitle: placeable && visual ? null : (visual ? _placeReason() : MediaStrings.overlayNeedsVisual),
        onTap: actions.overlay,
      ),
      DanaviewMenuItem(
        label: MediaStrings.replaceSelected,
        icon: Icons.swap_horiz_rounded,
        enabled: replace == null,
        subtitle: replace,
        onTap: actions.replace,
      ),
      if (badge?.offline ?? false) DanaviewMenuItem(label: MediaStrings.relink, icon: Icons.link_rounded, onTap: actions.relink),
      const DanaviewMenuDivider(),
      DanaviewMenuItem(label: MediaStrings.info, icon: Icons.info_outline_rounded, onTap: actions.info),
      DanaviewMenuItem(
        label: MediaStrings.remove,
        icon: Icons.delete_outline_rounded,
        destructive: true,
        enabled: remove == null,
        subtitle: remove,
        onTap: actions.remove,
      ),
    ];
  }

  String _placeReason() => asset.kind == MediaKind.lut ? MediaStrings.lutNotPlaceable : MediaStrings.assetFailed;

  @override
  Widget build(BuildContext context) {
    final touch = context.isTouchPlatform;
    final duration = MediaBin.durationLabel(asset);
    final placeable = asset.kind != MediaKind.lut && asset.status is! FailedStatus;
    final name = asset.displayName;
    final data = MediaDragData(project: projectId, media: [asset.id], label: name);
    final card = DanaviewSurface(
      color: DanaviewColors.surfaceElevated,
      borderRadius: DanaviewRadius.mdAll,
      shadow: DanaviewShadow.subtle,
      borderColor: previewed ? DanaviewColors.primaryLight : DanaviewColors.hairline,
      child: DanaviewPressable(
        onTap: onTap,
        isButton: false,
        borderRadius: DanaviewRadius.mdAll,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: thumbHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _MediaThumb(projectId: projectId, asset: asset, heightPx: 96, store: thumbs, fallback: _kindPlaceholder(asset.kind)),
                  if (badge != null)
                    Positioned(
                      left: DanaviewSpacing.xs,
                      top: DanaviewSpacing.xs,
                      right: 40,
                      child: Align(alignment: AlignmentDirectional.topStart, child: _SolidBadge(badge: badge!)),
                    ),
                  if (duration != null)
                    Positioned(
                      left: DanaviewSpacing.xs,
                      bottom: DanaviewSpacing.xs,
                      right: 40,
                      child: Align(alignment: AlignmentDirectional.bottomStart, child: _DurationChip(text: duration)),
                    ),
                  PositionedDirectional(
                    top: 0,
                    end: 0,
                    child: DanaviewMenuAnchor(
                      width: 240,
                      alignment: DanaviewMenuAlignment.end,
                      entries: _menu(),
                      builder: (context, open, isOpen) => DanaviewIconButton(
                        key: ValueKey('media-menu-${asset.id.value}'),
                        icon: Icons.more_horiz_rounded,
                        size: 28,
                        iconSize: 16,
                        variant: DanaviewIconButtonVariant.filled,
                        selected: isOpen,
                        tooltip: MediaStrings.menuButton(name),
                        onPressed: open,
                      ),
                    ),
                  ),
                  PositionedDirectional(
                    bottom: 0,
                    end: 0,
                    child: DanaviewIconButton(
                      key: ValueKey('media-add-${asset.id.value}'),
                      icon: Icons.add_rounded,
                      size: 28,
                      iconSize: 18,
                      variant: DanaviewIconButtonVariant.primary,
                      tooltip: MediaStrings.addButton(name),
                      onPressed: placeable ? actions.add : null,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(DanaviewSpacing.sm, DanaviewSpacing.xs, DanaviewSpacing.sm, DanaviewSpacing.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      ExcludeSemantics(child: Icon(MediaBin.iconOf(asset.kind), size: 13, color: DanaviewColors.textSecondary)),
                      const SizedBox(width: DanaviewSpacing.xs),
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DanaviewTextStyles.label.copyWith(fontFamily: DanaviewFonts.family, height: 1.3),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    MediaStrings.used(used),
                    key: ValueKey('media-used-${asset.id.value}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary, height: 1.3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    final feedback = _DragFeedback(asset: asset);
    final draggable = touch
        ? LongPressDraggable<MediaDragData>(
            data: data,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            maxSimultaneousDrags: 1,
            feedback: feedback,
            childWhenDragging: Opacity(opacity: 0.4, child: card),
            onDragStarted: HapticFeedback.mediumImpact,
            child: card,
          )
        : Draggable<MediaDragData>(
            data: data,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            maxSimultaneousDrags: 1,
            feedback: feedback,
            childWhenDragging: Opacity(opacity: 0.4, child: card),
            child: card,
          );

    final status = badge?.label;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: MediaStrings.cardSemantics(name: name, kind: asset.kind, duration: duration, used: used, status: status),
      hint: MediaStrings.cardHint,
      selected: previewed,
      onTap: onTap,
      customSemanticsActions: {
        CustomSemanticsAction(label: MediaStrings.addAtPlayhead): actions.add,
        if (isVisualMediaKind(asset.kind)) CustomSemanticsAction(label: MediaStrings.addAsOverlay): actions.overlay,
        CustomSemanticsAction(label: MediaStrings.replaceSelected): actions.replace,
        CustomSemanticsAction(label: MediaStrings.info): actions.info,
        CustomSemanticsAction(label: MediaStrings.remove): actions.remove,
      },
      child: draggable,
    );
  }
}

class _SolidBadge extends StatelessWidget {
  const _SolidBadge({required this.badge});

  final _Badge badge;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(color: DanaviewColors.surface, borderRadius: DanaviewRadius.xsAll),
        child: DanaviewBadge(badge.label, color: badge.color, icon: badge.icon),
      );
}

class _DurationChip extends StatelessWidget {
  const _DurationChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(color: DanaviewColors.surface, borderRadius: DanaviewRadius.xsAll),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(
            text,
            maxLines: 1,
            style: DanaviewTextStyles.caption.copyWith(
              fontFamily: DanaviewFonts.family,
              color: DanaviewColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      );
}

/// What follows the pointer while a card is dragged.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.asset});

  final MediaAsset asset;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: DefaultTextStyle(
          style: DanaviewTextStyles.label.copyWith(fontFamily: DanaviewFonts.family),
          child: Transform.translate(
            offset: const Offset(-24, -48),
            child: DanaviewSurface(
              color: DanaviewColors.surfaceElevatedHigher,
              borderRadius: DanaviewRadius.smAll,
              shadow: DanaviewShadow.soft,
              padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.sm, vertical: DanaviewSpacing.xs),
              constraints: const BoxConstraints(maxWidth: 200),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(MediaBin.iconOf(asset.kind), size: 16, color: DanaviewColors.textSecondary),
                  const SizedBox(width: DanaviewSpacing.xs),
                  Flexible(child: Text(asset.displayName, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
          ),
        ),
      );
}

// =================================================================================================
// Preview strip
// =================================================================================================

/// Tap on a card: a large poster, the facts and every action, with no change to the timeline.
class _PreviewStrip extends StatelessWidget {
  const _PreviewStrip({
    super.key,
    required this.projectId,
    required this.asset,
    required this.used,
    required this.badge,
    required this.thumbs,
    required this.ops,
    required this.actions,
    required this.onClose,
  });

  final ProjectId projectId;
  final MediaAsset asset;
  final int used;
  final _Badge? badge;
  final _ThumbStore thumbs;
  final MediaOperations ops;
  final _CardActions actions;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final placeable = asset.kind != MediaKind.lut && asset.status is! FailedStatus;
    final visual = isVisualMediaKind(asset.kind);
    final replace = ops.replaceBlocker(asset);
    final remove = ops.removeBlocker(asset.id);
    return Semantics(
      container: true,
      label: '${MediaStrings.previewRegion}, ${asset.displayName}',
      child: DanaviewSurface(
        color: DanaviewColors.surfaceElevated,
        borderRadius: DanaviewRadius.lgAll,
        shadow: DanaviewShadow.subtle,
        padding: const EdgeInsets.all(DanaviewSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 140),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: DanaviewRadius.smAll,
                  child: _MediaThumb(
                      projectId: projectId, asset: asset, heightPx: 192, store: thumbs, fallback: _kindPlaceholder(asset.kind, size: 40)),
                ),
              ),
            ),
            const SizedBox(height: DanaviewSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        asset.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: DanaviewTextStyles.headline.copyWith(fontFamily: DanaviewFonts.family),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        MediaBin.describe(asset),
                        key: const ValueKey('media-preview-facts'),
                        style:
                            DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary, height: 1.35),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        MediaStrings.used(used),
                        style:
                            DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary, height: 1.35),
                      ),
                      if (badge != null) ...[
                        const SizedBox(height: DanaviewSpacing.xs),
                        Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: DanaviewBadge(badge!.label, color: badge!.color, icon: badge!.icon)),
                      ],
                    ],
                  ),
                ),
                DanaviewIconButton(
                  key: const ValueKey('media-preview-close'),
                  icon: Icons.close_rounded,
                  size: 32,
                  iconSize: 18,
                  color: DanaviewColors.textSecondary,
                  tooltip: MediaStrings.closePreview,
                  onPressed: onClose,
                ),
              ],
            ),
            const SizedBox(height: DanaviewSpacing.sm),
            Wrap(
              spacing: DanaviewSpacing.sm,
              runSpacing: DanaviewSpacing.sm,
              children: [
                DanaviewButton.primary(
                  key: const ValueKey('media-preview-add'),
                  label: MediaStrings.addAtPlayhead,
                  icon: Icons.add_rounded,
                  size: DanaviewButtonSize.sm,
                  onPressed: placeable ? actions.add : null,
                ),
                if (visual)
                  DanaviewButton.secondary(
                    key: const ValueKey('media-preview-overlay'),
                    label: MediaStrings.addAsOverlay,
                    icon: Icons.layers_rounded,
                    size: DanaviewButtonSize.sm,
                    onPressed: placeable ? actions.overlay : null,
                  ),
                DanaviewButton.secondary(
                  key: const ValueKey('media-preview-replace'),
                  label: MediaStrings.replaceSelected,
                  icon: Icons.swap_horiz_rounded,
                  size: DanaviewButtonSize.sm,
                  tooltip: replace,
                  onPressed: replace == null ? actions.replace : null,
                ),
                if (badge?.offline ?? false)
                  DanaviewButton.secondary(
                    key: const ValueKey('media-preview-relink'),
                    label: MediaStrings.relink,
                    icon: Icons.link_rounded,
                    size: DanaviewButtonSize.sm,
                    onPressed: actions.relink,
                  ),
                DanaviewButton.ghost(
                  key: const ValueKey('media-preview-info'),
                  label: MediaStrings.info,
                  icon: Icons.info_outline_rounded,
                  size: DanaviewButtonSize.sm,
                  onPressed: actions.info,
                ),
                DanaviewButton.destructive(
                  key: const ValueKey('media-preview-remove'),
                  label: MediaStrings.remove,
                  icon: Icons.delete_outline_rounded,
                  size: DanaviewButtonSize.sm,
                  tooltip: remove,
                  onPressed: remove == null ? actions.remove : null,
                ),
              ],
            ),
            if (!placeable)
              Padding(
                padding: const EdgeInsets.only(top: DanaviewSpacing.xs),
                child: Text(
                  asset.kind == MediaKind.lut ? MediaStrings.lutNotPlaceable : MediaStrings.assetFailed,
                  key: const ValueKey('media-preview-place-reason'),
                  style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary, height: 1.35),
                ),
              )
            else if (replace != null)
              Padding(
                padding: const EdgeInsets.only(top: DanaviewSpacing.xs),
                child: Text(
                  replace,
                  key: const ValueKey('media-preview-replace-reason'),
                  style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary, height: 1.35),
                ),
              ),
            if (remove != null)
              Padding(
                padding: const EdgeInsets.only(top: DanaviewSpacing.xs),
                child: Text(
                  remove,
                  key: const ValueKey('media-preview-remove-reason'),
                  style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary, height: 1.35),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// =================================================================================================
// Info sheet
// =================================================================================================

/// The "Info" sheet of a media asset: its facts, where it is stored and how it is used.
class MediaInfoSheet extends StatelessWidget {
  /// Creates the sheet content.
  const MediaInfoSheet({super.key, required this.asset, required this.used, this.availability});

  /// The asset.
  final MediaAsset asset;

  /// Clips that use it.
  final int used;

  /// Its availability, when known.
  final MediaAvailability? availability;

  @override
  Widget build(BuildContext context) {
    final p = asset.probe;
    final w = p.width, h = p.height;
    final swap = p.rotation % 180 != 0;
    final badge = _Badge.of(asset, availability);
    final rows = <(String, String)>[
      (MediaStrings.infoName, asset.displayName),
      (MediaStrings.infoKind, MediaStrings.kindName(asset.kind)),
      if (MediaBin.durationLabel(asset) case final d?) (MediaStrings.infoDuration, d),
      if (w != null && h != null && w > 0 && h > 0) (MediaStrings.infoResolution, '${swap ? h : w}×${swap ? w : h}'),
      if (p.nominalFps != null && p.nominalFps! > 0) (MediaStrings.infoFrameRate, MediaStrings.fps(p.nominalFps!)),
      if (p.videoCodec != null) (MediaStrings.infoVideoCodec, p.videoCodec!),
      if (p.audioCodec != null) (MediaStrings.infoAudioCodec, p.audioCodec!),
      if (asset.fingerprint.sizeBytes > 0) (MediaStrings.infoSize, formatDataSize(asset.fingerprint.sizeBytes)),
      (
        MediaStrings.infoLocation,
        switch (asset.ownership) {
          MediaOwnership.external => MediaStrings.locationExternal,
          MediaOwnership.managedCopy => MediaStrings.locationManaged,
          MediaOwnership.projectOwned => MediaStrings.locationProject,
        }
      ),
      (MediaStrings.infoUsage, MediaStrings.used(used)),
      (
        MediaStrings.infoStatus,
        badge == null ? MediaStrings.statusAvailable : (badge == _Badge.processing ? MediaStrings.statusProcessing : badge.label)
      ),
    ];
    return Column(
      key: const ValueKey('media-info-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.xs + 1),
            child: Semantics(
              container: true,
              label: '$label, $value',
              child: ExcludeSemantics(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 110,
                      child: Text(label,
                          style: DanaviewTextStyles.caption
                              .copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary, height: 1.35)),
                    ),
                    Expanded(child: Text(value, style: DanaviewTextStyles.body.copyWith(fontFamily: DanaviewFonts.family))),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
