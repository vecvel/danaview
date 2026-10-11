// OWNER: UX-07
//
// EditorLayoutSpec.resolve over the ARCH §17.9 matrix (14 sizes × text scale 0.85/1.0/1.35 ×
// keyboard none/40%) × safe area none/device × inspector closed/open × touch/pointer × splitter
// ratios: every region inside the screen and its safe area, no overlaps, no gaps, no region below
// its minimum, and a deterministic, monotonic degradation ladder (ux.md §6.2). Plus the kind rules,
// the text-scale sizes and the ux.md worked examples.

import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';

import '../support/support.dart';

/// The safe area a device of [size] typically has (iPhone notch/home indicator, iPad bars).
EdgeInsets devicePadding(Size size) {
  if (size.shortestSide >= 700) return const EdgeInsets.only(top: 24, bottom: 20);
  if (size.height > size.width) return const EdgeInsets.only(top: 47, bottom: 34);
  return const EdgeInsets.only(left: 47, right: 47, bottom: 21);
}

EditorLayoutSpec resolve(
  Size size, {
  double scale = 1.0,
  double keyboard = 0,
  EdgeInsets padding = EdgeInsets.zero,
  bool open = false,
  bool touch = true,
  double? ratio,
}) =>
    EditorLayoutSpec.resolve(
      size: size,
      padding: padding,
      viewInsets: EdgeInsets.only(bottom: keyboard),
      textScaler: TextScaler.linear(scale),
      touch: touch,
      splitRatio: ratio,
      inspectorOpen: open,
    );

