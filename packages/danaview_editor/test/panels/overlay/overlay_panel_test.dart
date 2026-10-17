// OWNER: UX-28
//
// The Overlay panel and the overlay actions (ux.md §10.13, ARCH §17.6) with the fake engine:
// adding video and photo overlays through the picker and the import sheet (topmost free overlay lane
// at the playhead or a new lane, 40 % centre-right, one entry, selected, Transform opens), the
// front-to-back list, z moves between overlay lanes (pure plan and the buttons / actions, one
// labelled entry, new lanes joined into it, reasons when disabled), the bindings, and the matrix.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/actions/bindings/media_bindings.dart' show pictureInPictureDefault;
import 'package:danaview_editor/src/editor/actions/bindings/overlay_bindings.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/panels/overlay_panel.dart';
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show SetTrackFlags;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show MediaPickKind, MediaPickSource;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../inspector/inspector_rig.dart' show RegionFrame;
import 'overlay_rig.dart';

EditProject _seed({bool overlays = true, bool crowded = false, Set<TrackId> lock = const {}}) =>
    overlayProject(FakeProjectRepository(), overlays: overlays, crowded: crowded, lock: lock);

Future<OverlayRig> _pumpPanel(WidgetTester tester, {EditProject Function(FakeProjectRepository)? project, ScriptedPool? pool, ItemId? select}) async {
  final rig = await OverlayRig.pump(tester, project: project, pool: pool);
  await rig.open(const OverlayInspector(), select: select);
  return rig;
}

