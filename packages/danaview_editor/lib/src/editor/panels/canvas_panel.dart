// OWNER: UX-29
//
// The Format panel (ux.md §10.14, ARCH §17.7): the project canvas, opened by the `format` tool.
//
// * Aspect ratio: "Original" (the first main clip's aspect, snapped like project creation does),
//   16:9, 9:16, 1:1, 4:5, 4:3, 21:9. A chip is one `SetCanvas(aspect:)` (one "Canvas" entry); the
//   preview letterboxes to the new canvas at once and the toast "Clips keep their size; adjust them
//   with Transform." follows.
// * Background: Colour | Blur. Colour opens the colour picker; a picker gesture is one
//   `SetBackground` transaction (one "Background" entry). Blur is a blurred copy of the main video
//   (`BlurOfMainBackground`) with its amount slider (a drag is one entry, a typed value one entry).
// * Frame rate: 24 / 25 / 30 / 48 / 50 / 60 (D-03) and "Match first clip". Changing the rate of a
//   project that has content asks first (the requantize warning: edges, keys and markers move by at
//   most one frame), then runs one `SetFrameRate`.
// * Resolution base: 720p / 1080p / 4K, 4K only when the device can export it
//   (`EditorCapabilities.maxExportSize`, the same gate as project creation). One `SetCanvas`
//   (baseShortSide:) entry; the canvas size in pixels is shown below.
// * A project that cannot be edited (opening, read-only) shows a notice and disables the controls.
// * The constructor contract `CanvasPanel({Key? key, required CanvasInspector route})` is the one
//   InspectorHost (UX-16) builds panels with.

import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart' hide AspectRatio;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show EditCommand, SetBackground, SetCanvas, SetFrameRate;
import 'package:danaview_editor_core/store.dart' show deriveProjectSettings;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/project_strings.dart';
import '../contracts/inspector_routes.dart';
import '../editor_scope.dart';
import '../inspector/inspector_rows.dart';
import '../state/editor_controller.dart';
import '../state/editor_state.dart';
import 'transform_panel.dart' show PanelNotice;

/// What the Format panel reads of the editor state.
@immutable
final class CanvasPanelView {
  /// Creates the view.
  const CanvasPanelView({required this.settings, required this.original, required this.hasContent, required this.editable});

  /// Reads [state].
  factory CanvasPanelView.of(EditorState state) {
    final project = state.project;
    final editable = state.isReady && state.save.phase != SavePhase.readOnly && project != null;
    if (project == null) {
      return CanvasPanelView(settings: const ProjectSettings(), original: null, hasContent: false, editable: false);
    }
    final hasContent = project.markers.isNotEmpty || project.tracks.any((t) => t.items.isNotEmpty);
    return CanvasPanelView(settings: project.settings, original: CanvasPanelModel.originalOf(project), hasContent: hasContent, editable: editable);
  }

  /// Current settings.
  final ProjectSettings settings;

  /// Settings derived from the first main clip, or null when there is none.
  final ProjectSettings? original;

  /// Whether the timeline has anything a frame-rate change moves.
  final bool hasContent;

  /// Whether the controls accept edits.
  final bool editable;

  @override
  bool operator ==(Object other) =>
      other is CanvasPanelView &&
      other.settings == settings &&
      other.original == original &&
      other.hasContent == hasContent &&
      other.editable == editable;

  @override
  int get hashCode => Object.hash(settings, original, hasContent, editable);
}

/// The choices of the Format panel.
abstract final class CanvasPanelModel {
  /// Aspect chips after "Original" (ux.md §10.14).
  static const List<AspectRatio> aspects = AspectRatio.standard;

  /// Frame-rate chips (D-03).
  static const List<FrameRate> rates = [
    FrameRate.fps24,
    FrameRate.fps25,
    FrameRate.fps30,
    FrameRate.fps48,
    FrameRate.fps50,
    FrameRate.fps60,
  ];

  /// Resolution chips (short side in px).
  static const List<int> shortSides = CanvasSpec.supportedShortSides;

  /// The blur amount a new blur background starts with.
  static const double defaultBlur = 0.5;

  /// Settings derived from the first visual clip of the main lane (like project creation), or null
  /// when the main lane has no clip with known dimensions.
  static ProjectSettings? originalOf(EditProject project) {
    Track? main;
    for (final t in project.tracks) {
      if (t.isMain) main = t;
    }
    if (main == null) return null;
    for (final item in main.items) {
      if (item is! MediaClip) continue;
      final probe = project.pool[item.media]?.probe;
      if (probe == null || probe.width == null || probe.height == null) continue;
      return deriveProjectSettings(probe, allow2160: true);
    }
    return null;
  }

  /// Whether [shortSide] is offered on a device whose largest export is [maxExport].
  static bool allows(int shortSide, Size? maxExport) => shortSide < 2160 || (maxExport != null && maxExport.shortestSide >= 2160);
}

