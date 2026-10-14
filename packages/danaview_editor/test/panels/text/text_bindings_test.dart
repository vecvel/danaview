// OWNER: UX-30
//
// The text action binding (ARCH §17.6, ux.md §10.8): `addText` is bound once, adds "Your text" at
// the playhead (3 s) on the topmost free text lane (a new lane when every one is occupied), selects
// it and opens the text panel on Edit with the field focused; one history entry.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/text_strings.dart';
import 'package:danaview_editor/src/editor/actions/bindings/text_bindings.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/panels/text_panel.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_editor_core/model.dart';

import 'text_rig.dart';

void main() {
  tearDown(() {
    EditorAnnouncer.instance.reset();
    TextPanel.focusRequest.value = null;
  });

  test('addText is bound exactly once and no other id is bound by the text file', () {
    final source = editorBindingSources.singleWhere((s) => s.file == 'text_bindings');
    expect(source.owner, 'UX-30');
    expect(source.bindings().map((b) => b.id), [EditorActionId.addText]);
    expect(() => mergeEditorActionBindings(), returnsNormally);
    expect(mergeEditorActionBindings()[EditorActionId.addText], same(source.bindings().single));
    expect(identical(textBindings, textBindings), isTrue);
  });

  group('the handler', () {
    late TextRig rig;
    late EditorActionRegistry registry;
    late WidgetActionContext ctx;

    Future<void> setUpRig(WidgetTester tester) async {
      rig = await TextRig.pump(tester, open: null);
      registry = rig.container.read(editorActionRegistryProvider);
      ctx = WidgetActionContext.container(
        projectId: rig.id,
        context: tester.element(find.byType(RegionFrame)),
        container: rig.container,
        source: EditorActionSource.toolTile,
      );
    }

    Future<TextItem> add(WidgetTester tester) async {
      expect(registry.invoke(EditorActionId.addText, ctx), EditorActionResult.ran);
      await tester.pump();
      await tester.pump();
      await rig.settle();
      final id = rig.state.selection.primary!;
      return rig.text(id);
    }

    testWidgets('lands on the topmost free text lane, or a new one; panel opens focused', (tester) async {
      await setUpRig(tester);
      // 4.5 s: 4.5-7.5 s overlaps "Second" (6-8 s) on the text lane, and the locked lane is skipped.
      await rig.seek(4 * s + s ~/ 2);
      final lanes = rig.project.tracks.length;
      final before = rig.entries;
      final item = await add(tester);
      expect(item.text, TextStrings.newText);
      expect(item.start, 4 * s + s ~/ 2);
      expect(item.duration, 3 * s);
      expect(item.style, const TextStyleSpec());
      expect(rig.entries, before + 1);
      final lane = rig.project.index.locate(item.id)!.track;
      expect(lane.kind, TrackKind.text);
      expect(rig.project.tracks.length, lanes + 1, reason: 'no free unlocked text lane: a new one');
      expect(rig.state.inspector, TextInspector(item.id));
      expect(find.byType(TextPanel), findsOneWidget);
      final field = find.descendant(of: find.byKey(const ValueKey<String>('text.field')), matching: find.byType(EditableText));
      expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);
      await rig.closePanel();
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a free spot on the existing lane is used', (tester) async {
      await setUpRig(tester);
      await rig.seek(9 * s);
      final lanes = rig.project.tracks.length;
      final item = await add(tester);
      expect(rig.project.index.locate(item.id)!.track.id, Ids.text);
      expect(rig.project.tracks.length, lanes);
      await rig.closePanel();
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
