// OWNER: QA-09
//
// No-overflow matrix (BUILD_PLAN QA-09, ARCH §1.3 rule 5, §17.9): every flow sheet of the editor
// opened from the real EditorScreen on the long-content project, as the user reaches it (through
// its action, or the sheet's own entry point where the action needs a platform picker): project,
// history, tasks, export, keyboard shortcuts, add track, move to track, marker, export subtitles,
// freeze frame, fullscreen preview, Auto captions, the track menu of every lane kind, and the
// missing media banner with the relink sheet. Each state: takeException() == null, the top bar
// inside the screen, no truncated button label or section header. The deeper states of each flow
// (export progress and failure, caption download and progress, relink rows) have their own matrix
// tests that overflow_full.sh runs over the full matrix.

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/flows/captions/auto_captions_sheet.dart';
import 'package:danaview_editor/src/editor/flows/relink/relink_sheet.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor/src/editor/timeline/track_menu_sheet.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/store.dart' show MediaAvailability;
import 'package:danaview_transcription/testing.dart';

import '../support/support.dart';
import 'overflow_fixtures.dart';
import 'overflow_rig.dart';

/// A sheet opened through an action, after [prepare] set the selection or playhead.
typedef _ActionSheet = (String name, EditorActionId action, Future<void> Function(OverflowEditor rig)? prepare);

final List<_ActionSheet> _actionSheets = [
  ('project', EditorActionId.projectSheet, null),
  ('history', EditorActionId.history, null),
  ('tasks', EditorActionId.tasks, null),
  ('export', EditorActionId.export, null),
  ('shortcuts', EditorActionId.showShortcuts, null),
  ('add track', EditorActionId.addTrack, null),
  ('export subtitles', EditorActionId.exportSubtitles, null),
  ('fullscreen preview', EditorActionId.fullscreenPreview, null),
  ('marker', EditorActionId.editMarker, (rig) async => rig.editor.selectMarker(const MarkerId('mk_ovmark00001'))),
  ('move to track', EditorActionId.moveToTrack, (rig) async => rig.editor.select(LongIds.overlayItem)),
  (
    'freeze frame',
    EditorActionId.freeze,
    (rig) async {
      rig.editor.select(LongIds.clipA);
      await rig.real(() => rig.container.read(playheadProvider(rig.id)).seekExact(1 * microsPerSecond + 500000));
    },
  ),
];

Future<void> _closeTop(OverflowEditor rig) async {
  while (rig.navigator.canPop()) {
    rig.navigator.pop();
    await rig.settle();
  }
}

/// Checks the sheet [open] shows, then closes it.
Future<void> _sheet(OverflowEditor rig, String name, void Function() open, {Finder? shows}) async {
  open();
  await rig.settle();
  if (!rig.navigator.canPop()) {
    rig.log.add('[$name] did not open a sheet');
    return;
  }
  if (shows != null && shows.evaluate().isEmpty) rig.log.add('[$name] does not show $shows');
  rig.check(name);
  await _closeTop(rig);
  rig.check('$name closed');
}

void main() {
  setUpAll(loadRealFonts);

  testOverflow('editor flow sheets opened through their actions', (tester, surface) async {
    final rig = await OverflowEditor.pump(tester, surface);
    for (final (name, action, prepare) in _actionSheets) {
      rig.editor.clearSelection();
      await rig.settle();
      await prepare?.call(rig);
      await rig.settle();
      final registry = rig.container.read(editorActionRegistryProvider);
      // With the keyboard up the layout ladder hides the preview, so there is nothing to show
      // fullscreen (ARCH §17.2 degradation ladder).
      if (action == EditorActionId.fullscreenPreview && !rig.spec.shows(EditorRegion.preview)) continue;
      await _sheet(rig, name, () {
        final result = registry.invoke(action, WidgetActionContext.container(projectId: rig.id, context: rig.context, container: rig.container));
        if (result != EditorActionResult.ran) rig.log.add('[$name] ${action.name} did not run: $result');
      });
    }
  });

  testOverflow('auto captions sheet and the track menu of every lane kind', (tester, surface) async {
    final transcription = FakeTranscriptionService(physicalRamBytes: 8 << 30, clock: () => DateTime.utc(2026, 10, 15, 12));
    final rig = await OverflowEditor.pump(tester, surface, transcription: transcription);
    await _sheet(rig, 'auto captions', () => AutoCaptionsSheet.show(rig.context, projectId: rig.id));
    for (final track in [LongIds.main, LongIds.overlay, LongIds.text, LongIds.subtitles, LongIds.music, LongIds.voice]) {
      await _sheet(rig, 'track menu $track', () => TrackMenuSheet.show(rig.context, projectId: rig.id, track: track));
    }
  });

  testOverflow('missing media: editor banner and the relink sheet', (tester, surface) async {
    final pool = FakeMediaPoolService()
      ..availability = {
        const MediaId('md_ovvid000001'): MediaAvailability.missing,
        const MediaId('md_ovimg000001'): MediaAvailability.accessLost,
        const MediaId('md_ovsong00001'): MediaAvailability.changed,
      };
    final rig = await OverflowEditor.pump(tester, surface, mediaPool: pool);
    await rig.settle();
    rig.check('missing media banner');
    await _sheet(rig, 'relink', () => showRelinkSheet(rig.context, projectId: rig.id), shows: find.textContaining('VID_20261014', skipOffstage: false));
    // Keep the container in use until the sheet's controller released its listeners.
    expect(rig.container.read(editorControllerProvider(rig.id)).project, isNotNull);
  });
}
