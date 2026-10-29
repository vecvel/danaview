// OWNER: UX-28
//
// The Overlay (picture-in-picture) panel (ux.md §10.13), a project panel opened by the Overlay tool.
// Constructor contract: `OverlayPanel({Key? key, required OverlayInspector route})` (InspectorHost
// builds panels with it).
//
// * "Add video overlay" / "Add image overlay" run the engine's photo picker for that kind and import
//   the picks through UX-06's import sheet; `OverlayOperations.importJob` places them as an overlay
//   at the playhead (the topmost overlay lane free there, a new lane when needed; 40 % at
//   centre-right; one history entry), selects the new overlay and opens the Transform panel. Several
//   overlays stack on their own lanes, each with its own timing.
// * The list shows every overlay clip front to back (top lane first); a row selects that overlay and
//   moves the playhead into it when it is elsewhere, so the preview shows it.
// * With an overlay selected: Bring forward / Send backward (`OverlayOperations.moveZ`, moves
//   between overlay lanes; disabled with the reason at the front / back or on locked tracks) and
//   shortcuts to its Transform (position, size, rotation, opacity; the manipulation overlay edits
//   the same), Crop, Chroma key and Mask panels.

import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show MediaPickKind, MediaPickRequest, MediaPickSource;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/overlay_strings.dart';
import '../actions/bindings/overlay_bindings.dart';
import '../contracts/inspector_routes.dart';
import '../editor_scope.dart';
import '../flows/import_media_sheet.dart';
import '../state/edit_transaction.dart' show EditApplied;
import '../timeline/timeline_semantics.dart' show EditorAnnouncer, editorAnnounce;
import 'transform_panel.dart' show PanelNotice;

/// The overlay panel (ux.md §10.13).
class OverlayPanel extends ConsumerStatefulWidget {
  /// Creates the panel.
  const OverlayPanel({super.key, required this.route});

  /// What the panel edits.
  final OverlayInspector route;

  @override
  ConsumerState<OverlayPanel> createState() => _OverlayPanelState();
}

class _OverlayPanelState extends ConsumerState<OverlayPanel> {
  bool _picking = false;

  ProjectId get _id => EditorScope.idOf(context);

  OverlayOperations get _ops => OverlayOperations.forProject(_id, ref.read);

  void _toast(String message, {IconData? icon, DanaviewToastKind kind = DanaviewToastKind.info}) {
    if (!mounted) return;
    DanaviewToast.show(context, message, icon: icon, kind: kind);
    editorAnnounce(context, message);
  }

  /// Picks a video ([video]) or a photo and adds it as an overlay.
  Future<void> _add({required bool video}) async {
    if (_picking) return;
    final ops = _ops;
    if (!ops.canAdd) return _toast(OverlayStrings.cannotAdd);
    final edit = ops.media.session.editOrNull;
    if (edit == null) return _toast(OverlayStrings.cannotAdd);
    final at = ops.media.playhead;
    setState(() => _picking = true);
    try {
      final picked = await ref
          .read(editorEngineProvider)
          .picker
          .pick(MediaPickRequest(source: MediaPickSource.photos, kinds: {video ? MediaPickKind.video : MediaPickKind.image}));
      if (!mounted || picked.isEmpty) return;
      var placed = false;
      final job = ops.importJob(
        pool: ref.read(mediaPoolServiceProvider),
        edit: edit,
        at: at,
        onPlaced: (result) => placed = result is EditApplied,
      );
      // The panel goes away when the Transform panel opens: announce through the view.
      final view = View.maybeOf(context);
      final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
      final result = await showImportMediaSheet(context, picks: picked, job: job, title: OverlayStrings.importTitle);
      if (placed) {
        unawaited(HapticFeedback.lightImpact());
        if (view != null) EditorAnnouncer.instance.announce(view, OverlayStrings.added, textDirection: direction);
      } else if (result?.job != null && result!.job!.addedCount > 0) {
        _toast(OverlayStrings.nothingAdded);
      }
    } on Object catch (e) {
      debugPrint('[OverlayPanel] Picker failed: ${e.runtimeType}');
      _toast(OverlayStrings.pickerFailed, icon: Icons.error_outline_rounded, kind: DanaviewToastKind.error);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// Selects [entry] and brings the playhead into it when it is elsewhere.
  void _select(OverlayClipEntry entry) {
    final id = _id;
    ref.read(editorControllerProvider(id).notifier).select(entry.clip.id);
    final playhead = ref.read(playheadProvider(id));
    final t = playhead.value;
    if (!entry.clip.range.contains(t)) playhead.seekExact(entry.clip.start).ignore();
  }

  @override
  Widget build(BuildContext context) {
    final id = _id;
    final project = ref.watch(editorControllerProvider(id).select((s) => s.project));
    final selection = ref.watch(editorControllerProvider(id).select((s) => s.selection));
    ref.watch(editorControllerProvider(id).select((s) => s.isReady));
    if (project == null) return const SizedBox.shrink();
    final ops = _ops;
    final canAdd = ops.canAdd && !_picking;
    final entries = OverlayZOrder.entries(project);
    final primary = selection.primary ?? (selection.items.length == 1 ? selection.items.first : null);
    final selected = primary == null ? null : entries.where((e) => e.clip.id == primary).firstOrNull;

    final children = <Widget>[
      if (!ops.canAdd) const PanelNotice(OverlayStrings.cannotAdd),
      DanaviewButtonBar(
        reverseWhenStacked: false,
        children: [
          DanaviewButton.primary(
            key: const ValueKey<String>('overlay.addVideo'),
            label: OverlayStrings.addVideo,
            icon: Icons.video_library_rounded,
            onPressed: canAdd ? () => _add(video: true) : null,
          ),
          DanaviewButton.secondary(
            key: const ValueKey<String>('overlay.addImage'),
            label: OverlayStrings.addImage,
            icon: Icons.add_photo_alternate_rounded,
            onPressed: canAdd ? () => _add(video: false) : null,
          ),
        ],
      ),
      const SizedBox(height: DanaviewSpacing.xs),
      const PanelNotice(OverlayStrings.addHint, color: DanaviewColors.textMuted),
      DanaviewSectionHeader(
        OverlayStrings.listTitle(entries.length),
        subtitle: entries.length > 1 ? OverlayStrings.listOrder : null,
      ),
      if (entries.isEmpty)
        const PanelNotice(OverlayStrings.empty, color: DanaviewColors.textMuted)
      else
        for (final e in entries)
          _OverlayRow(
            key: ValueKey<String>('overlay.row.${e.clip.id}'),
            entry: e,
            name: project.pool[e.clip.media]?.displayName ?? OverlayStrings.unnamed,
            kind: project.pool[e.clip.media]?.kind,
            selected: selected?.clip.id == e.clip.id,
            onTap: () => _select(e),
          ),
      const DanaviewSectionHeader(OverlayStrings.selectedTitle),
      if (selected == null)
        const PanelNotice(OverlayStrings.selectHint, color: DanaviewColors.textMuted)
      else
        _SelectedOverlay(entry: selected, ops: ops),
    ];

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(DanaviewSpacing.lg, DanaviewSpacing.sm, DanaviewSpacing.lg, DanaviewSpacing.lg),
          sliver: SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)),
        ),
      ],
    );
  }
}

