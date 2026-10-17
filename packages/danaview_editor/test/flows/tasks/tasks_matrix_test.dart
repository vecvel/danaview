// OWNER: UX-35
//
// The surface matrix (ARCH §17.9) for the clip info panel (with a reversing status and long names),
// the Tasks sheet (running and failed rows) and the freeze frame sheet: no overflow from 280 to
// 1280 px wide at text scale 0.85-1.35, and the owner UI rules hold (custom components, Figtree).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/flows/tasks_sheet.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show EngineFailure, EngineErrorCode;

import '../../support/support.dart';
import 'tasks_rig.dart';

const String longName = 'A very long video file name from the family holiday that keeps going and going and going.mp4';

void main() {
  testSurfaces('the clip info panel with a reversing status and long names', (tester, surface) async {
    final rig = await TasksRig.pump(
      tester,
      surface: surface,
      extraAssets: [rigAsset('md_video', MediaKind.video, name: longName)],
      open: const ClipInfoInspector(TaskIds.video),
    );
    rig.tasks.reverse(TaskIds.video);
    await rig.settle();
    rig.job('reverse').report(0.45);
    await rig.settle();
    expectNoOverflow(tester);
    expectOwnerUiRules(tester);
    await rig.finish();
  });

  testSurfaces('the tasks sheet with running and failed rows', (tester, surface) async {
    final rig = await TasksRig.pump(tester, surface: surface);
    rig.tasks.reverse(TaskIds.video);
    rig.tasks.requestProxy(const MediaId('md_silent'));
    rig.tasks.begin(EditorTaskKind.download).progress(0.7);
    await rig.settle();
    rig.job('reverse').fail(EngineFailure.of(EngineErrorCode.io));
    await rig.settle();
    unawaited(TasksSheet.show(tester.element(find.byType(RegionFrame)), projectId: rig.id));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(TaskRow), findsNWidgets(3));
    expectNoOverflow(tester);
    expectOwnerUiRules(tester);
    await rig.finish();
  });

  testSurfaces('the freeze frame sheet', (tester, surface) async {
    final rig = await TasksRig.pump(tester, surface: surface);
    unawaited(FreezeFrameSheet.show(tester.element(find.byType(RegionFrame))));
    await tester.pumpAndSettle();
    expect(find.byType(FreezeFrameSheet), findsOneWidget);
    expectNoOverflow(tester);
    expectOwnerUiRules(tester);
    await rig.finish();
  });
}
