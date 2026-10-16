// OWNER: QA-09
//
// The no-overflow matrix covers every surface BUILD_PLAN QA-09 lists (ARCH §17.9). Each surface
// maps to the matrix tests that render it: this suite's long-content tests in test/overflow/ and
// the per-ticket matrix tests (`testSurfaces`) that cover a flow's deeper states. Both kinds run
// over the PR subset in flutter-packages CI and over the full matrix in
// scripts/ci/editor/nightly.d/overflow_full.sh (`--dart-define=DANAVIEW_SURFACE_MATRIX=full`). The
// Home header, player and licences surfaces live in danaview_features and are tested at the
// repository root (danaview_editor may not import them, ARCH §4.2 rule 7). The licences page (UX-42,
// restored by FIX-LICENSES after the owner decision of 2026-10-16) is covered by
// test/editor_entry/licenses_screen_test.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Surface (as BUILD_PLAN QA-09 names it) → test files, relative to the repository root.
const Map<String, List<String>> overflowCoverage = {
  'Projects': [
    'packages/danaview_editor/test/overflow/screens_overflow_test.dart',
    'packages/danaview_editor/test/projects/projects_screen_test.dart',
  ],
  'new project': [
    'packages/danaview_editor/test/overflow/screens_overflow_test.dart',
    'packages/danaview_editor/test/flows/import/new_project_sheet_test.dart',
    'packages/danaview_editor/test/flows/import/import_media_sheet_test.dart',
  ],
  'editor in 4 layouts': [
    'packages/danaview_editor/test/overflow/editor_inspector_overflow_test.dart',
    'packages/danaview_editor/test/layout/editor_screen_layout_test.dart',
    'packages/danaview_editor/test/timeline/gestures/timeline_view_matrix_test.dart',
    'packages/danaview_editor/test/timeline/interaction/interaction_matrix_test.dart',
    'packages/danaview_editor/test/transport/transport_bar_test.dart',
    'packages/danaview_editor/test/toolbar/tool_strip_test.dart',
    'packages/danaview_editor/test/preview/surface/preview_region_test.dart',
    'packages/danaview_editor/test/render_preview/render_preview_matrix_test.dart',
  ],
  'every inspector panel': [
    'packages/danaview_editor/test/overflow/editor_inspector_overflow_test.dart',
    'packages/danaview_editor/test/inspector/inspector_host_test.dart',
    'packages/danaview_editor/test/panels/media/media_matrix_test.dart',
    'packages/danaview_editor/test/panels/text/text_panel_test.dart',
    'packages/danaview_editor/test/panels/subtitles/subtitles_panel_test.dart',
    'packages/danaview_editor/test/panels/transitions/transitions_panel_test.dart',
  ],
  'every flow sheet': [
    'packages/danaview_editor/test/overflow/editor_sheets_overflow_test.dart',
    'packages/danaview_editor/test/flows/project/project_sheet_test.dart',
    'packages/danaview_editor/test/flows/project/history_sheet_test.dart',
    'packages/danaview_editor/test/flows/tasks/tasks_matrix_test.dart',
    'packages/danaview_editor/test/panels/subtitle_io/subtitle_io_flow_test.dart',
    'packages/danaview_editor/test/actions/shortcuts_sheet_test.dart',
  ],
  'export': [
    'packages/danaview_editor/test/overflow/editor_sheets_overflow_test.dart',
    'packages/danaview_editor/test/flows/export/export_sheet_test.dart',
  ],
  'captions': [
    'packages/danaview_editor/test/overflow/editor_sheets_overflow_test.dart',
    'packages/danaview_editor/test/flows/captions/auto_captions_matrix_test.dart',
    'packages/danaview_editor/test/flows/regenerate/regenerate_matrix_test.dart',
  ],
  'relink': [
    'packages/danaview_editor/test/overflow/editor_sheets_overflow_test.dart',
    'packages/danaview_editor/test/flows/relink/relink_matrix_test.dart',
  ],
  'recovery': [
    'packages/danaview_editor/test/overflow/screens_overflow_test.dart',
    'packages/danaview_editor/test/flows/relink/recovery_test.dart',
  ],
  'settings': [
    'packages/danaview_editor/test/overflow/screens_overflow_test.dart',
    'packages/danaview_editor/test/settings/editor_settings_screen_test.dart',
  ],
  'licences': ['test/editor_entry/licenses_screen_test.dart'],
  'home header': ['test/editor_entry/home_edit_button_test.dart'],
  'player top bar': ['test/editor_entry/player_edit_action_test.dart'],
  "the player's Playback more sheet with the 'Edit video' row": ['test/editor_entry/player_edit_action_test.dart'],
  'the player shortcuts cheat sheet': ['test/editor_entry/player_edit_action_test.dart'],
};

/// The repository root (tests run from the package directory).
Directory get repoRoot => Directory.current.parent.parent;

void main() {
  test('every surface of QA-09 maps to existing matrix tests', () {
    for (final MapEntry(key: surface, value: files) in overflowCoverage.entries) {
      expect(files, isNotEmpty, reason: surface);
      for (final path in files) {
        final file = File('${repoRoot.path}/$path');
        expect(file.existsSync(), isTrue, reason: '$surface: $path is missing');
        final source = file.readAsStringSync();
        if (path.startsWith('packages/danaview_editor/')) {
          expect(source.contains('testSurfaces(') || source.contains('testOverflow('), isTrue,
              reason: '$surface: $path has no surface-matrix test (testSurfaces/testOverflow)');
        } else {
          expect(source.toLowerCase(), contains('overflow'), reason: '$surface: $path has no overflow test');
        }
      }
    }
  });

  test('the nightly script runs every matrix test of the package and the root entry tests', () {
    final script = File('${repoRoot.path}/scripts/ci/editor/nightly.d/overflow_full.sh');
    expect(script.existsSync(), isTrue);
    final source = script.readAsStringSync();
    expect(source, contains('DANAVIEW_SURFACE_MATRIX=full'));
    expect(source, contains('testSurfaces('), reason: 'discovers the per-ticket matrix tests');
    expect(source, contains('test/overflow'));
    for (final path in overflowCoverage.values.expand((f) => f).where((p) => p.startsWith('test/')).toSet()) {
      expect(source, contains(path), reason: 'the nightly script runs $path');
    }
  });
}
