// OWNER: UX-23
//
// The Crop panel (ux.md §7.5): crop mode for one picture clip.
//
// * While the panel is open the preview is in crop mode: `PreviewToolController.enterCrop(item)`
//   switches the native editing mode to `cropSource(item)` (the clip's uncropped, untransformed
//   source fitted to the canvas) and shows `CropOverlay`, whose handles and frame drags each commit
//   one "Crop" entry. Closing the panel (Done, the header, back, another selection) leaves crop mode
//   and returns the preview to normal.
// * Aspect chips Free, Original, 16:9, 9:16, 1:1, 4:5, 4:3: picking one other than Free sets the
//   largest crop of that aspect centred on the current crop (one "Crop to 16:9" entry) and makes the
//   frame keep that aspect while dragging; the chip of the current crop is highlighted.
// * Rotate 90° (clockwise, keyframe-aware at the playhead), Flip H/V, Reset (the full source) and
//   Done. The readout shows the kept size in source pixels.
// * The header's reset is the panel's Reset.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/eval.dart' show Size2, evaluate;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show CompositeCommand, EditCommand, SetCrop, SetProperty;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/transform_strings.dart';
import '../contracts/inspector_routes.dart';
import '../editor_scope.dart';
import '../inspector/inspector_header.dart';
import '../preview/crop_overlay.dart';
import '../state/editor_controller.dart';
import 'transform_panel.dart' show FlipRow, PanelNotice, TransformCommands;

/// Commands of the crop panel.
abstract final class CropCommands {
  /// The largest crop of [aspect] around the current one ("Crop to 16:9").
  static EditCommand aspect(MediaClip clip, CropAspect aspect, Size2 source) => CompositeCommand(
        TransformStrings.historyCropAspect(aspect.label),
        [SetCrop([clip.id], CropMath.forAspect(clip.visual!.crop, aspect, source))],
      );

  /// The full source ("Reset crop").
  static EditCommand reset(ItemId item) => CompositeCommand(TransformStrings.historyResetCrop, [SetCrop([item], CropRect.full)]);

  /// Rotates [item] 90° clockwise at absolute [at] ("Rotate 90°"); wraps past 360° to stay in range.
  static EditCommand rotate90(TimelineItem item, TimeUs at) {
    final local = TransformCommands.localTime(item, at);
    final current = evaluate(item, PropertyKeys.rotation, local);
    var next = current + 90;
    if (next > 360) next -= 360;
    return CompositeCommand(TransformStrings.historyRotate90, [SetProperty<double>([item.id], PropertyKeys.rotation, next, at: at)]);
  }
}

/// The crop (ux.md §7.5).
class CropPanel extends ConsumerStatefulWidget {
  /// Creates the panel.
  const CropPanel({super.key, required this.route});

  /// What the panel edits.
  final CropInspector route;

  @override
  ConsumerState<CropPanel> createState() => _CropPanelState();
}

class _CropPanelState extends ConsumerState<CropPanel> {
  PreviewToolController? _tools;
  CropAspect _aspect = CropAspect.free;

  EditorController get _editor => ref.read(editorControllerProvider(EditorScope.idOf(context)).notifier);

  @override
  void didUpdateWidget(CropPanel old) {
    super.didUpdateWidget(old);
    if (old.route.item != widget.route.item) {
      final tools = _tools;
      final from = old.route.item;
      final to = widget.route.item;
      _aspect = CropAspect.free;
      // The tool notifies the preview layer: never during a build or an unmount.
      afterFrame(() {
        tools?.exit<CropPreviewTool>(from);
        if (mounted && identical(tools, _tools)) tools?.enterCrop(to);
      });
    }
  }

  @override
  void dispose() {
    final tools = _tools;
    final item = widget.route.item;
    afterFrame(() => tools?.exit<CropPreviewTool>(item));
    super.dispose();
  }

  void _bind(PreviewToolController tools) {
    if (identical(tools, _tools)) return;
    final old = _tools;
    _tools = tools;
    final item = widget.route.item;
    afterFrame(() {
      old?.exit<CropPreviewTool>(item);
      if (!mounted || !identical(tools, _tools)) return;
      tools.enterCrop(widget.route.item);
      tools.setCropAspect(_aspect);
    });
  }

