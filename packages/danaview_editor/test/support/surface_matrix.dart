// OWNER: UX-01
//
// Surface matrix helpers for no-overflow tests (ARCH §1.3 rule 5, §17.9).
//
// * [SurfaceMatrix.full]: every ARCH §17.9 size × text scale 0.85/1.0/1.35 × keyboard none/40%.
// * [SurfaceMatrix.pr]: the 6-surface PR subset (includes 280×500 @1.35 and 568×320 @1.35).
// * [SurfaceMatrix.current]: `pr`, or `full` when run with
//   `--dart-define=DANAVIEW_SURFACE_MATRIX=full` (nightly).
//
// Checks: [expectNoOverflow] (`takeException() == null`), [expectInside] (inside the screen) and
// [fitsFully]/[expectFitsFully] (inside the screen and no text truncated by its line limit).

import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart' show isTestGroup;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

/// One test surface: logical size, text scale, keyboard inset and platform.
@immutable
class EditorSurface {
  /// Creates a surface.
  const EditorSurface(this.size, {this.textScale = 1.0, this.keyboardFraction = 0.0, this.platform = TargetPlatform.android});

  /// Logical size (device pixel ratio 1).
  final Size size;

  /// Text scale factor (the app clamps to 0.85–1.35).
  final double textScale;

  /// Keyboard height as a fraction of the height (0 = no keyboard).
  final double keyboardFraction;

  /// Platform used for the theme (touch on iOS/Android).
  final TargetPlatform platform;

  /// Whether the platform is touch-first.
  bool get touch => platform == TargetPlatform.iOS || platform == TargetPlatform.android || platform == TargetPlatform.fuchsia;

  /// Keyboard inset in logical pixels.
  double get keyboardInset => (size.height * keyboardFraction).roundToDouble();

  /// A copy with the given fields replaced.
  EditorSurface copyWith({Size? size, double? textScale, double? keyboardFraction, TargetPlatform? platform}) => EditorSurface(
        size ?? this.size,
        textScale: textScale ?? this.textScale,
        keyboardFraction: keyboardFraction ?? this.keyboardFraction,
        platform: platform ?? this.platform,
      );

  /// Stable name used in test descriptions (`280x500 @1.35 kb40% android`).
  String get name {
    final kb = keyboardFraction == 0 ? '' : ' kb${(keyboardFraction * 100).round()}%';
    return '${size.width.round()}x${size.height.round()} @$textScale$kb ${platform.name}';
  }

  @override
  bool operator ==(Object other) =>
      other is EditorSurface &&
      other.size == size &&
      other.textScale == textScale &&
      other.keyboardFraction == keyboardFraction &&
      other.platform == platform;

  @override
  int get hashCode => Object.hash(size, textScale, keyboardFraction, platform);

  @override
  String toString() => name;
}

/// The ARCH §17.9 matrix.
abstract final class SurfaceMatrix {
  /// Every size of ARCH §17.9 (phones, phone landscape, iPad portrait/landscape, desktop-class).
  static const List<Size> sizes = [
    Size(280, 500),
    Size(320, 568),
    Size(360, 740),
    Size(390, 844),
    Size(412, 915),
    Size(568, 320),
    Size(667, 375),
    Size(844, 390),
    Size(932, 430),
    Size(744, 1133),
    Size(834, 1194),
    Size(1133, 744),
    Size(1194, 834),
    Size(1280, 800),
  ];

  /// Text scales of ARCH §17.9.
  static const List<double> textScales = [0.85, 1.0, 1.35];

  /// Keyboard insets of ARCH §17.9 (none, 40% of the height).
  static const List<double> keyboardFractions = [0.0, 0.4];

  /// The default surface of single-surface tests (a mid-size phone).
  static const EditorSurface phone = EditorSurface(Size(390, 844));

  /// The narrowest surface at the largest text scale.
  static const EditorSurface narrowest = EditorSurface(Size(280, 500), textScale: 1.35);

  /// The PR subset (6 surfaces).
  static const List<EditorSurface> pr = [
    EditorSurface(Size(280, 500), textScale: 1.35),
    EditorSurface(Size(568, 320), textScale: 1.35),
    EditorSurface(Size(390, 844)),
    EditorSurface(Size(390, 844), keyboardFraction: 0.4, platform: TargetPlatform.iOS),
    EditorSurface(Size(834, 1194), platform: TargetPlatform.iOS),
    EditorSurface(Size(1280, 800), textScale: 0.85),
  ];

  /// iPad-class sizes are tested as iOS, everything else as Android.
  static TargetPlatform platformFor(Size size) =>
      size.shortestSide >= 700 && size != const Size(1280, 800) ? TargetPlatform.iOS : TargetPlatform.android;

