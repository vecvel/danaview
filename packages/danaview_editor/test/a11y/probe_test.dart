import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../support/support.dart';
import 'a11y_support.dart';

void main() {
  testWidgets('move', (tester) async {
    final rig = await A11yEditorRig.pump(tester, surface: const EditorSurface(Size(1280, 800), platform: TargetPlatform.iOS));
    for (final id in ['it_o1', 'it_v6', 'it_t1', 'it_v1', 'it_a1', 'it_c1']) {
      print('$id ripple=${rig.state.modes.ripple} ${rig.editor.apply(MoveItems({ItemId(id)}, 3 * s, ripple: true))}');
    }
  });
}
