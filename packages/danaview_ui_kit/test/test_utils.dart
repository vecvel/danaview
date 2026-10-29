import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

class Surface {
  const Surface(this.name, this.size, this.textScale, this.platform);

  final String name;
  final Size size;
  final double textScale;
  final TargetPlatform platform;

  @override
  String toString() => name;
}

const List<Surface> surfaces = [
  Surface('narrow touch 1.0x', Size(280, 500), 1.0, TargetPlatform.android),
  Surface('narrow touch 1.35x', Size(280, 500), 1.35, TargetPlatform.iOS),
  Surface('wide desktop 1.0x', Size(1200, 800), 1.0, TargetPlatform.macOS),
  Surface('wide desktop 1.35x', Size(1200, 800), 1.35, TargetPlatform.windows),
];

const String longText =
    'An extraordinarily long label that keeps going well past any reasonable width for a control';

Future<void> pumpKit(WidgetTester tester, Surface surface, Widget child) async {
  tester.view.physicalSize = surface.size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: DanaviewTheme.darkTheme.copyWith(platform: surface.platform),
      builder: (context, navigator) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(surface.textScale)),
        child: navigator!,
      ),
      home: Scaffold(body: SafeArea(child: child)),
    ),
  );
}

void expectNoErrors(WidgetTester tester) {
  expect(tester.takeException(), isNull);
}

void expectInside(WidgetTester tester, Finder finder, Size screen) {
  final rect = tester.getRect(finder);
  final bounds = Offset.zero & screen;
  expect(rect.left >= bounds.left - 0.01 && rect.top >= bounds.top - 0.01, isTrue, reason: '$rect outside $bounds');
  expect(rect.right <= bounds.right + 0.01 && rect.bottom <= bounds.bottom + 0.01, isTrue, reason: '$rect outside $bounds');
}

/// The decorated frame (the filled box a control paints) of the first control under [control].
AnimatedContainer controlFrameWidget(WidgetTester tester, Finder control) => tester.widget<AnimatedContainer>(_frame(control));

Finder _frame(Finder control) => find
    .descendant(
      of: control,
      matching: find.byWidgetPredicate((w) => w is AnimatedContainer && w.decoration != null),
      matchRoot: true,
    )
    .first;

/// Expects every control in [controls] to paint a frame of the same height, centred on one line.
void expectEqualRowHeights(WidgetTester tester, List<Finder> controls, {double? height}) {
  final frames = [for (final c in controls) tester.getRect(_frame(c))];
  final expected = height ?? frames.first.height;
  for (final (i, f) in frames.indexed) {
    expect(f.height, moreOrLessEquals(expected, epsilon: 0.5), reason: 'control $i height');
    expect(f.center.dy, moreOrLessEquals(frames.first.center.dy, epsilon: 0.5), reason: 'control $i centre');
  }
}
