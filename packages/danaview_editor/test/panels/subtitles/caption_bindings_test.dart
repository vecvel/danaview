// OWNER: UX-31
//
// The caption action bindings (ARCH §17.6, ux.md §9.1, §10.9) and the panel's pure model:
// `captions` and `addCaption` are bound once by caption_bindings; `captions` opens the panel for the
// selected subtitle lane, the selected cue's lane or the topmost lane (the start state without
// one; the Style section from the track menu's Style row); `addCaption` dispatches one AddCue at
// the playhead and opens the panel on the new cue. The model: shift entry parsing (Timecode.parse:
// +2.5s, -10f), the cue under the playhead, the selected range and track names.

import 'package:flutter/services.dart' show TextSelection;
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/subtitle_strings.dart';
import 'package:danaview_editor/src/editor/actions/bindings/caption_bindings.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/panels/subtitles_panel.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show EditorSelection;
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_editor_core/model.dart';

import 'subtitles_rig.dart';

void main() {
  tearDown(EditorAnnouncer.instance.reset);

  group('model', () {
    test('shift entries: seconds and frames, signed, quantized to the grid', () {
      expect(SubtitlesPanelModel.shiftDelta('+2.5s', rate), frames(75));
      expect(SubtitlesPanelModel.shiftDelta('-2.5s', rate), -frames(75));
      expect(SubtitlesPanelModel.shiftDelta('-10f', rate), -frames(10));
      expect(SubtitlesPanelModel.shiftDelta('+10f', rate), frames(10));
      expect(SubtitlesPanelModel.shiftDelta('2s', rate), frames(60), reason: 'no sign means later');
      expect(SubtitlesPanelModel.shiftDelta(' - 1 s ', rate), -frames(30));
      expect(SubtitlesPanelModel.shiftDelta('−3f', rate), -frames(3), reason: 'a typographic minus');
      expect(SubtitlesPanelModel.shiftDelta('+0.01s', rate), 0);
      expect(SubtitlesPanelModel.shiftDelta('soon', rate), isNull);
      expect(SubtitlesPanelModel.shiftDelta('', rate), isNull);
      expect(SubtitlesPanelModel.shiftDelta('+2.5', rate), isNull);
      expect(SubtitlesPanelModel.formatDelta(frames(75)), '+2.50 s');
      expect(SubtitlesPanelModel.formatDelta(-frames(10)), '−0.33 s');
    });

    test('the cue under the playhead (binary search, [start, end))', () {
      final cues = [cue(Subs.a1, 1 * s, 3 * s, 'a'), cue(Subs.a2, 4 * s, 6 * s, 'b'), cue(Subs.a3, 6 * s, 7 * s, 'c')];
      expect(SubtitlesPanelModel.indexAt(cues, 0), isNull);
      expect(SubtitlesPanelModel.indexAt(cues, 1 * s), 0);
      expect(SubtitlesPanelModel.indexAt(cues, 3 * s - 1), 0);
      expect(SubtitlesPanelModel.indexAt(cues, 3 * s), isNull);
      expect(SubtitlesPanelModel.indexAt(cues, 6 * s), 2);
      expect(SubtitlesPanelModel.indexAt(cues, 7 * s), isNull);
      expect(SubtitlesPanelModel.indexAt(const [], 0), isNull);
      final many = [for (var i = 0; i < 3000; i++) cue(Subs.many(i), frames(45 * i), frames(45 * i + 30), '$i')];
      expect(SubtitlesPanelModel.indexAt(many, frames(45 * 2017 + 10)), 2017);
      expect(SubtitlesPanelModel.indexAt(many, frames(45 * 2017 + 40)), isNull);
    });

    test('the selected range needs two cues of the track', () {
      final project = subtitlesProject(const ProjectId('pr_m'));
      final a = project.tracks.firstWhere((t) => t.id == Subs.a);
      expect(SubtitlesPanelModel.selectedRange(a, EditorSelection(items: {Subs.a2}, primary: Subs.a2)), isNull);
      expect(SubtitlesPanelModel.selectedRange(a, EditorSelection(items: {Subs.a2, Subs.b1}, primary: Subs.a2)), isNull);
      final r = SubtitlesPanelModel.selectedRange(a, EditorSelection(items: {Subs.a3, Subs.a2}, primary: Subs.a2))!;
      expect(r, TimeRange(4 * s, 9 * s));
      expect(SubtitlesPanelModel.cuesIn(a, r), 2);
      expect(SubtitlesPanelModel.cuesIn(a, null), 4);
    });

    test('track names, tracks topmost first, the route\'s track', () {
      final project = subtitlesProject(const ProjectId('pr_n'));
      expect([for (final t in SubtitlesPanelModel.subtitleTracks(project)) t.id], [Subs.a, Subs.b, Subs.locked]);
      final a = project.tracks.firstWhere((t) => t.id == Subs.a);
      expect(SubtitlesPanelModel.nameOf(project, a), SubtitleStrings.laneName(3));
      expect(SubtitlesPanelModel.nameOf(project, project.tracks.firstWhere((t) => t.id == Subs.b)), 'English');
      expect(SubtitlesPanelModel.trackFor(project, const SubtitlesInspector(cue: Subs.b2))?.id, Subs.b);
      expect(SubtitlesPanelModel.trackFor(project, const SubtitlesInspector(track: Subs.main)), isNull, reason: 'not a subtitle lane');
      expect(SubtitlesPanelModel.textSplitOf('Hello', const TextSelection.collapsed(offset: 2)), 2);
      expect(SubtitlesPanelModel.textSplitOf('Hello', const TextSelection.collapsed(offset: 5)), isNull);
      expect(SubtitlesPanelModel.textSplitOf('Hello', const TextSelection(baseOffset: 1, extentOffset: 3)), isNull);
    });

    test('the action target: selected lane, the selected cue\'s lane, else the topmost lane', () {
      final project = subtitlesProject(const ProjectId('pr_t'));
      expect(captionTargetIn(project, EditorSelection.empty), Subs.a);
      expect(captionTargetIn(project, EditorSelection(lane: Subs.b)), Subs.b);
      expect(captionTargetIn(project, EditorSelection(items: {Subs.b2}, primary: Subs.b2, lane: Subs.b)), Subs.b);
      expect(captionTargetIn(project, EditorSelection(lane: Subs.main)), Subs.a, reason: 'not a subtitle lane');
      expect(captionTargetIn(subtitlesProject(const ProjectId('pr_e'), subtitles: false), EditorSelection.empty), isNull);
      expect(captionsRouteIn(project, EditorSelection(items: {Subs.b2}, primary: Subs.b2, lane: Subs.b)),
          const SubtitlesInspector(track: Subs.b, cue: Subs.b2));
      expect(captionsRouteIn(project, EditorSelection(lane: Subs.b), fromMenu: true),
          const SubtitlesInspector(track: Subs.b, section: SubtitlesPanelSection.style));
      expect(captionsRouteIn(project, EditorSelection(lane: Subs.b)), const SubtitlesInspector(track: Subs.b));
    });
  });

  test('captions and addCaption are bound exactly once by caption_bindings', () {
    final source = editorBindingSources.singleWhere((s) => s.file == 'caption_bindings');
    expect(source.owner, 'UX-31');
    expect(source.bindings().map((b) => b.id), [EditorActionId.captions, EditorActionId.addCaption]);
    expect(() => mergeEditorActionBindings(), returnsNormally);
    final merged = mergeEditorActionBindings();
    expect(merged[EditorActionId.captions], same(source.bindings().first));
    expect(merged[EditorActionId.addCaption], same(source.bindings().last));
    expect(identical(captionBindings, captionBindings), isTrue);
  });

  group('handlers', () {
    late SubtitlesRig rig;
    late EditorActionRegistry registry;

    Future<void> setUpRig(WidgetTester tester, {bool subtitles = true, TimeUs? playheadAt}) async {
      rig = await SubtitlesRig.pump(tester, open: null, subtitles: subtitles, playheadAt: playheadAt);
      registry = rig.container.read(editorActionRegistryProvider);
    }

    testWidgets('captions opens the panel on the topmost subtitle track', (tester) async {
      await setUpRig(tester);
      final ctx = rig.actionContext();
      expect(registry.spec(EditorActionId.captions).isEnabled(ctx), isTrue);
      expect(registry.invoke(EditorActionId.captions, ctx), EditorActionResult.ran);
      await tester.pump();
      expect(rig.state.inspector, const SubtitlesInspector(track: Subs.a));
      expect(find.byType(SubtitlesPanel), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('captions follows a selected cue; from the track menu (a button, lane only) it opens Style', (tester) async {
      await setUpRig(tester);
      rig.editor.select(Subs.b2);
      await tester.pump();
      registry.invoke(EditorActionId.captions, rig.actionContext());
      await tester.pump();
      expect(rig.state.inspector, const SubtitlesInspector(track: Subs.b, cue: Subs.b2));
      rig.editor
        ..closeInspector()
        ..selectAt(Subs.b, -1);
      await tester.pump();
      registry.invoke(EditorActionId.captions, rig.actionContext(source: EditorActionSource.button));
      await tester.pump();
      expect(rig.state.inspector, const SubtitlesInspector(track: Subs.b, section: SubtitlesPanelSection.style));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('captions without subtitle tracks opens the start state', (tester) async {
      await setUpRig(tester, subtitles: false);
      registry.invoke(EditorActionId.captions, rig.actionContext());
      await tester.pump();
      expect(rig.state.inspector, const SubtitlesInspector());
      expect(find.byKey(SubtitlesPanelKeys.start), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('addCaption: one AddCue at the playhead, selected, panel focused on it', (tester) async {
      await setUpRig(tester, playheadAt: 20 * s);
      final before = rig.entries;
      expect(registry.spec(EditorActionId.addCaption).isEnabled(rig.actionContext()), isTrue);
      registry.invoke(EditorActionId.addCaption, rig.actionContext());
      await tester.pump();
      final added = rig.cues(Subs.a).last;
      expect(added.start, 20 * s);
      expect(added.end, 22 * s);
      expect(added.text, SubtitleStrings.newCueText);
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, 'Add caption');
      expect(rig.state.selection.primary, added.id);
      expect(rig.state.inspector, SubtitlesInspector(track: Subs.a, cue: added.id));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('addCaption without subtitle tracks creates the track with the cue', (tester) async {
      await setUpRig(tester, subtitles: false, playheadAt: 3 * s);
      registry.invoke(EditorActionId.addCaption, rig.actionContext());
      await tester.pump();
      final lanes = rig.project.tracks.where((t) => t.kind == TrackKind.subtitle).toList();
      expect(lanes, hasLength(1));
      expect(lanes.single.items.single.start, 3 * s);
      expect(rig.state.inspector, isA<SubtitlesInspector>());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('addCaption on a selected locked lane goes to an unlocked one', (tester) async {
      await setUpRig(tester, playheadAt: 30 * s);
      rig.editor.selectAt(Subs.locked, -1);
      await tester.pump();
      registry.invoke(EditorActionId.addCaption, rig.actionContext());
      await tester.pump();
      expect(rig.track(Subs.locked).items, hasLength(1));
      expect(rig.cues(Subs.a).last.start, 30 * s);
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
