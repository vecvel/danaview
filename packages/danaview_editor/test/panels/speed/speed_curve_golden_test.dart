// OWNER: UX-25
//
// Golden of the speed curve editor (ux.md §10.3): a preset with a selected point, a custom curve
// with seven points, a flat curve with the device's speed range limited to 0.25-4x (the shaded
// bands), and the disabled state. Ahem font (labels are blocks), DPR 1.
//
// Regenerate (after reviewing the change) with:
//   flutter test --update-goldens test/panels/speed/speed_curve_golden_test.dart

import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/panels/speed_curve_editor.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show SpeedRampPresets;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';

class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile, {required this.tolerance});

  final double tolerance;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(imageBytes, await getGoldenBytes(golden));
    if (result.passed || result.diffPercent <= tolerance) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}

SpeedRamp custom7() => SpeedRamp(const [
      SpeedPoint(0, 1),
      SpeedPoint(0.12, 4),
      SpeedPoint(0.3, 0.5),
      SpeedPoint(0.5, 0.1),
      SpeedPoint(0.68, 2.5),
      SpeedPoint(0.85, 6),
      SpeedPoint(1, 1),
    ]);

Widget _frame(List<Widget> editors) => ColoredBox(
      color: DanaviewColors.surfaceElevated,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          for (final e in editors) Padding(padding: const EdgeInsets.only(bottom: 12), child: e),
        ]),
      ),
    );

void main() {
  setUp(() {
    final base = goldenFileComparator as LocalFileComparator;
    goldenFileComparator = _TolerantComparator(base.basedir.resolve('speed_curve_golden_test.dart'), tolerance: 0.002);
  });

  testWidgets('speed curve editor', (tester) async {
    const surface = EditorSurface(Size(400, 900));
    applySurface(tester, surface);
    await tester.pumpWidget(surfaceApp(
      surface,
      RepaintBoundary(
        key: const ValueKey<String>('golden'),
        child: _frame([
          SpeedCurveEditor(ramp: SpeedRampPresets.byId('hero')!, selected: 2),
          SpeedCurveEditor(ramp: custom7(), selected: 5),
          SpeedCurveEditor(ramp: SpeedRamp(const [SpeedPoint(0, 2), SpeedPoint(0.5, 2), SpeedPoint(1, 2)]), minSpeed: 0.25, maxSpeed: 4),
          SpeedCurveEditor(ramp: SpeedRampPresets.byId('bullet')!, enabled: false),
        ]),
      ),
    ));
    await tester.pump();
    expectNoOverflow(tester);
    await expectLater(find.byKey(const ValueKey<String>('golden')), matchesGoldenFile('goldens/speed_curve_editor.png'));
  });
}
