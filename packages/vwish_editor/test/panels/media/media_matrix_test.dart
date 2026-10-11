// OWNER: UX-36
//
// The surface matrix (ARCH §17.9) for the media panel and the drop ghost: no overflow from 280 to
// 1280 px wide, at text scale 1.35, with the keyboard up, with the preview strip, a missing badge,
// long names and a docked (short) panel; the owner UI rules hold (rounded buttons, Figtree only);
// every card action stays reachable by semantics.

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/strings/media_strings.dart';
import 'package:vwish_editor/src/editor/contracts/contracts.dart';
import 'package:vwish_editor/src/editor/panels/media_panel.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_drop_target.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_view.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';
import 'package:vwish_editor_core/store.dart' show MediaAvailability;

import '../../timeline/gestures/gesture_support.dart' show gestureProject;
import 'media_support.dart';

List<MediaAsset> _assets() => [
      binAsset('vid_a', name: 'A very long video name that keeps going and going.mp4', addedAt: DateTime.utc(2026, 10, 1)),
      binAsset('vid_b', name: 'city.mov', duration: 3725 * s, addedAt: DateTime.utc(2026, 10, 2)),
      binAsset('img_a', kind: MediaKind.image, name: 'logo.png', addedAt: DateTime.utc(2026, 10, 3)),
      binAsset('aud_a', kind: MediaKind.audio, name: 'song.m4a', duration: 30 * s, addedAt: DateTime.utc(2026, 10, 4)),
      binAsset('vid_p', name: 'processing.mp4', status: const PendingStatus('j'), addedAt: DateTime.utc(2026, 10, 5)),
      binAsset('vid_o', name: 'optimizing.mp4', proxy: ProxyState.pending, addedAt: DateTime.utc(2026, 10, 6)),
      binAsset('lut_a', kind: MediaKind.lut, name: 'teal and orange.cube', addedAt: DateTime.utc(2026, 10, 7)),
      for (var i = 0; i < 10; i++) binAsset('c$i', name: 'clip number $i.mp4', addedAt: DateTime.utc(2026, 9, 1 + i)),
    ];

EditProject _project(FakeProjectRepository repo) => seedMediaProject(
      repo,
      assets: _assets(),
      setup: (edit) => applyOrThrow(edit, InsertMedia([const MediaId('vid_a')], 0)),
    );

Widget _panel(Size size, {double? height}) => Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: size.width, height: height ?? size.height, child: const MediaPanel(route: MediaInspector())),
    );

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testSurfaces('the bin lists, filters, previews and shows badges without overflow', (tester, surface) async {
    final rig = await MediaRig.pump(tester, (_) => _panel(surface.size), project: _project, surface: surface);
    rig.harness.mediaPool.emitAvailability({const MediaId('vid_b'): MediaAvailability.missing});
    await tester.pump();
    await tester.pump();
    expectNoOverflow(tester);
    expectOwnerUiRules(tester);
    expect(find.byKey(const ValueKey('media-search')), findsOneWidget, reason: '17 items');
    // The preview strip with every action, then the info sheet.
    await _tap(tester, find.byKey(const ValueKey('media-card-vid_b')));
    expect(find.byKey(const ValueKey('media-preview')), findsOneWidget);
    expectNoOverflow(tester);
    expectOwnerUiRules(tester);
    await _tap(tester, find.byKey(const ValueKey('media-preview-info')));
    expect(find.byKey(const ValueKey('media-info-sheet')), findsOneWidget);
    expectNoOverflow(tester);
    expectOwnerUiRules(tester);
  });

  testSurfaces('a short docked panel scrolls instead of overflowing', (tester, surface) async {
    await MediaRig.pump(tester, (_) => _panel(surface.size, height: 180), project: _project, surface: surface);
    expectNoOverflow(tester);
    await _tap(tester, find.byKey(const ValueKey('media-filter-video')));
    expectNoOverflow(tester);
    await tester.drag(find.byKey(const ValueKey('media-panel')), const Offset(0, -400));
    await tester.pump();
    expectNoOverflow(tester);
    expectOwnerUiRules(tester);
  });

  testSurfaces('the card menu opens inside the screen', (tester, surface) async {
    await MediaRig.pump(tester, (_) => _panel(surface.size), project: _project, surface: surface);
    await _tap(tester, find.byKey(const ValueKey('media-menu-vid_a')));
    expectNoOverflow(tester);
    expectInside(tester, find.text(MediaStrings.addAtPlayhead));
    expectInside(tester, find.text(MediaStrings.remove));
    expectOwnerUiRules(tester);
  });

  testSurfaces('the empty bin and the no-match state fit', (tester, surface) async {
    await MediaRig.pump(
      tester,
      (_) => _panel(surface.size),
      project: (repo) => seedMediaProject(repo),
      surface: surface,
    );
    expectNoOverflow(tester);
    expect(find.byKey(const ValueKey('media-empty')), findsOneWidget);
    expectOwnerUiRules(tester);
  });

  testSurfaces('the drop ghost and its pills fit while a card is dragged over the timeline', (tester, surface) async {
    final rig = await MediaRig.pump(
      tester,
      (id) => Column(
        children: [
          SizedBox(
            height: 40,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Draggable<MediaDragData>(
                data: MediaDragData(project: id, media: const [MediaId('m_free')]),
                dragAnchorStrategy: pointerDragAnchorStrategy,
                hitTestBehavior: HitTestBehavior.opaque,
                feedback: const SizedBox(width: 40, height: 20),
                child: const SizedBox(key: ValueKey('drag-source'), width: 80, height: 40),
              ),
            ),
          ),
          const Expanded(child: TimelineDropTarget(child: TimelineView())),
        ],
      ),
      project: (repo) {
        final base = gestureProject();
        final project = base.copyWith(pool: base.pool.upsert(binAsset('m_free', duration: 3 * s)));
        repo.seed(project);
        return project;
      },
      surface: surface,
    );
    rig.editor.setModes((m) => m.copyWith(ripple: false));
    rig.viewport
      ..setPxPerSecond(40, anchorX: 0)
      ..jumpTo(scrollTimeSec: 0, scrollY: 0);
    await tester.pump();
    final drop = DropRig(rig);
    final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('drag-source'))),
        kind: surface.touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse);
    await g.moveBy(const Offset(30, 0));
    await g.moveBy(const Offset(30, 0));
    await tester.pump();
    await g.moveTo(drop.at(5 * s, 'tr_main'));
    await tester.pump();
    final state = tester.state<TimelineDropTargetState>(find.byType(TimelineDropTarget));
    expect(state.ghost, isNotNull);
    expectNoOverflow(tester);
    expectOwnerUiRules(tester);
    expectInside(tester, find.byKey(const ValueKey('drop-pill')));
    await g.up();
    await tester.pump();
    expectNoOverflow(tester);
  });
}
