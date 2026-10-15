// OWNER: UX-44
//
// RenderMarkerStrip (ARCH D-45(A), §17.4, §17.5): the thin render-status strip under the timeline
// ruler.
//
// * One segment per range of the current preview plan (CORE-37 `coverage`): **rendered** is a solid
//   green bar, **heavy and not rendered** an amber bar with diagonal hatching, **not needed** is
//   left empty. State is therefore told apart by fill pattern as well as colour. A range being
//   rendered shows its progress as a solid green part over the hatching.
// * Colours are computed against the strip background ([RenderMarkerColors.resolve]): each fill keeps
//   at least 3:1 (WCAG non-text contrast) on the ruler background, lightened if a theme needs it.
// * Every visible range is a semantics node labelled with its state and time span ("Needs
//   rendering, 0:05 to 0:12, chroma key"); amber ranges are buttons. Tapping an amber range (or
//   activating its node) offers "Render preview" in a sheet ([showRenderRangeSheet]).
// * [RenderMarkerStripHost] binds the strip to the project's `RenderPreviewController` and timeline
//   viewport. It is what UX-12's timeline decoration slot mounts under the ruler.

import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show ProjectId, TimeUs;
import 'package:danaview_editor_core/render_cache.dart' show RangeState, RangeStatus;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/render_preview_strings.dart';
import '../state/render_preview_controller.dart';

/// Fill colours of the strip (computed contrast).
///
/// See ARCH §1.3 rule 4, §17.9.
@immutable
final class RenderMarkerColors {
  /// Creates colours.
  const RenderMarkerColors({required this.background, required this.rendered, required this.heavy, required this.heavyHatch});

  /// Minimum contrast of each fill on [background] (WCAG 1.4.11, non-text).
  static const double minContrast = 3;

  /// Colours for a strip drawn on [background] (default: the ruler's surface).
  factory RenderMarkerColors.resolve({Color background = DanaviewColors.surface}) {
    final rendered = _atLeast(DanaviewColors.success, background);
    final heavy = _atLeast(DanaviewColors.warning, background);
    // The hatch lines sit between the amber stripes; darker amber keeps the pattern visible while
    // the stripes alone still meet the contrast.
    final hatch = Color.lerp(heavy, background, 0.55)!;
    return RenderMarkerColors(background: background, rendered: rendered, heavy: heavy, heavyHatch: hatch);
  }

  /// Strip background.
  final Color background;

  /// Rendered fill.
  final Color rendered;

  /// Heavy-unrendered stripes.
  final Color heavy;

  /// Gaps between the heavy stripes.
  final Color heavyHatch;

  /// [color] lightened towards white until it keeps [minContrast] on [background].
  static Color _atLeast(Color color, Color background) {
    var c = color;
    for (var i = 0; i < 20 && DanaviewColors.contrastRatio(c, background) < minContrast; i++) {
      c = Color.lerp(c, const Color(0xFFFFFFFF), 0.1)!;
    }
    return c;
  }
}

/// The strip itself (pure: state, a time → x mapping and a tap callback).
///
/// See ARCH §17.4.
class RenderMarkerStrip extends StatelessWidget {
  /// Creates the strip.
  const RenderMarkerStrip({
    super.key,
    required this.state,
    required this.xOf,
    this.onRangeTap,
    this.colors,
    this.height = RenderMarkerStrip.defaultHeight,
  });

  /// Strip height (the painted bar is [barHeight], centred).
  static const double defaultHeight = 10;

  /// Painted bar height.
  static const double barHeight = 6;

  /// Minimum painted width of a range, so a one-frame range stays visible.
  static const double minRangeWidth = 2;

  /// Coverage and the running render.
  final RenderPreviewState state;

  /// Plan time → x in the strip (the timeline viewport's `xOf`).
  final double Function(TimeUs t) xOf;

  /// Called for a tap on a heavy, unrendered range (null: not interactive).
  final ValueChanged<RangeStatus>? onRangeTap;

  /// Colours (default [RenderMarkerColors.resolve]).
  final RenderMarkerColors? colors;

  /// Height.
  final double height;