  void _pickAspect(MediaClip clip, Size2 source, CropAspect aspect) {
    setState(() => _aspect = aspect);
    _tools?.setCropAspect(aspect);
    if (aspect == CropAspect.free) return;
    final next = CropMath.forAspect(clip.visual!.crop, aspect, source);
    if (next == clip.visual!.crop) return;
    _editor.apply(CropCommands.aspect(clip, aspect, source));
  }

  void _reset() {
    setState(() => _aspect = CropAspect.free);
    _tools?.setCropAspect(CropAspect.free);
    _editor.apply(CropCommands.reset(widget.route.item));
  }

  @override
  Widget build(BuildContext context) {
    final id = EditorScope.idOf(context);
    _bind(ref.watch(previewToolProvider(id)));
    final project = ref.watch(editorControllerProvider(id).select((s) => s.project));
    final item = project?.index.item(widget.route.item);
    if (project == null || item is! MediaClip || item.visual == null) return const SizedBox.shrink();
    final locked = project.index.locate(item.id)?.track.locked ?? false;
    final ready = ref.watch(editorControllerProvider(id).select((s) => s.isReady)) && !locked;
    final source = pictureSizeOf(project, item);
    final crop = item.visual!.crop;
    final shown = _aspect == CropAspect.free || source == null ? _aspect : (CropMath.matching(crop, source) ?? CropAspect.free);
    return InspectorHeaderActions.publish(
      actions: InspectorHeaderActions(onReset: ready ? _reset : null),
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(DanaviewSpacing.lg, DanaviewSpacing.sm, DanaviewSpacing.lg, DanaviewSpacing.lg),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (locked) const PanelNotice(TransformStrings.trackLocked),
                  if (source == null) const PanelNotice(TransformStrings.cropUnavailable, color: DanaviewColors.textMuted),
                  Text(TransformStrings.aspect, style: _label),
                  const SizedBox(height: DanaviewSpacing.xs),
                  Semantics(
                    container: true,
                    label: TransformStrings.aspect,
                    child: DanaviewChipGroup(
                      children: [
                        for (final a in CropAspect.values)
                          DanaviewChoiceChip(
                            key: ValueKey<String>('crop.aspect.${a.name}'),
                            label: a.label,
                            selected: a == shown,
                            enabled: ready && source != null,
                            onTap: ready && source != null ? () => _pickAspect(item, source, a) : null,
                          ),
                      ],
                    ),
                  ),
                  if (source != null) ...[
                    const SizedBox(height: DanaviewSpacing.sm),
                    Text(
                      TransformStrings.cropSize(CropMath.pixels(crop, source).$1, CropMath.pixels(crop, source).$2),
                      key: const ValueKey<String>('crop.size'),
                      style: _caption,
                    ),
                  ],
                  const SizedBox(height: DanaviewSpacing.sm),
                  FlipRow(item: item, enabled: ready, onFlip: (h) => _editor.apply(TransformCommands.flip(item, horizontal: h))),
                  const SizedBox(height: DanaviewSpacing.md),
                  Wrap(
                    spacing: DanaviewSpacing.sm,
                    runSpacing: DanaviewSpacing.sm,
                    children: [
                      DanaviewButton.secondary(
                        key: const ValueKey<String>('crop.rotate'),
                        label: TransformStrings.rotate90,
                        icon: Icons.rotate_90_degrees_cw_rounded,
                        onPressed: ready ? () => _editor.apply(CropCommands.rotate90(item, ref.read(playheadProvider(id)).value)) : null,
                      ),
                      DanaviewButton.ghost(
                        key: const ValueKey<String>('crop.reset'),
                        label: TransformStrings.resetCrop,
                        icon: Icons.settings_backup_restore_rounded,
                        onPressed: ready && !crop.isFull ? _reset : null,
                      ),
                      DanaviewButton.primary(
                        key: const ValueKey<String>('crop.done'),
                        label: TransformStrings.done,
                        icon: Icons.check_rounded,
                        onPressed: _editor.closeInspector,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

TextStyle get _label => DanaviewTextStyles.body.copyWith(fontFamily: DanaviewFonts.family);

TextStyle get _caption => DanaviewTextStyles.caption.copyWith(
      fontFamily: DanaviewFonts.family,
      color: DanaviewColors.textSecondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
