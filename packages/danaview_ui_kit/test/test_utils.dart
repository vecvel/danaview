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
