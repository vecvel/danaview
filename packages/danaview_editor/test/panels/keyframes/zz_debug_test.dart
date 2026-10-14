import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart';
import '../../support/support.dart';
import 'keyframes_panel_test.dart' show selectKey;
import 'keyframes_rig.dart';
void main() {
  testWidgets('dbg', (tester) async {
    final rig = await KfRig.pump(tester, surface: const EditorSurface(Size(280, 500), textScale: 1.35), at: 1 * s);
    final errs = <FlutterErrorDetails>[];
    final old = FlutterError.onError;
    FlutterError.onError = (d) { errs.add(d); };
    await selectKey(rig, PropertyKeys.opacity, 1 * s);
    await tester.pump();
    FlutterError.onError = old;
    for (final e in errs) { debugPrint(e.toStringShort()); for (final i in e.informationCollector?.call() ?? const <DiagnosticsNode>[]) { debugPrint(i.toStringDeep().split('\n').take(12).join('\n')); } }
    tester.takeException();
  });
}