/// Every invariant of one resolved spec; returns the problems found.
List<String> problemsOf(EditorLayoutSpec s) {
  final p = <String>[];
  final w = s.size.width;
  final h = s.size.height;
  final pad = s.padding;
  final kb = s.viewInsets.bottom;
  final screen = Offset.zero & s.size;
  final safe = Rect.fromLTRB(pad.left, pad.top, w - pad.right, h - math.max(pad.bottom, kb));
  final docked = s.kind == EditorLayoutKind.compactPortrait && s.inspectorOpen;
  final dockBottom = kb > 0 ? h - kb : h;
  const eps = 1e-6;

  if (!s.fitsMinimums) p.add('does not fit its minimums');

  // Presence.
  bool has(EditorRegion r) => s.shows(r);
  if (!has(EditorRegion.topBar)) p.add('no top bar');
  if (!has(EditorRegion.timeline)) p.add('no timeline');
  if (has(EditorRegion.preview) == s.previewHidden) p.add('preview shown=${has(EditorRegion.preview)} but degrade=${s.degrade.name}');
  if (s.previewHidden && kb == 0) p.add('preview hidden without a keyboard');
  if (has(EditorRegion.transport) == (s.transportInTopBar || s.previewHidden)) {
    p.add('transport shown=${has(EditorRegion.transport)} at ${s.degrade.name}');
  }
  if (has(EditorRegion.toolStrip) != (s.kind == EditorLayoutKind.compactPortrait && !docked)) p.add('tool strip presence');
  if (has(EditorRegion.dock) != docked) p.add('dock presence');
  if (has(EditorRegion.pane) != (s.kind != EditorLayoutKind.compactPortrait)) p.add('pane presence');
  if (has(EditorRegion.rail) != (s.kind == EditorLayoutKind.expanded)) p.add('rail presence');
  if (has(EditorRegion.splitter) != (has(EditorRegion.preview) && !docked)) p.add('splitter presence');
  if (s.inspectorPlacement != (s.kind == EditorLayoutKind.compactPortrait ? InspectorPlacement.dockBottom : InspectorPlacement.sidePane)) {
    p.add('inspector placement');
  }

  // Bounds: inside the screen; everything but the dock inside the safe area above the keyboard.
  s.regions.forEach((r, rect) {
    if (rect.width <= 0 || rect.height <= 0) p.add('${r.name} is empty');
    if (!_inside(screen, rect)) p.add('${r.name} $rect is outside the screen');
    if (r == EditorRegion.dock) {
      if ((rect.bottom - dockBottom).abs() > eps) p.add('dock bottom ${rect.bottom} != $dockBottom');
    } else if (!_inside(safe, rect)) {
      p.add('${r.name} $rect is outside the safe area $safe');
    }
  });

  // No overlaps, no gaps: the regions tile the content rect exactly.
  final entries = s.regions.entries.toList();
  for (var i = 0; i < entries.length; i++) {
    for (var j = i + 1; j < entries.length; j++) {
      final o = entries[i].value.intersect(entries[j].value);
      if (o.width > eps && o.height > eps) p.add('${entries[i].key.name} overlaps ${entries[j].key.name}');
    }
  }
  final content = docked ? Rect.fromLTRB(0, pad.top, w, dockBottom) : safe;
  final area = s.regions.values.fold<double>(0, (a, r) => a + r.width * r.height);
  if ((area - content.width * content.height).abs() > 0.5) p.add('regions cover $area of ${content.width * content.height} (gap)');

  // Minimums.
  double hOf(EditorRegion r) => s.rectOf(r)?.height ?? 0;
  if ((hOf(EditorRegion.topBar) - s.topBarHeight).abs() > eps) p.add('top bar height');
  if (has(EditorRegion.preview)) {
    if (hOf(EditorRegion.preview) < s.previewMinHeight - eps) p.add('preview ${hOf(EditorRegion.preview)} < ${s.previewMinHeight}');
    if (s.previewMinHeight < EditorLayoutSpec.previewReducedMin) p.add('preview minimum ${s.previewMinHeight}');
    if (s.rectOf(EditorRegion.preview)!.width < EditorLayoutSpec.previewMinWidth - eps) p.add('preview narrower than 160');
    if (!s.applied(DegradeStep.previewReduced) && hOf(EditorRegion.preview) < EditorLayoutSpec.previewMin - eps) {
      p.add('preview below 140 without step 2');
    }
  }
  if (hOf(EditorRegion.timeline) < s.timelineMinHeight - eps) p.add('timeline ${hOf(EditorRegion.timeline)} < ${s.timelineMinHeight}');
  if (s.timelineMinHeight < s.rulerHeight + EditorLayoutSpec.compactVideoLane - eps) p.add('timeline minimum below ruler + lane');
  if (has(EditorRegion.transport) && (hOf(EditorRegion.transport) - s.transportRowHeight).abs() > eps) p.add('transport height');
  if (has(EditorRegion.toolStrip) && (hOf(EditorRegion.toolStrip) - s.toolTileHeight).abs() > eps) p.add('tool strip height');
  if (has(EditorRegion.splitter) && (hOf(EditorRegion.splitter) - EditorLayoutSpec.splitterExtent).abs() > eps) p.add('splitter height');
  final dockHeight = hOf(EditorRegion.dock);
  if (has(EditorRegion.dock) && dockHeight < s.dockMinHeight - eps) p.add('dock $dockHeight < ${s.dockMinHeight}');
  if (has(EditorRegion.dock) && s.dockMinHeight < EditorLayoutSpec.dockKeyboardFloor) p.add('dock minimum');
  if (has(EditorRegion.pane) && s.paneWidth < 280 - eps) p.add('pane ${s.paneWidth} < 280');
  if (has(EditorRegion.pane) && s.paneWidth > 380 + eps) p.add('pane ${s.paneWidth} > 380');
  if (has(EditorRegion.rail) && (s.rectOf(EditorRegion.rail)!.width - EditorLayoutSpec.expandedRailWidth).abs() > eps) p.add('rail width');
  if (s.iconOnlyTools != (s.toolTileHeight == EditorLayoutSpec.iconOnlyToolTileHeight)) p.add('icon-only tiles');

  // Splitter range.
  if (has(EditorRegion.splitter)) {
    if (s.minSplitRatio > s.splitRatio + eps || s.splitRatio > s.maxSplitRatio + eps) p.add('ratio outside its range');
    if (s.splitSpan <= 0) p.add('no split span');
  }
  return p;
}

bool _inside(Rect outer, Rect inner) =>
    inner.left >= outer.left - 1e-6 &&
    inner.top >= outer.top - 1e-6 &&
    inner.right <= outer.right + 1e-6 &&
    inner.bottom <= outer.bottom + 1e-6;