/// One overlay in the list.
class _OverlayRow extends StatelessWidget {
  const _OverlayRow({super.key, required this.entry, required this.name, required this.kind, required this.selected, required this.onTap});

  final OverlayClipEntry entry;
  final String name;
  final MediaKind? kind;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final clip = entry.clip;
    final video = kind == MediaKind.video;
    return Semantics(
      hint: OverlayStrings.rowHint,
      child: DanaviewListTile(
        title: name,
        subtitle: OverlayStrings.rowSubtitle(entry.laneName, clip.start, clip.end),
        leading: DanaviewIconTile(video ? Icons.videocam_rounded : Icons.image_rounded),
        trailing: entry.lane.locked ? const Icon(Icons.lock_rounded, size: 16, color: DanaviewColors.textMuted) : null,
        selected: selected,
        dense: true,
        onTap: onTap,
      ),
    );
  }
}

/// Order and tools of the selected overlay.
class _SelectedOverlay extends ConsumerWidget {
  const _SelectedOverlay({required this.entry, required this.ops});

  final OverlayClipEntry entry;
  final OverlayOperations ops;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = entry.clip.id;
    final forwardBlocked = ops.zBlocker(forward: true);
    final backwardBlocked = ops.zBlocker(forward: false);
    final editable = ops.controller.canEdit && !entry.lane.locked;
    final reasons = {
      if (forwardBlocked != null) forwardBlocked,
      if (backwardBlocked != null) backwardBlocked,
    };
    void open(InspectorRoute route) => ops.controller.openInspector(route);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DanaviewButtonBar(
          reverseWhenStacked: false,
          children: [
            DanaviewButton.secondary(
              key: const ValueKey<String>('overlay.forward'),
              label: OverlayStrings.bringForward,
              icon: Icons.flip_to_front_rounded,
              onPressed: forwardBlocked == null ? () => ops.moveZ(item, forward: true) : null,
            ),
            DanaviewButton.secondary(
              key: const ValueKey<String>('overlay.backward'),
              label: OverlayStrings.sendBackward,
              icon: Icons.flip_to_back_rounded,
              onPressed: backwardBlocked == null ? () => ops.moveZ(item, forward: false) : null,
            ),
          ],
        ),
        if (reasons.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: DanaviewSpacing.xs),
            child: PanelNotice(reasons.join('. '), color: DanaviewColors.textMuted),
          ),
        const SizedBox(height: DanaviewSpacing.sm),
        Wrap(
          spacing: DanaviewSpacing.sm,
          runSpacing: DanaviewSpacing.sm,
          children: [
            DanaviewButton.tonal(
              key: const ValueKey<String>('overlay.transform'),
              label: OverlayStrings.transform,
              icon: Icons.open_with_rounded,
              onPressed: editable ? () => open(TransformInspector(item)) : null,
            ),
            DanaviewButton.tonal(
              key: const ValueKey<String>('overlay.crop'),
              label: OverlayStrings.crop,
              icon: Icons.crop_rounded,
              onPressed: editable ? () => open(CropInspector(item)) : null,
            ),
            DanaviewButton.tonal(
              key: const ValueKey<String>('overlay.chroma'),
              label: OverlayStrings.chroma,
              icon: Icons.gradient_rounded,
              onPressed: editable ? () => open(ChromaInspector(item)) : null,
            ),
            DanaviewButton.tonal(
              key: const ValueKey<String>('overlay.mask'),
              label: OverlayStrings.mask,
              icon: Icons.blur_circular_rounded,
              onPressed: editable ? () => open(MaskInspector(item)) : null,
            ),
          ],
        ),
        const SizedBox(height: DanaviewSpacing.xs),
        const PanelNotice(OverlayStrings.toolsHint, color: DanaviewColors.textMuted),
      ],
    );
  }
}
