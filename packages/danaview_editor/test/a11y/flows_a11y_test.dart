// OWNER: QA-08
//
// Accessibility of the editor's modal flows (ARCH §17.2, §17.7): export, auto captions,
// regenerate captions, relink, recovery, import, project, track menu, markers, history, tasks, the
// shortcuts sheet, the subtitle export sheet, the freeze-frame sheet (ux.md §10.15) and the render
// preview range sheet (UX-44, offered from an amber range of the render marker strip), opened over
// the real editor screen on the narrow and wide PR surfaces at the largest text scale. The editor
// runs with a render-preview store and a plan with heavy ranges, so the strip shows amber ranges. Each one: tap targets ≥ 44×44 with labels, text
// contrast ≥ 4.5:1, nothing overflows.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/actions/shortcuts_sheet.dart';
import 'package:danaview_editor/src/editor/flows/captions/auto_captions_sheet.dart';
import 'package:danaview_editor/src/editor/flows/captions/regenerate_sheet.dart';
import 'package:danaview_editor/src/editor/flows/export/export_sheet.dart';
import 'package:danaview_editor/src/editor/flows/history_sheet.dart';
import 'package:danaview_editor/src/editor/flows/import_media_sheet.dart';
import 'package:danaview_editor/src/editor/flows/project_sheet.dart';
import 'package:danaview_editor/src/editor/flows/relink/recovery_dialog.dart';
import 'package:danaview_editor/src/editor/flows/relink/relink_sheet.dart';
import 'package:danaview_editor/src/editor/flows/tasks_sheet.dart';
import 'package:danaview_editor/src/editor/layout/editor_top_bar.dart';
import 'package:danaview_editor/src/editor/panels/subtitle_io.dart';
import 'package:danaview_editor/src/editor/timeline/marker_sheet.dart';
import 'package:danaview_editor/src/editor/timeline/render_marker_strip.dart' show showRenderRangeSheet;
import 'package:danaview_editor/src/editor/timeline/track_menu_sheet.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/store.dart' show RecoverableSession;

import '../flows/import/import_fakes.dart' show ScriptedPool, pickOf;
import '../support/support.dart';
import 'a11y_support.dart';

typedef _Opener = void Function(BuildContext context, A11yEditorRig rig);

final Map<String, _Opener> _flows = {
  'export': (c, r) => unawaited(ExportSheet.show(c, projectId: r.id)),
  'auto captions': (c, r) => unawaited(AutoCaptionsSheet.show(c, projectId: r.id)),
  'regenerate captions': (c, r) => unawaited(RegenerateSheet.show(c, projectId: r.id, track: const TrackId('tr_subs'))),
  'relink': (c, r) => unawaited(showRelinkSheet(c, projectId: r.id)),
  'recovery dialog': (c, r) => unawaited(showEditorRecoveryDialog(
        c,
        RecoverableSession(
          projectId: r.id,
          projectName: 'A project with a long name that keeps going for a while',
          journalRevision: 3,
          mainRevision: 2,
          journalSavedAt: DateTime.utc(2026, 10, 8, 11),
        ),
        now: DateTime.utc(2026, 10, 8, 12),
      )),
  'import media': (c, r) => unawaited(showImportMediaSheet(
        c,
        picks: [pickOf('holiday clip with a rather long file name.mp4'), pickOf('photo.jpg')],
        job: sessionImportJob(pool: ScriptedPool(), session: r.container.read(editorSessionProvider(r.id)).edit),
        closeWhenAllAdded: false,
      )),
  'project sheet': (c, r) => unawaited(ProjectSheet.show(r.ctx)),
  'track menu': (c, r) => unawaited(TrackMenuSheet.show(c, projectId: r.id, track: const TrackId('tr_main'))),
  'marker sheet': (c, r) => unawaited(MarkerSheet.show(c, projectId: r.id, marker: const MarkerId('mk_1'))),
  'history': (c, r) => unawaited(HistorySheet.show(c, projectId: r.id)),
  'tasks': (c, r) => unawaited(TasksSheet.show(c, projectId: r.id)),
  'shortcuts': (c, r) => unawaited(ShortcutsSheet.show(c, projectId: r.id)),
  'subtitle export': (c, r) => unawaited(showSubtitleExportSheet(c, project: r.project)),
  'freeze frame': (c, r) => unawaited(FreezeFrameSheet.show(c)),
  'render preview range': (c, r) =>
      unawaited(showRenderRangeSheet(c, controller: r.renderPreview, range: r.renderPreview.value.heavyUnrendered.first)),
};

const List<EditorSurface> _surfaces = [
  EditorSurface(Size(280, 500), textScale: 1.35),
  EditorSurface(Size(568, 320), textScale: 1.35),
  EditorSurface(Size(390, 844), platform: TargetPlatform.iOS),
  EditorSurface(Size(1194, 834), textScale: 1.35, platform: TargetPlatform.iOS),
];

void main() {
  for (final surface in _surfaces) {
    group('[$surface]', () {
      for (final MapEntry(key: name, value: open) in _flows.entries) {
        testWidgets(name, (tester) async {
          final semantics = tester.ensureSemantics();
          final rig = await A11yEditorRig.pump(tester, surface: surface, renderPreview: true);
          await rig.showHeavyRanges();
          final context = tester.element(find.byType(EditorTopBar));
          open(context, rig);
          await rig.real(() async {});
          await rig.settle();
          await rig.real(() async {});
          await rig.settle();
          expect(takeKnownException(tester, where: 'opening $name'), isNull);
          expect(Navigator.of(context).canPop(), isTrue, reason: '$name did not open a sheet or dialog');
          expectNoOverflow(tester);
          await expectA11yGuidelines(tester, where: '$name on $surface');
          semantics.dispose();
        });
      }
    });
  }
}