Future<void> _settleImport(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

List<String> _rowTitles(WidgetTester tester) => [
      for (final tile in tester.widgetList<DanaviewListTile>(find.descendant(of: find.byType(OverlayPanel), matching: find.byType(DanaviewListTile))))
        tile.title,
    ];

void main() {
  group('OverlayZOrder (pure)', () {
    test('entries are front to back: top lane first', () {
      final p = _seed();
      expect([for (final e in OverlayZOrder.entries(p)) e.clip.id], [Ov.p3, Ov.p2, Ov.p1]);
      expect([for (final e in OverlayZOrder.entries(p)) e.laneName], ['Overlay 3', 'Overlay 2', 'Overlay 1']);
      expect(OverlayZOrder.entries(_seed(overlays: false)), isEmpty);
    });

    test('forward passes the nearest overlapping lane; with nothing overlapping it goes to the adjacent lane', () {
      final p = _seed();
      // P1 (1-4 s) is covered by P2 on O2 (2-5 s); O3 is free over 1-4 s.
      expect(OverlayZOrder.plan(p, Ov.p1, forward: true), const OverlayZMove(item: Ov.p1, forward: true, lane: Ov.o3));
      // P2 (2-5 s): nothing on O3 overlaps; the adjacent lane.
      expect(OverlayZOrder.plan(p, Ov.p2, forward: true), const OverlayZMove(item: Ov.p2, forward: true, lane: Ov.o3));
      // P3 is in front already.
      expect(OverlayZOrder.plan(p, Ov.p3, forward: true), isNull);
      expect(OverlayZOrder.blocker(p, Ov.p3, forward: true), 'This overlay is already in front');
    });

    test('a move with no free lane beyond the blocker makes a new lane (top or bottom)', () {
      final crowded = _seed(crowded: true);
      // P1 (1-4 s): O2 and O3 (3-7 s) both overlap.
      expect(OverlayZOrder.plan(crowded, Ov.p1, forward: true), const OverlayZMove(item: Ov.p1, forward: true));
      // P2 backward: P1 on O1 overlaps and nothing is below it.
      expect(OverlayZOrder.plan(_seed(), Ov.p2, forward: false), const OverlayZMove(item: Ov.p2, forward: false));
      expect(OverlayZOrder.plan(_seed(), Ov.p1, forward: false), isNull);
      expect(OverlayZOrder.blocker(_seed(), Ov.p1, forward: false), 'This overlay is already at the back');
    });

    test('locked lanes: the clip can not move, and locked targets are skipped', () {
      expect(OverlayZOrder.blocker(_seed(lock: {Ov.o1}), Ov.p1, forward: true), 'This track is locked');
      // P2 forward: O3 is the only lane above and it is locked.
      expect(OverlayZOrder.plan(_seed(lock: {Ov.o3}), Ov.p2, forward: true), isNull);
      expect(OverlayZOrder.blocker(_seed(lock: {Ov.o3}), Ov.p2, forward: true), 'The tracks in that direction are locked');
      // Not an overlay.
      expect(OverlayZOrder.blocker(_seed(), Ov.main, forward: true), 'Select an overlay first');
      expect(OverlayZOrder.blocker(_seed(), null, forward: true), 'Select an overlay first');
    });
  });

  group('add overlay', () {
    testWidgets('Add video overlay: video picker, import sheet, topmost free lane at the playhead, PiP, selected, Transform opens',
        (tester) async {
      final pool = ScriptedPool();
      final rig = await _pumpPanel(tester, pool: pool);
      await rig.media.seek(2 * s);
      rig.engine.picker.nextPicks = [pickOf('pip.mp4', size: 1000)];
      final before = rig.media.historyDepth;
      await rig.tapKey('overlay.addVideo');
      await _settleImport(tester);
      final request = rig.engine.picker.requests.single;
      expect(request.source, MediaPickSource.photos);
      expect(request.kinds, {MediaPickKind.video});
      expect(pool.imported, ['pip.mp4']);
      // 2-6 s: O1 and O2 are taken there, O3 (6-8 s) is free.
      final o3 = rig.overlayLanes.last;
      expect(o3.id, Ov.o3);
      final added = o3.items.firstWhere((i) => i.id != Ov.p3) as MediaClip;
      expect(added.range, const TimeRange(2 * s, 6 * s));
      expect(added.visual, pictureInPictureDefault);
      expect(rig.media.state.selection.primary, added.id);
      expect(rig.media.state.inspector, TransformInspector(added.id));
      expect(rig.media.historyDepth, before + 1, reason: 'one entry');
    });

    testWidgets('Add image overlay: photo picker; no free lane at the playhead makes a new top lane, one entry', (tester) async {
      final pool = ScriptedPool()..steps['logo.png'] = const AddStep(kind: MediaKind.image);
      final rig = await _pumpPanel(tester, pool: pool, project: (repo) => overlayProject(repo, crowded: true));
      await rig.media.seek(3 * s);
      rig.engine.picker.nextPicks = [pickOf('logo.png', size: 1000)];
      final before = rig.media.historyDepth;
      await rig.tapKey('overlay.addImage');
      await _settleImport(tester);
      expect(rig.engine.picker.requests.single.kinds, {MediaPickKind.image});
      expect(rig.overlayLanes, hasLength(4));
      final top = rig.overlayLanes.last;
      final added = top.items.single as MediaClip;
      expect(added.start, 3 * s);
      expect(added.visual!.transform, pictureInPictureDefault.transform);
      expect(rig.media.state.inspector, TransformInspector(added.id));
      expect(rig.media.historyDepth, before + 1, reason: 'the new lane and the clip are one entry');
      rig.media.editor.undo();
      await tester.pump();
      expect(rig.overlayLanes, hasLength(3));
    });

    testWidgets('a cancelled picker changes nothing', (tester) async {
      final rig = await _pumpPanel(tester);
      await rig.tapKey('overlay.addVideo');
      await _settleImport(tester);
      expect(rig.overlayLanes.expand((t) => t.items), hasLength(3));
      expect(rig.media.historyDepth, 0);
      expect(find.byType(OverlayPanel), findsOneWidget);
    });
  });

  group('list and selection', () {
    testWidgets('rows front to back; a row selects and moves the playhead into the overlay', (tester) async {
      final rig = await _pumpPanel(tester);
      expect(_rowTitles(tester), ['photo.jpg', 'clip.mp4', 'photo.jpg']);
      expect(find.text('Overlays · 3'), findsOneWidget);
      expect(find.text('Select an overlay in the list or on the timeline to order and edit it.'), findsOneWidget);
      await rig.tapKey('overlay.row.${Ov.p3}');
      expect(rig.media.state.selection.primary, Ov.p3);
      expect(rig.media.playhead.value, 6 * s);
      expect(find.byKey(const ValueKey<String>('overlay.forward')), findsOneWidget);
    });

    testWidgets('no overlays: the empty text', (tester) async {
      await _pumpPanel(tester, project: (repo) => overlayProject(repo, overlays: false));
      expect(find.text('No overlays yet. Add a video or photo to show it over the main video.'), findsOneWidget);
      expect(_rowTitles(tester), isEmpty);
    });

    testWidgets('tool buttons open the overlay\'s Transform, Crop, Chroma key and Mask panels', (tester) async {
      final rig = await _pumpPanel(tester, select: Ov.p1);
      for (final (key, route) in [
        ('overlay.transform', const TransformInspector(Ov.p1) as InspectorRoute),
        ('overlay.crop', const CropInspector(Ov.p1)),
        ('overlay.chroma', const ChromaInspector(Ov.p1)),
        ('overlay.mask', const MaskInspector(Ov.p1)),
      ]) {
        await rig.tapKey(key);
        expect(rig.media.state.inspector, route, reason: key);
        rig.media.editor.openInspector(const OverlayInspector());
        await tester.pump();
        await tester.pump();
      }
    });
  });

  group('z moves', () {
    testWidgets('Bring forward moves P1 past P2 to O3: one labelled entry, undoable', (tester) async {
      final rig = await _pumpPanel(tester, select: Ov.p1);
      await rig.tapKey('overlay.forward');
      expect(rig.laneOf(Ov.p1), Ov.o3);
      expect(rig.item(Ov.p1).range, const TimeRange(1 * s, 4 * s), reason: 'timing kept');
      expect(rig.undoLabel, 'Bring overlay forward');
      expect(rig.entries, 1);
      expect(rig.media.state.selection.primary, Ov.p1);
      rig.media.editor.undo();
      await tester.pump();
      expect(rig.laneOf(Ov.p1), Ov.o1);
    });

    testWidgets('Send backward with no free lane below makes a bottom lane, as one entry', (tester) async {
      final rig = await _pumpPanel(tester, select: Ov.p2);
      await rig.tapKey('overlay.backward');
      expect(rig.overlayLanes, hasLength(4));
      expect(rig.overlayLanes.first.items.single.id, Ov.p2, reason: 'the new lane is the bottom overlay lane');
      expect(rig.undoLabel, 'Send overlay backward');
      expect(rig.entries, 1);
      rig.media.editor.undo();
      await tester.pump();
      expect(rig.overlayLanes, hasLength(3));
      expect(rig.laneOf(Ov.p2), Ov.o2);
    });

    testWidgets('Bring forward with every lane above taken makes a top lane', (tester) async {
      final rig = await _pumpPanel(tester, select: Ov.p1, project: (repo) => overlayProject(repo, crowded: true));
      await rig.tapKey('overlay.forward');
      expect(rig.overlayLanes, hasLength(4));
      expect(rig.overlayLanes.last.items.single.id, Ov.p1);
      expect(rig.entries, 1);
    });

    testWidgets('front / back and locked overlays disable the buttons and say why', (tester) async {
      final rig = await _pumpPanel(tester, select: Ov.p3);
      expect(tester.widget<DanaviewButton>(find.byKey(const ValueKey<String>('overlay.forward'))).onPressed, isNull);
      expect(find.textContaining('This overlay is already in front'), findsOneWidget);
      rig.media.editor.apply(const SetTrackFlags(Ov.o3, locked: true));
      await tester.pump();
      await tester.pump();
      expect(tester.widget<DanaviewButton>(find.byKey(const ValueKey<String>('overlay.backward'))).onPressed, isNull);
      expect(tester.widget<DanaviewButton>(find.byKey(const ValueKey<String>('overlay.transform'))).onPressed, isNull);
      expect(find.textContaining('This track is locked'), findsOneWidget);
    });
  });

  group('bindings', () {
    late OverlayRig rig;
    late EditorActionRegistry registry;
    late WidgetActionContext ctx;

    Future<void> setUpRig(WidgetTester tester) async {
      rig = await OverlayRig.pump(tester);
      registry = rig.media.container.read(editorActionRegistryProvider);
      ctx = WidgetActionContext.container(
        projectId: rig.media.id,
        context: tester.element(find.byType(RegionFrame)),
        container: rig.media.container,
        source: EditorActionSource.toolTile,
      );
    }

    test('the four overlay ids are bound exactly once by the overlay file', () {
      final source = editorBindingSources.singleWhere((s) => s.file == 'overlay_bindings');
      expect(source.owner, 'UX-28');
      expect(source.bindings().map((b) => b.id),
          [EditorActionId.addOverlay, EditorActionId.chromaKey, EditorActionId.bringForward, EditorActionId.sendBackward]);
      expect(() => mergeEditorActionBindings(), returnsNormally);
      expect(identical(source.bindings(), source.bindings()), isTrue);
    });

    testWidgets('addOverlay opens the Overlay panel; chromaKey opens the Chroma key panel on a picture clip', (tester) async {
      await setUpRig(tester);
      expect(registry.invoke(EditorActionId.addOverlay, ctx), EditorActionResult.ran);
      await tester.pump();
      expect(rig.media.state.inspector, const OverlayInspector());
      expect(registry.spec(EditorActionId.chromaKey).isEnabled(ctx), isFalse);
      expect(registry.spec(EditorActionId.chromaKey).disabledReason(ctx), 'Select a video or photo clip first');
      rig.media.editor.select(Ov.p2);
      await tester.pump();
      expect(registry.invoke(EditorActionId.chromaKey, ctx), EditorActionResult.ran);
      await tester.pump();
      expect(rig.media.state.inspector, const ChromaInspector(Ov.p2));
      rig.media.editor.select(Ov.text);
      await tester.pump();
      expect(registry.spec(EditorActionId.chromaKey).isEnabled(ctx), isFalse);
    });

    testWidgets('bringForward / sendBackward follow the selection and say why when disabled', (tester) async {
      await setUpRig(tester);
      expect(registry.spec(EditorActionId.bringForward).disabledReason(ctx), 'Select an overlay first');
      rig.media.editor.select(Ov.main);
      await tester.pump();
      expect(registry.spec(EditorActionId.bringForward).isEnabled(ctx), isFalse);
      rig.media.editor.select(Ov.p1);
      await tester.pump();
      expect(registry.spec(EditorActionId.sendBackward).isEnabled(ctx), isFalse);
      expect(registry.spec(EditorActionId.sendBackward).disabledReason(ctx), 'This overlay is already at the back');
      expect(registry.invoke(EditorActionId.bringForward, ctx), EditorActionResult.ran);
      await tester.pump();
      expect(rig.laneOf(Ov.p1), Ov.o3);
      expect(registry.spec(EditorActionId.bringForward).disabledReason(ctx), 'This overlay is already in front');
      expect(registry.invoke(EditorActionId.sendBackward, ctx), EditorActionResult.ran);
      await tester.pump();
      expect(rig.laneOf(Ov.p1), Ov.o1, reason: "past P2 on O2, back to the free O1");
      expect(rig.entries, 2);
    });
  });

  group('matrix (ARCH §17.9)', () {
    testSurfaces('the overlay panel fits with and without a selection', (tester, surface) async {
      final rig = await OverlayRig.pump(tester, surface: surface);
      await rig.open(const OverlayInspector());
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      rig.media.editor.select(Ov.p2);
      await tester.pump();
      await tester.pump();
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });
  });
}
