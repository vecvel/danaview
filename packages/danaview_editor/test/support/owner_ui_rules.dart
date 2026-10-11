// OWNER: UX-01
//
// `expectOwnerUiRules(tester)` (ARCH §1.3): fails when
// * a `DanaviewPressable` with a text label is round: `circle: true`, or the text sits inside a circle,
//   a stadium/pill (corner radius ≥ half the shorter side), a `ClipOval` or a circular clip
//   (rule 3: text and icon+text buttons use the standard rounded rectangle; only single-icon
//   buttons are fully round), or
// * chrome text resolves to a font family other than Figtree (rule 6), including text with no
//   family at all (it would render in the platform default font).
// Icon glyphs are not text. User content is exempt: anything below `EditorContentTextRegion` or the
// preview's `TextOverlayLayer` (ARCH §17.8).

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/contracts/content_text.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

/// Font family names accepted for chrome text.
const Set<String> chromeFontFamilies = {DanaviewFonts.family, 'Figtree'};

/// Widget type names whose subtree is user content (besides `EditorContentTextRegion`).
const Set<String> contentTextHosts = {'TextOverlayLayer'};

/// Fails the test when the current tree breaks an owner UI rule (see the file comment).
void expectOwnerUiRules(WidgetTester tester) {
  final violations = ownerUiViolations(tester);
  expect(violations, isEmpty, reason: 'owner UI rules (ARCH §1.3):\n${violations.map((v) => '  $v').join('\n')}');
}

/// Every owner UI rule violation in the current tree.
List<String> ownerUiViolations(WidgetTester tester) {
  final out = <String>[];
  final root = tester.binding.rootElement;
  if (root == null) return out;

  void visit(Element element) {
    final widget = element.widget;
    if (widget is EditorContentTextRegion || contentTextHosts.contains(widget.runtimeType.toString())) return;
    if (widget is Icon) return;
    final ro = element.renderObject;
    if (widget is RichText && ro is RenderParagraph) {
      _checkFamilies(ro.text, null, 'text', out);
    } else if (widget is EditableText && ro is RenderEditable && ro.text != null) {
      _checkFamilies(ro.text!, null, 'editable text', out);
    }
    if (widget is DanaviewPressable) _checkPressable(element, widget, out);
    element.visitChildren(visit);
  }

  root.visitChildren(visit);
  return out;
}

void _checkFamilies(InlineSpan span, String? inherited, String what, List<String> out) {
  final family = span.style?.fontFamily ?? inherited;
  if (span is TextSpan) {
    final text = span.text;
    if (text != null && text.trim().isNotEmpty && !chromeFontFamilies.contains(family)) {
      out.add('$what "${_snippet(text)}" resolves to font family ${family ?? '(none: platform default)'}, not Figtree');
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      _checkFamilies(child, family, what, out);
    }
  }
}

void _checkPressable(Element pressable, DanaviewPressable widget, List<String> out) {
  final labels = <Element>[];
  void collect(Element e) {
    final w = e.widget;
    if (w is Icon || w is EditorContentTextRegion) return;
    if (w is RichText && w.text.toPlainText().trim().isNotEmpty) labels.add(e);
    e.visitChildren(collect);
  }

  pressable.visitChildren(collect);
  if (labels.isEmpty) return;
  final label = _snippet((labels.first.widget as RichText).text.toPlainText());
  if (widget.circle) {
    out.add('DanaviewPressable with text "$label" uses circle: true (text buttons use DanaviewRadius corners)');
    return;
  }
  for (final text in labels) {
    String? round;
    text.visitAncestorElements((ancestor) {
      if (identical(ancestor, pressable)) return false;
      round = _roundShape(ancestor);
      return round == null;
    });
    if (round != null) {
      out.add('DanaviewPressable with text "$label" is drawn as $round (text buttons use DanaviewRadius corners)');
      return;
    }
  }
}

/// Describes [element]'s shape when it is fully round around its child, else null.
String? _roundShape(Element element) {
  final w = element.widget;
  final ro = element.renderObject;
  final size = ro is RenderBox && ro.hasSize ? ro.size : null;
  if (w is ClipOval) return 'a ClipOval';
  if (w is ClipRRect && size != null && _isPill(w.borderRadius, size)) return 'a fully rounded clip';
  if (w is PhysicalShape && _isRoundBorder(w.clipper)) return 'a round PhysicalShape';
  if (w is DecoratedBox) {
    final d = w.decoration;
    if (d is BoxDecoration) {
      if (d.shape == BoxShape.circle) return 'a circle';
      final radius = d.borderRadius;
      if (radius != null && size != null && _isPill(radius, size)) return 'a pill (corner radius ≥ half the height)';
    } else if (d is ShapeDecoration) {
      if (d.shape is CircleBorder || d.shape is StadiumBorder) return 'a ${d.shape.runtimeType}';
    }
  }
  return null;
}

bool _isRoundBorder(CustomClipper<Path> clipper) =>
    clipper is ShapeBorderClipper && (clipper.shape is CircleBorder || clipper.shape is StadiumBorder);

bool _isPill(BorderRadiusGeometry geometry, Size size) {
  final minSide = size.shortestSide;
  if (minSide <= 0) return false;
  final r = geometry.resolve(TextDirection.ltr);
  final corners = [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight];
  final smallest = corners.map((c) => c.x < c.y ? c.x : c.y).reduce((a, b) => a < b ? a : b);
  return smallest >= minSide / 2 - 0.5;
}

String _snippet(String s) {
  final t = s.replaceAll('\n', ' ');
  return t.length <= 32 ? t : '${t.substring(0, 32)}…';
}
