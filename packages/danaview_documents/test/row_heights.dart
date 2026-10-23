import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The decorated frame (the filled box a control paints) of the first control under [control]:
/// the hit area can be taller on touch platforms, the frame is what the eye lines up.
Finder controlFrame(Finder control) => find
    .descendant(
      of: control,
      matching: find.byWidgetPredicate((w) => w is AnimatedContainer && w.decoration != null),
      matchRoot: true,
    )
    .first;

/// Owner rule: every control in a row that mixes an input with buttons paints a frame of the same
/// height ([height] when given), centred on one line.
void expectEqualRowHeights(WidgetTester tester, List<Finder> controls, {double? height}) {
  final frames = [for (final c in controls) tester.getRect(controlFrame(c))];
  final expected = height ?? frames.first.height;
  for (final (i, f) in frames.indexed) {
    expect(f.height, moreOrLessEquals(expected, epsilon: 0.5), reason: 'control $i height');
    expect(f.center.dy, moreOrLessEquals(frames.first.center.dy, epsilon: 0.5), reason: 'control $i centre');
  }
}
