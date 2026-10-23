// OWNER: UX-01
//
// `expectNeutralBorders(tester)`: the owner's border rule ("near-transparent borders only, no
// coloured/accent/warning outlines"). Every `DecoratedBox` in the tree (which covers `Container`,
// `AnimatedContainer` and `DanaviewSurface`) whose `BoxDecoration` draws a `Border` must use a
// neutral (grey/white/black) colour at no more than [maxNeutralBorderAlpha] opacity. Fully
// transparent sides are ignored. Selection indicators that carry meaning (a selected look ring,
// a selected swatch) are checked by their own tests, so callers scope with [of] or [skip].

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The brightest neutral border allowed (the kit's hairline is 0.08, `DanaviewColors.border` 0.10).
const double maxNeutralBorderAlpha = 0.2;

/// Fails the test when a border in the tree (or below [of]) is coloured or too opaque.
void expectNeutralBorders(WidgetTester tester, {Finder? of, Finder? skip}) {
  final violations = neutralBorderViolations(tester, of: of, skip: skip);
  expect(violations, isEmpty, reason: 'near-transparent neutral borders only:\n${violations.map((v) => '  $v').join('\n')}');
}

/// True when [color] is a grey/white/black at most [maxNeutralBorderAlpha] opaque, or transparent.
bool isNeutralBorderColor(Color color) {
  if (color.a == 0) return true;
  const tolerance = 2 / 255;
  final grey = (color.r - color.g).abs() <= tolerance && (color.g - color.b).abs() <= tolerance;
  return grey && color.a <= maxNeutralBorderAlpha + 0.001;
}

/// Every coloured or too-opaque border side in the tree (or below [of]).
List<String> neutralBorderViolations(WidgetTester tester, {Finder? of, Finder? skip}) {
  final boxes = of == null
      ? find.byType(DecoratedBox)
      : find.descendant(of: of, matching: find.byType(DecoratedBox), matchRoot: true);
  final skipped = skip == null
      ? const <Element>{}
      : find.descendant(of: skip, matching: find.byType(DecoratedBox), matchRoot: true).evaluate().toSet();
  final out = <String>[];
  for (final element in boxes.evaluate()) {
    if (skipped.contains(element)) continue;
    final box = element.widget as DecoratedBox;
    final decoration = box.decoration;
    if (decoration is! BoxDecoration) continue;
    final border = decoration.border;
    if (border is! Border) continue;
    for (final side in [border.top, border.right, border.bottom, border.left]) {
      if (side.style == BorderStyle.none || side.width == 0) continue;
      if (!isNeutralBorderColor(side.color)) {
        out.add('${_owner(element)}: border ${side.color} (alpha ${side.color.a.toStringAsFixed(2)})');
        break;
      }
    }
  }
  return out;
}

String _owner(Element element) {
  String? found;
  element.visitAncestorElements((a) {
    final key = a.widget.key;
    if (key is ValueKey) {
      found = '${a.widget.runtimeType}($key)';
      return false;
    }
    return true;
  });
  return found ?? element.widget.runtimeType.toString();
}