  /// The full matrix (14 sizes × 3 scales × 2 keyboard states = 84 surfaces).
  static List<EditorSurface> get full => [
        for (final size in sizes)
          for (final scale in textScales)
            for (final kb in keyboardFractions) EditorSurface(size, textScale: scale, keyboardFraction: kb, platform: platformFor(size)),
      ];

  /// `full` under `--dart-define=DANAVIEW_SURFACE_MATRIX=full`, else [pr].
  static List<EditorSurface> get current => const String.fromEnvironment('DANAVIEW_SURFACE_MATRIX') == 'full' ? full : pr;
}

/// Sizes the test view like [surface] (DPR 1, keyboard as a bottom view inset) until the test ends.
void applySurface(WidgetTester tester, EditorSurface surface) {
  tester.view.physicalSize = surface.size;
  tester.view.devicePixelRatio = 1.0;
  tester.view.viewInsets = surface.keyboardInset == 0 ? FakeViewPadding.zero : FakeViewPadding(bottom: surface.keyboardInset);
  addTearDown(tester.view.reset);
}

/// A dark Danaview app around [home] with [surface]'s platform and text scale (no providers; see
/// `EditorTestHarness` for the editor's provider overrides).
Widget surfaceApp(EditorSurface surface, Widget home) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: DanaviewTheme.darkTheme.copyWith(platform: surface.platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(surface.textScale)),
        child: child ?? const SizedBox.shrink(),
      ),
      home: home,
    );

/// Registers one `testWidgets` per surface of [surfaces] (default [SurfaceMatrix.current]).
@isTestGroup
void testSurfaces(
  String description,
  Future<void> Function(WidgetTester tester, EditorSurface surface) body, {
  List<EditorSurface>? surfaces,
  bool semanticsEnabled = true,
}) {
  for (final surface in surfaces ?? SurfaceMatrix.current) {
    testWidgets('$description [$surface]', (tester) => body(tester, surface), semanticsEnabled: semanticsEnabled);
  }
}

/// No exception (overflow, layout or build error) was reported since the last check.
void expectNoOverflow(WidgetTester tester) {
  final error = tester.takeException();
  expect(error, isNull, reason: 'unexpected exception (overflow or layout error): $error');
}

/// The screen rectangle of the test view, in logical pixels.
Rect screenRect(WidgetTester tester) => Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio);

/// Every widget found by [finder] lies inside the screen (or [screen] when given).
void expectInside(WidgetTester tester, Finder finder, {Size? screen}) {
  final bounds = screen == null ? screenRect(tester) : Offset.zero & screen;
  final elements = finder.evaluate().toList();
  expect(elements, isNotEmpty, reason: 'expectInside: $finder found nothing');
  for (final element in elements) {
    final rect = _globalRect(element);
    expect(_contains(bounds, rect), isTrue, reason: '${element.widget.runtimeType} at $rect is outside $bounds');
  }
}

/// Whether every widget found by [finder] lies inside the screen and none of the text below it is
/// cut by its line limit (ellipsis or max-lines truncation).
bool fitsFully(WidgetTester tester, Finder finder) => fitsFullyProblems(tester, finder).isEmpty;

/// [fitsFully] as an expectation, with the reasons on failure.
void expectFitsFully(WidgetTester tester, Finder finder) {
  final problems = fitsFullyProblems(tester, finder);
  expect(problems, isEmpty, reason: problems.join('\n'));
}

/// The reasons [fitsFully] would fail.
List<String> fitsFullyProblems(WidgetTester tester, Finder finder) {
  final bounds = screenRect(tester);
  final problems = <String>[];
  final elements = finder.evaluate().toList();
  if (elements.isEmpty) return ['$finder found nothing'];
  for (final element in elements) {
    final rect = _globalRect(element);
    if (!_contains(bounds, rect)) problems.add('${element.widget.runtimeType} at $rect is outside $bounds');
    void visit(Element e) {
      final ro = e.renderObject;
      if (e.widget is RichText && ro is RenderParagraph && ro.hasSize && ro.didExceedMaxLines) {
        problems.add('text "${_snippet(ro.text.toPlainText())}" is truncated');
      }
      e.visitChildren(visit);
    }

    visit(element);
  }
  return problems;
}

Rect _globalRect(Element element) {
  final ro = element.renderObject;
  if (ro is! RenderBox || !ro.hasSize) return Rect.zero;
  return MatrixUtils.transformRect(ro.getTransformTo(null), Offset.zero & ro.size);
}

bool _contains(Rect outer, Rect inner) =>
    inner.left >= outer.left - 0.01 &&
    inner.top >= outer.top - 0.01 &&
    inner.right <= outer.right + 0.01 &&
    inner.bottom <= outer.bottom + 0.01;

String _snippet(String s) => s.length <= 40 ? s : '${s.substring(0, 40)}…';