/// The Format panel (ux.md §10.14).
class CanvasPanel extends ConsumerStatefulWidget {
  /// Creates the panel.
  const CanvasPanel({super.key, required this.route});

  /// What the panel edits.
  final CanvasInspector route;

  @override
  ConsumerState<CanvasPanel> createState() => _CanvasPanelState();
}

class _CanvasPanelState extends ConsumerState<CanvasPanel> {
  InspectorEditSession? _color;
  InspectorEditSession? _blur;
  double _lastBlur = CanvasPanelModel.defaultBlur;
  bool _confirming = false;

  @override
  void dispose() {
    _color?.dispose();
    _blur?.dispose();
    super.dispose();
  }

  EditorController get _editor => ref.read(editorControllerProvider(EditorScope.idOf(context)).notifier);

  InspectorEditSession _colorSession() =>
      (_color ??= InspectorEditSession(editor: _editor, label: 'Background', coalesceKey: 'canvas:background'))..editor = _editor;

  InspectorEditSession _blurSession() =>
      (_blur ??= InspectorEditSession(editor: _editor, label: 'Background', coalesceKey: 'canvas:blur'))..editor = _editor;

  bool _apply(EditCommand command) => _editor.apply(command).applied;

  void _setAspect(AspectRatio aspect) {
    if (_apply(SetCanvas(aspect: aspect)) && mounted) {
      DanaviewToast.show(context, ProjectStrings.aspectChanged, icon: Icons.aspect_ratio_rounded);
    }
  }

  void _setShortSide(int side) => _apply(SetCanvas(baseShortSide: side));

  Future<void> _setRate(FrameRate rate, CanvasPanelView view) async {
    if (rate == view.settings.frameRate || _confirming) return;
    if (view.hasContent) {
      _confirming = true;
      try {
        final ok = await showDanaviewConfirm(
          context,
          title: ProjectStrings.frameRateConfirmTitle(rate),
          message: ProjectStrings.frameRateConfirmMessage,
          confirmLabel: ProjectStrings.frameRateConfirm,
          cancelLabel: ProjectStrings.cancel,
          icon: Icons.slow_motion_video_rounded,
        );
        if (!ok || !mounted) return;
      } finally {
        _confirming = false;
      }
    }
    _apply(SetFrameRate(rate));
  }

