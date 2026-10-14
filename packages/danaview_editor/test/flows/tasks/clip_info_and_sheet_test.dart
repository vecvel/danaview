// OWNER: UX-35
//
// The clip info panel and the Tasks sheet (ux.md §10.15) with fake jobs: the info rows; the
// "Reversing 45%" status with Cancel reverse; a failed rendition with Try again; a pending freeze
// still; the deleted clip; the sheet's rows with progress, Cancel, Try again and Dismiss, following
// the state while open; the preview task indicator source (EditorState.tasks); a replacement of the
// wrong kind is refused.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/clip_strings.dart';
import 'package:danaview_editor/src/app/strings/media_strings.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/flows/tasks_sheet.dart';
import 'package:danaview_editor/src/editor/panels/clip_info_panel.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show EngineFailure, EngineErrorCode;

import '../../support/support.dart';
import 'tasks_rig.dart';

Finder key(String k) => find.byKey(ValueKey<String>(k));

String rowValue(WidgetTester tester, String label) {
  final row = key('clipInfo.row.$label');
  final texts = tester.widgetList<Text>(find.descendant(of: row, matching: find.byType(Text))).toList();
  return texts.last.data!;
}

void main() {
  group('clip info panel', () {
    testWidgets('shows name, source, duration, source in/out, speed, direction, picture, audio, size and storage', (tester) async {
      final rig = await TasksRig.pump(tester, open: const ClipInfoInspector(TaskIds.video));
      expect(find.byType(ClipInfoPanel), findsOneWidget);
      expect(rowValue(tester, ClipStrings.infoName), 'beach.mp4');
      expect(rowValue(tester, ClipStrings.infoSource), 'beach.mp4');
      expect(rowValue(tester, ClipStrings.infoDuration), Timecode.format(12 * s, rate));
      expect(rowValue(tester, ClipStrings.infoSourceIn), Timecode.format(5 * s, rate));
      expect(rowValue(tester, ClipStrings.infoSourceOut), Timecode.format(17 * s, rate));
      expect(rowValue(tester, ClipStrings.infoSpeed), '1×');
      expect(rowValue(tester, ClipStrings.infoDirection), ClipStrings.forward);
      expect(rowValue(tester, ClipStrings.infoResolution), '1920×1080');
      expect(rowValue(tester, ClipStrings.infoFrameRate), '30 fps');
      expect(rowValue(tester, ClipStrings.infoCodec), 'H264');
      expect(rowValue(tester, ClipStrings.infoAudio), 'AAC · Stereo · 48 kHz');
      expect(rowValue(tester, ClipStrings.infoSize), isNotEmpty);
      expect(rowValue(tester, ClipStrings.infoLocation), ClipStrings.location(MediaOwnership.managedCopy));
      expect(rowValue(tester, ClipStrings.infoStatus), ClipStrings.statusReady);
      expect(key('clipInfo.derived'), findsNothing);
      expectNoOverflow(tester);
      await rig.finish();
    });

    testWidgets('an image has no time rows and no audio row', (tester) async {
      final rig = await TasksRig.pump(tester, open: const ClipInfoInspector(TaskIds.image));
      expect(key('clipInfo.row.${ClipStrings.infoSourceIn}'), findsNothing);
      expect(key('clipInfo.row.${ClipStrings.infoAudio}'), findsNothing);
      expect(key('clipInfo.row.${ClipStrings.infoResolution}'), findsOneWidget);
      await rig.finish();
    });

    testWidgets('a reversing clip shows "Reversing 45%" with Cancel reverse, then switches to Ready', (tester) async {
      final rig = await TasksRig.pump(tester, open: const ClipInfoInspector(TaskIds.video));
      rig.tasks.reverse(TaskIds.video);
      await rig.settle();
      final job = rig.job('reverse');
      job.report(0.45);
      await rig.settle();
      expect(find.text('Reversing 45%'), findsOneWidget);
      expect(rowValue(tester, ClipStrings.infoDirection), ClipStrings.reversed);
      expect(key('clipInfo.cancel'), findsOneWidget);
      await rig.complete(job);
      expect(key('clipInfo.derived'), findsNothing);
      await rig.finish();
    });

    testWidgets('Cancel reverse in the panel cancels the job and plays the clip forward', (tester) async {
      final rig = await TasksRig.pump(tester, open: const ClipInfoInspector(TaskIds.video));
      rig.tasks.reverse(TaskIds.video);
      await rig.settle();
      final job = rig.job('reverse');
      await tester.tap(key('clipInfo.cancel'));
      await rig.settle();
      expect(job.cancelled, isTrue);
      expect(rig.clip(TaskIds.video).reversed, isFalse);
      expect(key('clipInfo.derived'), findsNothing);
      await rig.finish();
    });

    testWidgets('a failed rendition shows Try again, which restarts the job', (tester) async {
      final rig = await TasksRig.pump(tester, open: const ClipInfoInspector(TaskIds.video));
      rig.tasks.reverse(TaskIds.video);
      await rig.settle();
      rig.job('reverse').fail(EngineFailure.of(EngineErrorCode.decodeFailed));
      await rig.settle();
      expect(find.text(ClipStrings.reverseFailed), findsOneWidget);
      await tester.tap(key('clipInfo.retry'));
      await rig.settle();
      expect(rig.jobs.created.where((j) => j.id.startsWith('reverse-')), hasLength(2));
      expect(find.text(ClipStrings.reversing(null)), findsOneWidget);
      await rig.finish();
    });

    testWidgets('a pending freeze still shows its progress and source', (tester) async {
      final rig = await TasksRig.pump(tester);
      rig.tasks.freeze(TaskIds.video, 4 * s, 3 * s);
      await rig.settle();
      final still = rig.state.selection.primary!;
      rig.editor.openInspector(ClipInfoInspector(still));
      await rig.settle();
      rig.job('freezeFrame').report(0.5);
      await rig.settle();
      expect(find.text(ClipStrings.freezing(0.5)), findsOneWidget);
      expect(rowValue(tester, ClipStrings.infoSource), 'beach.mp4');
      expect(rowValue(tester, ClipStrings.infoLocation), ClipStrings.location(MediaOwnership.projectOwned));
      await rig.finish();
    });
  });

  group('tasks sheet', () {
    testWidgets('lists rows with progress, follows the state, cancels, retries and dismisses', (tester) async {
      final rig = await TasksRig.pump(tester);
      rig.tasks.reverse(TaskIds.video);
      rig.tasks.requestProxy(const MediaId('md_silent'));
      await rig.settle();
      expect(rig.state.tasks, hasLength(2), reason: 'the preview task badge counts these');
      await tester.runAsync(() async {});
      unawaited(TasksSheet.show(tester.element(find.byType(RegionFrame)), projectId: rig.id));
      // Step (not settle): indeterminate progress bars animate for as long as they show.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final reverse = rig.job('reverse');
      final proxy = rig.job('proxy');
      expect(key('tasks.row.${reverse.id}'), findsOneWidget);
      expect(key('tasks.row.${proxy.id}'), findsOneWidget);
      expect(find.text('Reversing a clip'), findsOneWidget);
      expect(find.text('Optimizing a clip for editing'), findsOneWidget);
      reverse.report(0.3);
      await rig.settle();
      expect(find.text(ClipStrings.taskProgress(0.3)), findsOneWidget);
      // Cancel the proxy.
      await tester.tap(key('tasks.cancel.${proxy.id}'));
      await rig.settle();
      expect(proxy.cancelled, isTrue);
      expect(key('tasks.row.${proxy.id}'), findsNothing);
      expect(rig.asset(const MediaId('md_silent')).proxy, ProxyState.none);
      // Fail the reverse: Try again, then fail again and dismiss.
      reverse.fail(EngineFailure.of(EngineErrorCode.io));
      await rig.settle();
      expect(find.text(ClipStrings.taskFailed), findsOneWidget);
      await tester.tap(key('tasks.retry.${reverse.id}'));
      await rig.settle();
      final again = rig.job('reverse');
      expect(again, isNot(same(reverse)));
      expect(key('tasks.row.${again.id}'), findsOneWidget);
      again.fail(EngineFailure.of(EngineErrorCode.io));
      await rig.settle();
      await tester.tap(key('tasks.dismiss.${again.id}'));
      await rig.settle();
      expect(rig.state.tasks, isEmpty);
      expect(key('tasks.empty'), findsOneWidget);
      expectNoOverflow(tester);
      await rig.finish();
    });
  });

  group('replace kind mismatch', () {
    testWidgets('audio picked for a video clip is refused with the reason', (tester) async {
      final pool = ScriptedPool()..steps['song.m4a'] = const AddStep(kind: MediaKind.audio);
      final rig = await TasksRig.pump(tester, pool: pool);
      rig.editor.select(TaskIds.silent);
      await rig.settle();
      rig.engine.picker.nextPicks = [pickOf('song.m4a', size: 1000)];
      rig.registry.invoke(EditorActionId.replace, rig.ctx);
      final reason = find.text(MediaStrings.replaceKindMismatch);
      for (var i = 0; i < 40 && reason.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(reason, findsOneWidget);
      expect(rig.clip(TaskIds.silent).media, const MediaId('md_silent'));
      expect(rig.entries, 0);
      await tester.pumpAndSettle();
      await rig.finish();
    });
  });
}