  @override
  Widget build(BuildContext context) {
    final palette = colors ?? RenderMarkerColors.resolve();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 0.0;
        final visible = <(RangeStatus, double, double)>[];
        for (final r in state.ranges) {
          final x0 = xOf(r.range.start);
          final x1 = math.max(xOf(r.range.end), x0 + minRangeWidth);
          if (x1 <= 0 || x0 >= width) continue;
          visible.add((r, math.max(0.0, x0), math.min(width, x1)));
        }
        return SizedBox(
          height: height,
          width: width,
          child: Semantics(
            container: true,
            label: RenderPreviewStrings.stripLabel,
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(
                  child: ExcludeSemantics(
                    child: CustomPaint(
                      painter: _StripPainter(state: state, visible: visible, colors: palette, barHeight: math.min(barHeight, height)),
                    ),
                  ),
                ),
                for (final (r, x0, x1) in visible) _rangeNode(r, x0, x1),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _rangeNode(RangeStatus r, double x0, double x1) {
    final tappable = onRangeTap != null && r.state == RangeState.heavyUnrendered;
    final label = RenderPreviewStrings.rangeLabel(r.state, r.range.start, r.range.end, reasons: r.reasons);
    return Positioned(
      key: ValueKey('render-range-${r.range.start}'),
      left: x0,
      width: math.max(0.0, x1 - x0),
      top: 0,
      bottom: 0,
      child: Semantics(
        container: true,
        label: label,
        button: tappable,
        hint: tappable ? RenderPreviewStrings.renderHint : null,
        onTap: tappable ? () => onRangeTap!(r) : null,
        child: tappable
            ? GestureDetector(behavior: HitTestBehavior.opaque, excludeFromSemantics: true, onTap: () => onRangeTap!(r))
            : const SizedBox.expand(),
      ),
    );
  }
}

class _StripPainter extends CustomPainter {
  _StripPainter({required this.state, required this.visible, required this.colors, required this.barHeight});

  final RenderPreviewState state;
  final List<(RangeStatus, double, double)> visible;
  final RenderMarkerColors colors;
  final double barHeight;

  static const double _stripe = 4;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.background);
    final top = (size.height - barHeight) / 2;
    final radius = Radius.circular(barHeight / 2);
    final active = state.active;
    for (final (r, x0, x1) in visible) {
      final rect = RRect.fromLTRBR(x0, top, x1, top + barHeight, radius);
      switch (r.state) {
        case RangeState.rendered:
          canvas.drawRRect(rect, Paint()..color = colors.rendered);
        case RangeState.heavyUnrendered:
          _hatch(canvas, rect);
          if (active != null && active.hash == r.hash) {
            final p = (active.progress ?? 0).clamp(0.0, 1.0);
            if (p > 0) {
              canvas.save();
              canvas.clipRRect(rect);
              canvas.drawRect(Rect.fromLTRB(x0, top, x0 + (x1 - x0) * p, top + barHeight), Paint()..color = colors.rendered);
              canvas.restore();
            }
          }
        case RangeState.notNeeded:
          if (active != null && active.hash == r.hash) {
            // A light range the user asked to render: an outline until it is done.
            canvas.drawRRect(
              rect.deflate(0.5),
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1
                ..color = colors.rendered,
            );
          }
      }
    }
  }

  void _hatch(Canvas canvas, RRect rect) {
    canvas.save();
    canvas.clipRRect(rect);
    canvas.drawRect(rect.outerRect, Paint()..color = colors.heavyHatch);
    final paint = Paint()
      ..color = colors.heavy
      ..strokeWidth = _stripe / 2 + 0.5;
    final h = rect.height;
    for (var x = rect.left - h; x < rect.right + h; x += _stripe) {
      canvas.drawLine(Offset(x, rect.bottom), Offset(x + h, rect.top), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StripPainter old) => old.state != state || old.colors != colors || old.barHeight != barHeight || !_sameVisible(old.visible);

  bool _sameVisible(List<(RangeStatus, double, double)> other) {
    if (other.length != visible.length) return false;
    for (var i = 0; i < other.length; i++) {
      if (other[i] != visible[i]) return false;
    }
    return true;
  }
}

/// The strip bound to a project (the timeline decoration slot mounts this under the ruler).
///
/// See ARCH §17.4.
class RenderMarkerStripHost extends ConsumerWidget {
  /// Creates the host.
  const RenderMarkerStripHost({super.key, required this.projectId});

  /// The project.
  final ProjectId projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(renderPreviewControllerProvider(projectId));
    final viewport = ref.watch(viewportProvider(projectId));
    return ListenableBuilder(
      listenable: Listenable.merge([controller, viewport]),
      builder: (context, _) {
        final state = controller.value;
        if (!state.available) return const SizedBox.shrink();
        return RenderMarkerStrip(
          state: state,
          xOf: viewport.xOf,
          onRangeTap: (r) => showRenderRangeSheet(context, controller: controller, range: r),
        );
      },
    );
  }
}

/// Offers "Render preview" for one heavy range (and "Render all" when several need it).
///
/// See ARCH §17.5.
Future<void> showRenderRangeSheet(BuildContext context, {required RenderPreviewController controller, required RangeStatus range}) {
  return showDanaviewSheet<void>(
    context,
    title: RenderPreviewStrings.rangeTitle(range.range.start, range.range.end),
    builder: (sheetContext) => RenderRangeSheetBody(controller: controller, range: range),
  );
}

/// Body of [showRenderRangeSheet] (public for tests).
///
/// See ARCH §17.5.
class RenderRangeSheetBody extends StatelessWidget {
  /// Creates the body.
  const RenderRangeSheetBody({super.key, required this.controller, required this.range});

  /// The controller.
  final RenderPreviewController controller;

  /// The tapped range.
  final RangeStatus range;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RenderPreviewState>(
      valueListenable: controller,
      builder: (context, state, _) {
        final current = state.ranges.where((r) => r.hash == range.hash).firstOrNull;
        final pending = state.isPending(range.hash);
        final heavyCount = state.heavyUnrendered.length;
        final rendered = current?.state == RangeState.rendered;
        final blocked = controller.blockedReason;
        final reasons = range.reasons;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(RenderPreviewStrings.rangeBody, style: DanaviewTextStyles.bodySecondary),
            if (reasons.isNotEmpty) ...[
              const SizedBox(height: DanaviewSpacing.sm),
              Text(
                RenderPreviewStrings.rangeLabel(RangeState.heavyUnrendered, range.range.start, range.range.end, reasons: reasons),
                style: DanaviewTextStyles.caption,
              ),
            ],
            if (blocked != null) ...[
              const SizedBox(height: DanaviewSpacing.sm),
              Text(blockedMessage(blocked), style: DanaviewTextStyles.caption),
            ],
            const SizedBox(height: DanaviewSpacing.lg),
            if (pending)
              Text(
                RenderPreviewStrings.rendering(state.active?.hash == range.hash ? state.active?.progress : null),
                key: const ValueKey('render-range-progress'),
                style: DanaviewTextStyles.body,
              )
            else if (rendered)
              Text(RenderPreviewStrings.alreadyRendered, style: DanaviewTextStyles.body)
            else
              Wrap(
                spacing: DanaviewSpacing.sm,
                runSpacing: DanaviewSpacing.sm,
                alignment: WrapAlignment.end,
                children: [
                  if (heavyCount > 1)
                    DanaviewButton(
                      key: const ValueKey('render-range-all'),
                      label: RenderPreviewStrings.renderAll,
                      onPressed: blocked != null
                          ? null
                          : () => controller.render(const RenderTarget.timeline()),
                    ),
                  DanaviewButton.primary(
                    key: const ValueKey('render-range-this'),
                    label: RenderPreviewStrings.renderThis,
                    icon: Icons.movie_filter_rounded,
                    onPressed: blocked != null
                        ? null
                        : () => controller.render(RenderTarget.range(range.range.range)),
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// The user-facing reason of a refused or blocked render.
String blockedMessage(RenderRequestOutcome outcome) => switch (outcome) {
      RenderRequestOutcome.started => RenderPreviewStrings.started(1),
      RenderRequestOutcome.waitingForPause => RenderPreviewStrings.waitingForPause,
      RenderRequestOutcome.alreadyRendered => RenderPreviewStrings.alreadyRendered,
      RenderRequestOutcome.nothingToRender => RenderPreviewStrings.nothingToRender,
      RenderRequestOutcome.unavailable => RenderPreviewStrings.notReady,
      RenderRequestOutcome.unsupported => RenderPreviewStrings.unsupported,
      RenderRequestOutcome.exportRunning => RenderPreviewStrings.exportRunning,
    };
