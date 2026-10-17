// OWNER: QA-09
//
// No-overflow matrix (BUILD_PLAN QA-09, ARCH §1.3 rule 5, §17.9): the real EditorScreen on the
// long-content project in every layout kind the surface resolves to (the matrix covers all four,
// asserted below), idle, with each item kind selected (context tools), and with every inspector
// panel open (every text tab, both audio focuses, every subtitles section, the transition panel and
// the project-level panels). Each state: takeException() == null, the top bar inside the screen,
// no truncated button label or section header.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_dock.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_header.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_host.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor_core/eval.dart' show validate;
import 'package:danaview_editor_core/model.dart';

import '../support/support.dart';
import 'overflow_fixtures.dart';
import 'overflow_rig.dart';

/// Every inspector route over the long-content project, with the item it targets (selected first).
List<(String, ItemId?, InspectorRoute)> inspectorStates() => [
      ('media', null, const MediaInspector()),
      ('voiceover', null, const VoiceoverInspector()),
      ('overlay add', null, const OverlayInspector()),
      ('format', null, const CanvasInspector()),
      ('transform', LongIds.clipA, const TransformInspector(LongIds.clipA)),
      ('crop', LongIds.clipA, const CropInspector(LongIds.clipA)),
      ('mask', LongIds.overlayItem, const MaskInspector(LongIds.overlayItem)),
      ('speed', LongIds.clipA, const SpeedInspector(LongIds.clipA)),
      ('volume', LongIds.musicItem, const AudioInspector(LongIds.musicItem)),
      ('fades', LongIds.voiceItem, const AudioInspector(LongIds.voiceItem, focus: AudioPanelFocus.fades)),
      ('adjust', LongIds.clipB, const AdjustInspector(LongIds.clipB)),
      ('filters', LongIds.clipB, const FiltersInspector(LongIds.clipB)),
      ('chroma', LongIds.overlayItem, const ChromaInspector(LongIds.overlayItem)),
      ('keyframes', LongIds.clipA, const KeyframesInspector(LongIds.clipA)),
      for (final tab in TextPanelTab.values) ('text ${tab.name}', LongIds.textItem, TextInspector(LongIds.textItem, tab: tab)),
      ('clip info', LongIds.clipA, const ClipInfoInspector(LongIds.clipA)),
      ('captions start', null, const SubtitlesInspector()),
      for (final section in SubtitlesPanelSection.values)
        ('captions ${section.name}', LongIds.cue1, SubtitlesInspector(track: LongIds.subtitles, cue: LongIds.cue1, section: section)),
      ('transition', null, const TransitionInspector(LongIds.cut)),
    ];

void main() {
  setUpAll(loadRealFonts);

  test('the full matrix resolves every layout kind, with and without the inspector', () {
    for (final open in [false, true]) {
      final kinds = {
        for (final s in SurfaceMatrix.full)
          EditorLayoutSpec.resolve(
            size: s.size,
            padding: EdgeInsets.zero,
            viewInsets: EdgeInsets.only(bottom: s.keyboardInset),
            textScaler: TextScaler.linear(s.textScale),
            touch: s.touch,
            splitRatio: null,
            inspectorOpen: open,
          ).kind,
      };
      expect(kinds, EditorLayoutKind.values.toSet(), reason: 'inspector open: $open');
    }
  });

  test('the PR subset has 6 surfaces including 280x500 @1.35 and 568x320 @1.35', () {
    expect(SurfaceMatrix.pr, hasLength(6));
    expect(SurfaceMatrix.pr, contains(const EditorSurface(Size(280, 500), textScale: 1.35)));
    expect(SurfaceMatrix.pr, contains(const EditorSurface(Size(568, 320), textScale: 1.35)));
    expect(SurfaceMatrix.full, hasLength(84));
  });

  test('the long-content fixture is a valid project', () {
    expect(validate(longProject()), isEmpty);
    expect(longProjectName.length, lessThanOrEqualTo(80));
    expect(longProjectName.length, greaterThan(75));
  });

  testOverflow('editor idle and with each item kind selected', (tester, surface) async {
    final rig = await OverflowEditor.pump(tester, surface);
    rig.check('idle');
    for (final item in [LongIds.clipA, LongIds.still, LongIds.overlayItem, LongIds.textItem, LongIds.cue1, LongIds.musicItem, LongIds.voiceItem]) {
      rig.editor.select(item);
      await rig.settle();
      rig.check('selected $item');
    }
    rig.editor.selectTransition(LongIds.cut);
    await rig.settle();
    rig.check('selected transition');
    rig.editor
      ..setModes((m) => m.copyWith(multiSelect: true))
      ..select(LongIds.clipA);
    await rig.settle();
    rig.check('multi-select, 1 selected');
    rig.editor.selectAll();
    await rig.settle();
    rig.check('multi-select, all selected');
    rig.editor
      ..setModes((m) => m.copyWith(multiSelect: false))
      ..clearSelection();
    await rig.settle();
    rig.check('cleared');
  });

  testOverflow('editor with every inspector panel', (tester, surface) async {
    final rig = await OverflowEditor.pump(tester, surface);
    for (final (name, item, route) in inspectorStates()) {
      if (item != null) {
        rig.editor.select(item);
      } else if (route is TransitionInspector) {
        rig.editor.selectTransition(route.cut);
      } else {
        rig.editor.clearSelection();
      }
      await tester.pump();
      rig.editor.openInspector(route);
      await rig.settle();
      if (rig.state.inspector != route) rig.log.add('[$name] the panel did not stay open (${rig.state.inspector})');
      if (find.byType(InspectorHeader).evaluate().length != 1) rig.log.add('[$name] no inspector header');
      final panel = rig.spec.kind == EditorLayoutKind.compactPortrait ? find.byType(InspectorDock) : find.byType(InspectorHost);
      rig.check(name, inside: [find.byType(InspectorHeader), panel]);
      rig.editor.closeInspector();
      await rig.settle();
    }
    rig.check('closed');
  });
}