  void _setMode(bool blur, BackgroundSpec current) {
    switch ((blur, current)) {
      case (true, SolidBackground()):
        _apply(SetBackground(BlurOfMainBackground(_lastBlur)));
      case (false, BlurOfMainBackground(:final radius)):
        _lastBlur = radius;
        _apply(const SetBackground(BackgroundSpec.black));
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = EditorScope.idOf(context);
    final view = ref.watch(editorControllerProvider(id).select(CanvasPanelView.of));
    final editor = ref.read(editorControllerProvider(id).notifier);
    final maxExport = editor.session.capabilities?.maxExportSize ?? ref.watch(editorCapabilitiesProvider).valueOrNull?.maxExportSize;
    final settings = view.settings;
    final enabled = view.editable;
    final canvas = settings.canvas;
    final original = view.original;
    final background = settings.background;
    final blur = background is BlurOfMainBackground;
    if (background is BlurOfMainBackground) _lastBlur = background.radius;
    final allow4k = CanvasPanelModel.allows(2160, maxExport);

    // Aspect chips: "Original" when it is known, the standard ratios, and the current ratio when it
    // is neither (exactly one chip is selected).
    final aspectChips = <Widget>[
      if (original != null)
        DanaviewChoiceChip(
          key: const ValueKey<String>('canvas.aspect.original'),
          label: ProjectStrings.aspectOriginal(original.canvas.aspect),
          selected: canvas.aspect == original.canvas.aspect,
          enabled: enabled,
          onTap: () => _setAspect(original.canvas.aspect),
        ),
      for (final a in CanvasPanelModel.aspects)
        DanaviewChoiceChip(
          key: ValueKey<String>('canvas.aspect.${a.w}x${a.h}'),
          label: ProjectStrings.aspect(a),
          selected: canvas.aspect == a && canvas.aspect != original?.canvas.aspect,
          enabled: enabled,
          onTap: () => _setAspect(a),
        ),
      if (!CanvasPanelModel.aspects.contains(canvas.aspect) && canvas.aspect != original?.canvas.aspect)
        DanaviewChoiceChip(
          key: const ValueKey<String>('canvas.aspect.current'),
          label: ProjectStrings.aspect(canvas.aspect),
          selected: true,
          enabled: enabled,
          onTap: () {},
        ),
    ];

    final rate = settings.frameRate;
    final originalRate = original?.frameRate;
    final rateChips = <Widget>[
      if (originalRate != null)
        DanaviewChoiceChip(
          key: const ValueKey<String>('canvas.fps.match'),
          label: ProjectStrings.fpsMatch(originalRate),
          selected: rate == originalRate,
          enabled: enabled,
          onTap: () => unawaited(_setRate(originalRate, view)),
        ),
      for (final r in CanvasPanelModel.rates)
        DanaviewChoiceChip(
          key: ValueKey<String>('canvas.fps.${r.num}'),
          label: ProjectStrings.fps(r),
          selected: rate == r && rate != originalRate,
          enabled: enabled,
          onTap: () => unawaited(_setRate(r, view)),
        ),
    ];

    final sideChips = <Widget>[
      for (final side in CanvasPanelModel.shortSides)
        DanaviewChoiceChip(
          key: ValueKey<String>('canvas.res.$side'),
          label: ProjectStrings.resolution(side),
          selected: canvas.baseShortSide == side,
          enabled: enabled && CanvasPanelModel.allows(side, maxExport),
          onTap: () => _setShortSide(side),
        ),
    ];

    return CustomScrollView(
      key: const ValueKey<String>('canvas.scroll'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!enabled) const PanelNotice(ProjectStrings.notEditable, key: ValueKey<String>('canvas.notEditable')),
                const _Heading(ProjectStrings.aspectHeading),
                DanaviewChipGroup(key: const ValueKey<String>('canvas.aspects'), children: aspectChips),
                const SizedBox(height: DanaviewSpacing.md),
                const _Heading(ProjectStrings.backgroundHeading),
                DanaviewSegmentedControl<bool>(
                  key: const ValueKey<String>('canvas.background.mode'),
                  value: blur,
                  enabled: enabled,
                  options: const [
                    DanaviewOption<bool>(value: false, label: ProjectStrings.backgroundColor, icon: Icons.format_color_fill_rounded),
                    DanaviewOption<bool>(value: true, label: ProjectStrings.backgroundBlur, icon: Icons.blur_on_rounded),
                  ],
                  onChanged: (v) => _setMode(v, background),
                ),
                const SizedBox(height: DanaviewSpacing.sm),
                if (background is SolidBackground)
                  InspectorColorRow(
                    key: const ValueKey<String>('canvas.background.color'),
                    label: ProjectStrings.backgroundColorLabel,
                    color: Color(background.color | 0xFF000000),
                    enabled: enabled,
                    onChangeStart: (_) => _colorSession().start(),
                    onChanged: (c) => _colorSession().change(SetBackground(SolidBackground(c.toARGB32() | 0xFF000000))),
                    onChangeEnd: (_) => _colorSession().end(),
                  )
                else if (background is BlurOfMainBackground) ...[
                  InspectorSliderRow(
                    key: const ValueKey<String>('canvas.background.blur'),
                    label: ProjectStrings.blurAmount,
                    value: background.radius,
                    min: 0,
                    max: 1,
                    step: 0.01,
                    displayScale: 100,
                    unit: '%',
                    fractionDigits: 0,
                    defaultValue: CanvasPanelModel.defaultBlur,
                    enabled: enabled,
                    onChangeStart: (_) => _blurSession().start(),
                    onChanged: (v) => _blurSession().change(SetBackground(BlurOfMainBackground(v.clamp(0, 1).toDouble()))),
                    onChangeEnd: (_) => _blurSession().end(),
                    onSubmitted: (v) => _blurSession().apply(SetBackground(BlurOfMainBackground(v.clamp(0, 1).toDouble()))),
                  ),
                  const _Caption(ProjectStrings.blurHint),
                ],
                const SizedBox(height: DanaviewSpacing.md),
                const _Heading(ProjectStrings.frameRateHeading),
                DanaviewChipGroup(key: const ValueKey<String>('canvas.rates'), children: rateChips),
                const SizedBox(height: DanaviewSpacing.md),
                const _Heading(ProjectStrings.resolutionHeading),
                DanaviewChipGroup(key: const ValueKey<String>('canvas.resolutions'), children: sideChips),
                const SizedBox(height: DanaviewSpacing.xs),
                _Caption(ProjectStrings.canvasSize(canvas.widthPx, canvas.heightPx), key: const ValueKey<String>('canvas.size')),
                if (!allow4k) const _Caption(ProjectStrings.resolution4kUnavailable, key: ValueKey<String>('canvas.no4k')),
                const _Caption(ProjectStrings.resolutionHint),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: DanaviewSpacing.xs, bottom: DanaviewSpacing.sm),
        child: Semantics(
          header: true,
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary),
          ),
        ),
      );
}

class _Caption extends StatelessWidget {
  const _Caption(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: DanaviewSpacing.xs),
        child: Text(
          text,
          style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary),
        ),
      );
}