void main() {
  group('kind rules (ux.md §6.2)', () {
    test('usable size picks the kind; the keyboard never changes it', () {
      final cases = <(Size, EdgeInsets, EditorLayoutKind)>[
        (const Size(280, 500), EdgeInsets.zero, EditorLayoutKind.compactPortrait),
        (const Size(390, 844), const EdgeInsets.only(top: 47, bottom: 34), EditorLayoutKind.compactPortrait),
        (const Size(568, 320), EdgeInsets.zero, EditorLayoutKind.compactLandscape),
        (const Size(844, 390), const EdgeInsets.only(left: 47, right: 47, bottom: 21), EditorLayoutKind.compactLandscape),
        (const Size(932, 430), EdgeInsets.zero, EditorLayoutKind.compactLandscape),
        (const Size(744, 1133), EdgeInsets.zero, EditorLayoutKind.medium),
        (const Size(834, 1194), EdgeInsets.zero, EditorLayoutKind.medium),
        (const Size(1133, 744), EdgeInsets.zero, EditorLayoutKind.expanded),
        (const Size(1194, 834), EdgeInsets.zero, EditorLayoutKind.expanded),
        (const Size(1280, 800), EdgeInsets.zero, EditorLayoutKind.expanded),
        // A short, wide window is compactLandscape; a short window narrower than tall is not.
        (const Size(1280, 500), EdgeInsets.zero, EditorLayoutKind.compactLandscape),
        (const Size(500, 510), EdgeInsets.zero, EditorLayoutKind.compactPortrait),
        // The safe area decides: 1000 wide with 2 × 47 of notch is medium.
        (const Size(1000, 800), const EdgeInsets.symmetric(horizontal: 47), EditorLayoutKind.medium),
      ];
      for (final (size, padding, kind) in cases) {
        expect(EditorLayoutSpec.kindOf(size: size, padding: padding), kind, reason: '$size $padding');
        for (final kb in [0.0, size.height * 0.4]) {
          expect(resolve(size, padding: padding, keyboard: kb).kind, kind, reason: '$size kb $kb');
        }
      }
    });
  });

  group('text-scale sizes (ux.md §6.2 table)', () {
    test('rows grow with the text scale and never shrink below their floors', () {
      final s1 = resolve(const Size(390, 844));
      final s135 = resolve(const Size(390, 844), scale: 1.35);
      final s085 = resolve(const Size(390, 844), scale: 0.85);
      expect(s1.topBarHeight, 52);
      expect(s135.topBarHeight, 55);
      expect(s085.topBarHeight, 52);
      expect(s1.transportRowHeight, 44);
      expect(s1.toolTileHeight, 60);
      expect(s135.toolTileHeight, 64);
      expect(s1.rulerHeight, 24);
      expect(s135.rulerHeight, 26);
      expect(resolve(const Size(844, 390)).topBarHeight, 44, reason: 'compactLandscape one-line title');
      expect(resolve(const Size(844, 390)).topBarTwoLineTitle, isFalse);
      expect(resolve(const Size(834, 1194)).topBarHeight, 56, reason: 'medium');
      // A non-linear scaler is honoured row by row.
      final nonLinear = EditorLayoutSpec.resolve(
        size: const Size(390, 844),
        padding: EdgeInsets.zero,
        viewInsets: EdgeInsets.zero,
        textScaler: const _StepScaler(),
        touch: true,
      );
      expect(nonLinear.toolTileHeight, greaterThanOrEqualTo(64));
      expect(problemsOf(nonLinear), isEmpty);
    });

    test('track header width and side pane width', () {
      expect(resolve(const Size(390, 844)).headerWidth, 44);
      expect(resolve(const Size(844, 390)).headerWidth, 44);
      expect(resolve(const Size(834, 1194)).headerWidth, 132);
      expect(resolve(const Size(1194, 834)).headerWidth, 220);
      expect(resolve(const Size(1194, 834), touch: false).headerWidth, 168);
      expect(resolve(const Size(390, 844)).paneWidth, 0);
      expect(resolve(const Size(844, 390)).paneWidth, 286); // floor(844 × 0.34)
      expect(resolve(const Size(834, 1194)).paneWidth, 283);
      expect(resolve(const Size(1280, 800)).paneWidth, 380);
      expect(resolve(const Size(568, 320)).paneWidth, 280);
    });
  });

  group('worked examples (ux.md §6.2, §6.3)', () {
    test('280×500 @1.35: no degradation, preview 162, timeline 163', () {
      final s = resolve(const Size(280, 500), scale: 1.35);
      expect(s.kind, EditorLayoutKind.compactPortrait);
      expect(s.degrade, DegradeStep.none);
      expect(s.topBarHeight + s.transportRowHeight + s.toolTileHeight + EditorLayoutSpec.splitterExtent, 175);
      expect(s.previewHeight, 162);
      expect(s.timelineHeight, 163);
      expect(s.splitRatio, closeTo(0.5, 0.01));
    });

    test('320×480 with a 240 keyboard during text editing: step 5', () {
      final s = resolve(const Size(320, 480), keyboard: 240, open: true);
      expect(s.degrade, DegradeStep.previewHidden);
      expect(s.previewHidden, isTrue);
      expect(s.shows(EditorRegion.dock), isTrue);
      expect(s.rectOf(EditorRegion.dock)!.bottom, 240);
    });

    test('844×390 phone landscape (usable 750×369): 44 + preview + 40 + 12 + timeline ≥ 110', () {
      final s = resolve(const Size(844, 390), padding: const EdgeInsets.only(left: 47, right: 47, bottom: 21));
      expect(s.kind, EditorLayoutKind.compactLandscape);
      expect(s.topBarHeight, 44);
      expect(s.transportRowHeight, 40);
      expect(s.timelineHeight, greaterThanOrEqualTo(110));
      expect(s.topBarHeight + s.previewHeight + s.transportHeight + s.splitterHeight + s.timelineHeight, 369);
      expect(s.degrade, DegradeStep.none);
      // Dragging the splitter towards the timeline takes the preview down to its minimum.
      final low = resolve(const Size(844, 390), padding: const EdgeInsets.only(left: 47, right: 47, bottom: 21), ratio: 0.3);
      expect(low.previewHeight, greaterThanOrEqualTo(EditorLayoutSpec.previewMin));
    });

    test('docked inspector: the timeline keeps ruler + one lane (≥ 76), the dock at least 240 when it can', () {
      final s = resolve(const Size(390, 844), padding: const EdgeInsets.only(top: 47, bottom: 34), open: true);
      expect(s.degrade, DegradeStep.none);
      expect(s.timelineHeight, 76);
      expect(s.dockHeight, greaterThanOrEqualTo(240));
      expect(s.shows(EditorRegion.toolStrip), isFalse);
      expect(s.shows(EditorRegion.splitter), isFalse);
      // The dock draws the bottom safe area itself: its rect reaches the screen bottom.
      expect(s.rectOf(EditorRegion.dock)!.bottom, 844);
    });

    test('expanded: rail and pane beside the preview and transport; the timeline spans the width', () {
      final s = resolve(const Size(1194, 834), padding: const EdgeInsets.only(top: 24, bottom: 20));
      final rail = s.rectOf(EditorRegion.rail)!;
      final pane = s.rectOf(EditorRegion.pane)!;
      final preview = s.rectOf(EditorRegion.preview)!;
      final transport = s.rectOf(EditorRegion.transport)!;
      final timeline = s.rectOf(EditorRegion.timeline)!;
      expect(rail.left, 0);
      expect(pane.left, rail.right);
      expect(preview.left, pane.right);
      expect(transport.left, pane.right);
      expect(rail.bottom, transport.bottom);
      expect(timeline.width, 1194);
      expect(s.toolPlacement, ToolPlacement.rail);
    });
  });

  group('ARCH §17.9 matrix', () {
    var count = 0;
    final failures = <String>[];
    setUpAll(() {
      for (final size in SurfaceMatrix.sizes) {
        for (final scale in SurfaceMatrix.textScales) {
          for (final kbFraction in SurfaceMatrix.keyboardFractions) {
            for (final padding in [EdgeInsets.zero, devicePadding(size)]) {
              for (final open in [false, true]) {
                for (final touch in [true, false]) {
                  for (final ratio in <double?>[null, 0.3, 0.7, 0.05, 0.95]) {
                    final s = resolve(size,
                        scale: scale,
                        keyboard: (size.height * kbFraction).roundToDouble(),
                        padding: padding,
                        open: open,
                        touch: touch,
                        ratio: ratio);
                    count++;
                    final problems = problemsOf(s);
                    if (problems.isNotEmpty) failures.add('$s ratio $ratio touch $touch: ${problems.join('; ')}');
                    // Deterministic: the same inputs give an equal spec.
                    final again = resolve(size,
                        scale: scale,
                        keyboard: (size.height * kbFraction).roundToDouble(),
                        padding: padding,
                        open: open,
                        touch: touch,
                        ratio: ratio);
                    if (again != s || again.hashCode != s.hashCode) failures.add('$s is not deterministic');
                  }
                }
              }
            }
          }
        }
      }
    });

    test('no region below its minimum, inside the screen, no overlap, no gap', () {
      expect(count, 14 * 3 * 2 * 2 * 2 * 2 * 5);
      expect(failures, isEmpty, reason: failures.take(20).join('\n'));
    });

    test('without a keyboard the preview never hides; a closed inspector stops at step 2', () {
      for (final size in SurfaceMatrix.sizes) {
        for (final scale in SurfaceMatrix.textScales) {
          for (final open in [false, true]) {
            for (final padding in [EdgeInsets.zero, devicePadding(size)]) {
              final s = resolve(size, scale: scale, open: open, padding: padding);
              expect(s.previewHidden, isFalse, reason: '$s');
            }
            // Without a notch, a closed inspector never needs more than the reduced preview.
            final plain = resolve(size, scale: scale, open: open);
            if (!open) expect(plain.degrade.index, lessThanOrEqualTo(DegradeStep.previewReduced.index), reason: '$plain');
          }
        }
      }
    });
  });

  group('ladder', () {
    test('monotonic: less height never undoes a step (same kind, no keyboard)', () {
      for (final width in [280.0, 320.0, 390.0, 568.0, 667.0, 844.0, 932.0, 744.0, 1194.0, 1280.0]) {
        for (final scale in SurfaceMatrix.textScales) {
          for (final open in [false, true]) {
            EditorLayoutSpec? previous;
            for (var height = 1200.0; height >= 300; height -= 4) {
              final s = resolve(Size(width, height), scale: scale, open: open);
              if (previous != null && previous.kind == s.kind) {
                expect(s.degrade.index, greaterThanOrEqualTo(previous.degrade.index),
                    reason: '${previous.size} -> ${s.size} open $open @$scale');
              }
              previous = s;
            }
          }
        }
      }
    });

    test('monotonic: a taller keyboard never undoes a step', () {
      for (final size in SurfaceMatrix.sizes) {
        for (final scale in SurfaceMatrix.textScales) {
          for (final open in [false, true]) {
            EditorLayoutSpec? previous;
            for (var kb = 1.0; kb <= size.height * 0.4; kb += 6) {
              final s = resolve(size, scale: scale, keyboard: kb, open: open);
              if (previous != null) {
                expect(s.degrade.index, greaterThanOrEqualTo(previous.degrade.index),
                    reason: '$size kb ${previous.viewInsets.bottom} -> $kb open $open @$scale');
              }
              expect(problemsOf(s), isEmpty, reason: '$s');
              previous = s;
            }
          }
        }
      }
    });

    test('each step is applied only when the previous configuration cannot meet the minimums', () {
      // compactPortrait, inspector closed, no keyboard: walk the height down and check the step
      // against the arithmetic of ux.md §6.2.
      for (final scale in SurfaceMatrix.textScales) {
        for (var height = 700.0; height >= 380; height -= 2) {
          final s = resolve(Size(360, height), scale: scale);
          final tlMin = s.timelineMinHeight;
          // Icon-only tiles change toolTileHeight on the spec itself; recompute with full tiles.
          final full = resolve(const Size(360, 700), scale: scale).toolTileHeight;
          final spanFull = height - (s.topBarHeight + s.transportRowHeight + full + EditorLayoutSpec.splitterExtent);
          final expectedFull = spanFull >= EditorLayoutSpec.previewMin + tlMin + EditorLayoutSpec.timelineComfort
              ? DegradeStep.none
              : spanFull - tlMin >= EditorLayoutSpec.previewMin
                  ? DegradeStep.timelineMin
                  : spanFull - tlMin >= EditorLayoutSpec.previewReducedMin
                      ? DegradeStep.previewReduced
                      : spanFull - tlMin + (full - EditorLayoutSpec.iconOnlyToolTileHeight) >= EditorLayoutSpec.previewReducedMin
                          ? DegradeStep.iconOnlyTools
                          : DegradeStep.transportInTopBar;
          expect(s.degrade, expectedFull, reason: '360x$height @$scale (span $spanFull)');
          if (s.degrade == DegradeStep.timelineMin || s.degrade == DegradeStep.previewReduced) {
            expect(s.timelineHeight, tlMin, reason: 'steps 1+ keep the timeline at its minimum');
          }
          if (s.degrade == DegradeStep.none) expect(s.previewHeight, greaterThanOrEqualTo(EditorLayoutSpec.previewMin));
        }
      }
    });
  });

  group('splitter ratio', () {
    test('the user ratio is clamped to 0.30-0.70 and to the minimums; defaults per kind', () {
      expect(resolve(const Size(390, 844)).splitRatio, closeTo(0.5, 0.01));
      expect(resolve(const Size(844, 390)).splitRatio, closeTo(0.6, 0.02));
      expect(resolve(const Size(834, 1194)).splitRatio, closeTo(0.55, 0.01));
      expect(resolve(const Size(1280, 800)).splitRatio, closeTo(0.58, 0.01));
      final lo = resolve(const Size(390, 844), ratio: 0.01);
      final hi = resolve(const Size(390, 844), ratio: 0.99);
      expect(lo.splitRatio, closeTo(0.3, 0.01));
      expect(hi.splitRatio, closeTo(0.7, 0.01));
      expect(lo.splitterMovable, isTrue);
      expect(lo.minSplitRatio, closeTo(0.3, 0.01));
      expect(lo.maxSplitRatio, closeTo(0.7, 0.01));
      // ratioForPreviewHeight maps back into the allowed range.
      expect(lo.ratioForPreviewHeight(10), lo.minSplitRatio);
      expect(lo.ratioForPreviewHeight(10000), lo.maxSplitRatio);
    });

    test('a ratio at either end of the range keeps both minimums', () {
      for (final size in SurfaceMatrix.sizes) {
        for (final scale in SurfaceMatrix.textScales) {
          final base = resolve(size, scale: scale);
          for (final r in [base.minSplitRatio, base.maxSplitRatio]) {
            final s = resolve(size, scale: scale, ratio: r);
            expect(problemsOf(s), isEmpty, reason: '$s');
            if (s.shows(EditorRegion.preview)) expect(s.previewHeight, greaterThanOrEqualTo(s.previewMinHeight));
            expect(s.timelineHeight, greaterThanOrEqualTo(s.timelineMinHeight));
          }
        }
      }
    });

    test('a degraded layout pins the splitter', () {
      final s = resolve(const Size(568, 320), scale: 1.35);
      expect(s.degrade, DegradeStep.previewReduced);
      expect(s.splitterMovable, isFalse);
      expect(s.minSplitRatio, s.maxSplitRatio);
    });
  });

  group('robustness', () {
    test('sizes below the matrix shrink without negative rects and report fitsMinimums = false', () {
      for (final size in const [Size(200, 300), Size(100, 100), Size(0, 0), Size(320, 200)]) {
        for (final open in [false, true]) {
          final s = resolve(size, open: open, scale: 1.35);
          for (final rect in s.regions.values) {
            expect(rect.width, greaterThan(0));
            expect(rect.height, greaterThan(0));
            expect(_inside(Offset.zero & s.size, rect), isTrue, reason: '$s');
          }
        }
      }
      expect(resolve(const Size(200, 300), scale: 1.35).fitsMinimums, isFalse);
    });

    test('non-finite and negative inputs are treated as zero', () {
      final s = EditorLayoutSpec.resolve(
        size: const Size(390, 844),
        padding: const EdgeInsets.only(top: -5, bottom: double.nan),
        viewInsets: const EdgeInsets.only(bottom: double.infinity),
        textScaler: TextScaler.noScaling,
        touch: true,
        splitRatio: double.nan,
      );
      expect(s.padding, EdgeInsets.zero);
      expect(s.viewInsets, EdgeInsets.zero);
      expect(problemsOf(s), isEmpty);
    });
  });
}

/// A non-linear scaler (large fonts grow less), like Android 14's.
class _StepScaler extends TextScaler {
  const _StepScaler();

  @override
  double scale(double fontSize) => fontSize <= 12 ? fontSize * 1.35 : fontSize * 1.15;

  @override
  double get textScaleFactor => 1.35;

  @override
  TextScaler clamp({double minScaleFactor = 0, double maxScaleFactor = double.infinity}) => this;

  @override
  bool operator ==(Object other) => other is _StepScaler;

  @override
  int get hashCode => 7;
}
