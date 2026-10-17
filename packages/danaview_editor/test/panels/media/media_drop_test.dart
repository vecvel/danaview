// OWNER: UX-36
//
// TimelineDropTarget (ux.md §15.3, D-18) over the real TimelineView, EditorController and
// FakeEditorEngine: an in-app drag shows a drop ghost that is the dryRun of the command the drop
// commits (snapping, new lanes, ripple, lane kinds, refused lanes, auto-scroll), and external
// drops from engine.drops are imported through the import sheet (preflight, errors, cancel) and
// placed at the drop position.

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart' show isTestGroup;
import 'package:danaview_editor/src/app/strings/media_strings.dart';
import 'package:danaview_editor/src/editor/state/editor_events.dart' show EditorRejected, EditorToast;
import 'package:danaview_editor/src/editor/timeline/timeline_drop_target.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_view.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/store.dart' show ProjectHealth, LoadedProject;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show ExternalDrop;

import '../../timeline/gestures/gesture_support.dart' show gestureProject;
import '../../timeline/interaction/interaction_support.dart' show HapticRecorder;
import 'media_support.dart';

/// What the drag source carries; tests change it.
class _Holder extends ChangeNotifier {
  List<MediaId> _media = const [MediaId('m_free')];
  ProjectId? _project;

  List<MediaId> get media => _media;

  set media(List<MediaId> value) {
    _media = value;
    notifyListeners();
  }

  ProjectId? get project => _project;

  set project(ProjectId? value) {
    _project = value;
    notifyListeners();
  }
}

class _Host extends StatelessWidget {
  const _Host({required this.id, required this.holder});

  final ProjectId id;
  final _Holder holder;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          SizedBox(
            height: 40,
            child: Align(
              alignment: Alignment.centerLeft,
              child: ListenableBuilder(
                listenable: holder,
                builder: (context, _) => Draggable<MediaDragData>(
                  data: MediaDragData(project: holder.project ?? id, media: holder.media, label: 'drag me'),
                  dragAnchorStrategy: pointerDragAnchorStrategy,
                  hitTestBehavior: HitTestBehavior.opaque,
                  feedback: const SizedBox(width: 40, height: 20),
                  child: const SizedBox(key: ValueKey('drag-source'), width: 80, height: 40),
                ),
              ),
            ),
          ),
          const Expanded(child: TimelineDropTarget(child: TimelineView())),
        ],
      );
}

/// [gestureProject] with free media in the pool: a 3 s video, an 8 s song and a photo.
EditProject _project(FakeProjectRepository repo) {
  final base = gestureProject();
  final pool = base.pool
      .upsert(binAsset('m_free', duration: 3 * s, name: 'free.mp4'))
      .upsert(binAsset('m_free_aud', kind: MediaKind.audio, duration: 8 * s, name: 'free.m4a'))
      .upsert(binAsset('m_free_img', kind: MediaKind.image, name: 'free.jpg'));
  final project = base.copyWith(pool: pool);
  repo.seed(project);
  return project;
}

class _Pumped {
  _Pumped(this.rig, this.drop, this.holder);

  final MediaRig rig;
  final DropRig drop;
  final _Holder holder;

  WidgetTester get tester => rig.tester;

  TimelineDropTargetState get target => tester.state<TimelineDropTargetState>(find.byType(TimelineDropTarget));

  /// Drags [media] (of [project], default this one) from the next frame on.
  Future<void> use(List<MediaId> media, {ProjectId? project}) async {
    holder
      ..media = media
      ..project = project;
    await tester.pump();
  }

  /// The drop ghost of the drag in progress.
  DropGhost? get ghost => target.ghost;

  /// Starts dragging the source card and moves to [to] (a few steps so the drag starts).
  Future<TestGesture> dragTo(Offset to, {PointerDeviceKind kind = PointerDeviceKind.touch}) async {
    final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('drag-source'))), kind: kind);
    await g.moveBy(const Offset(30, 0));
    await g.moveBy(const Offset(30, 0));
    await tester.pump();
    await g.moveTo(to);
    await tester.pump();
    return g;
  }

  /// The clips of lane [lane] as ranges.
  List<TimeRange> lane(String lane) =>
      [for (final i in rig.project.timeline.tracks.firstWhere((t) => t.id == TrackId(lane)).items) i.range];
}

Future<_Pumped> _pump(
  WidgetTester tester, {
  Size size = const Size(1000, 420),
  TargetPlatform platform = TargetPlatform.android,
  bool ripple = false,
  ScriptedPool? pool,
  EditProject Function(FakeProjectRepository repo)? project,
  List<Override> overrides = const [],
}) async {
  final holder = _Holder();
  final rig = await MediaRig.pump(
    tester,
    (id) => _Host(id: id, holder: holder),
    project: project ?? _project,
    surface: EditorSurface(size, platform: platform),
    pool: pool,
    overrides: overrides,
  );
  rig.editor.setModes((m) => m.copyWith(ripple: ripple));
  rig.viewport
    ..setPxPerSecond(60, anchorX: 0)
    ..jumpTo(scrollTimeSec: 0, scrollY: 0);
  await tester.pump();
  return _Pumped(rig, DropRig(rig), holder);
}

/// Shape of placements for comparing a ghost with the result: range and lane (null for new lanes).
List<(TimeRange, Object?)> _shape(Iterable<Placement> placements) =>
    [for (final p in placements) (p.range, p.onNewTrack ? p.newTrack!.kind : p.track)]..sort((a, b) => a.$1.start.compareTo(b.$1.start));

/// A widget test that lets toasts and the announcer's one-per-second gate expire before it ends
/// (no timer may stay pending).
@isTestGroup
void _test(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 4));
    });

void main() {
  group('in-app drag', () {
    _test('the ghost is the dryRun of the drop and the drop lands exactly there', (tester) async {
      final t = await _pump(tester);
      final g = await t.dragTo(t.drop.at(15 * s, 'tr_main'));
      final ghost = t.ghost!;
      expect(ghost.valid, isTrue);
      expect(ghost.start, 15 * s);
      expect(ghost.placements.values.single.range, const TimeRange(15 * s, 18 * s));
      expect(ghost.placements.values.single.track, const TrackId('tr_main'));
      expect(find.byKey(const ValueKey('drop-pill')), findsOneWidget);
      expect(find.text(MediaStrings.dropStart('00:15:00')), findsOneWidget);
      final expected = _shape(ghost.placements.values);
      final depth = t.rig.historyDepth;
      await g.up();
      await tester.pump();
      expect(t.ghost, isNull, reason: 'the ghost is gone after the drop');
      expect(t.lane('tr_main').last, const TimeRange(15 * s, 18 * s));
      expect(
          _shape([
            for (final i in t.rig.project.timeline.tracks
                .firstWhere((tr) => tr.id == const TrackId('tr_main'))
                .items
                .where((i) => i.start == 15 * s))
              Placement(const TrackId('tr_main'), i.range)
          ]),
          expected);
      expect(t.rig.historyDepth, depth + 1, reason: 'one history entry');
      expect(t.rig.undoLabel, 'Add clip');
      expect(t.rig.state.selection.items, hasLength(1));
    });

    _test('over an occupied main lane without ripple the ghost is a lane the drop creates, and so is the result', (tester) async {
      final t = await _pump(tester);
      final g = await t.dragTo(t.drop.at(5 * s, 'tr_main'));
      final ghost = t.ghost!;
      expect(ghost.createsTrack, isTrue);
      expect(find.byKey(const ValueKey('drop-new-track-pill')), findsOneWidget);
      final expected = _shape(ghost.placements.values);
      final lanes = t.rig.project.timeline.tracks.length;
      await g.up();
      await tester.pump();
      expect(t.rig.project.timeline.tracks.length, lanes + 1);
      final made =
          t.rig.project.timeline.tracks.where((tr) => tr.items.any((i) => i is MediaClip && i.media == const MediaId('m_free'))).toList();
      expect(made, hasLength(1));
      expect(made.single.items.single.range, expected.single.$1);
      expect(made.single.kind, expected.single.$2);
      expect(t.rig.historyDepth, 1);
    });

    _test('with ripple on, a drop on the main lane at a cut inserts there and the later clips move right', (tester) async {
      final t = await _pump(tester, ripple: true);
      final g = await t.dragTo(t.drop.at(4 * s, 'tr_main') + const Offset(2, 0));
      final ghost = t.ghost!;
      expect(ghost.valid, isTrue);
      expect(ghost.placements.values.single.range, const TimeRange(4 * s, 7 * s), reason: 'ripple inserts at the cut');
      expect(ghost.shifted.values.map((p) => p.range), unorderedEquals([const TimeRange(7 * s, 11 * s), const TimeRange(13 * s, 17 * s)]),
          reason: 'the later clips are drawn where they go');
      await g.up();
      await tester.pump();
      expect(t.lane('tr_main').take(3), [const TimeRange(0, 4 * s), const TimeRange(4 * s, 7 * s), const TimeRange(7 * s, 11 * s)]);
    });

    _test('audio over the music lane keeps its length on that lane', (tester) async {
      final t = await _pump(tester);
      await t.use(const [MediaId('m_free_aud')]);
      final g = await t.dragTo(t.drop.at(12 * s, 'tr_music'));
      final ghost = t.ghost!;
      expect(ghost.placements.values.single.track, const TrackId('tr_music'));
      expect(ghost.placements.values.single.range, const TimeRange(12 * s, 20 * s));
      await g.up();
      await tester.pump();
      expect(t.lane('tr_music').last, const TimeRange(12 * s, 20 * s));
    });

    _test('a photo over the overlay lane keeps the image length', (tester) async {
      final t = await _pump(tester);
      await t.use(const [MediaId('m_free_img')]);
      final g = await t.dragTo(t.drop.at(6 * s, 'tr_ov'));
      expect(t.ghost!.placements.values.single.track, const TrackId('tr_ov'));
      expect(t.ghost!.placements.values.single.range, const TimeRange(6 * s, 9 * s));
      await g.up();
      await tester.pump();
      expect(t.lane('tr_ov').last, const TimeRange(6 * s, 9 * s));
    });

    _test('audio dropped over a video lane goes to its audio lane; video over audio goes to the main lane', (tester) async {
      final t = await _pump(tester);
      await t.use(const [MediaId('m_free_aud')]);
      var g = await t.dragTo(t.drop.at(12 * s, 'tr_main'));
      expect(t.ghost!.lane, isNull, reason: 'a video lane does not take audio');
      expect(t.ghost!.placements.values.single.track, const TrackId('tr_music'));
      await g.up();
      await tester.pump();
      await t.use(const [MediaId('m_free')]);
      g = await t.dragTo(t.drop.at(15 * s, 'tr_music'));
      expect(t.ghost!.placements.values.single.track, const TrackId('tr_main'));
      await g.up();
      await tester.pump();
      expect(t.lane('tr_main').last, const TimeRange(15 * s, 18 * s));
    });

    _test('a video and a song dragged together land together as one entry', (tester) async {
      final t = await _pump(tester);
      await t.use(const [MediaId('m_free'), MediaId('m_free_aud')]);
      final g = await t.dragTo(t.drop.at(15 * s, 'tr_main'));
      final ghost = t.ghost!;
      expect(ghost.command, isA<CompositeCommand>());
      expect(ghost.placements, hasLength(2));
      final depth = t.rig.historyDepth;
      await g.up();
      await tester.pump();
      expect(t.lane('tr_main').last, const TimeRange(15 * s, 18 * s));
      expect(t.lane('tr_music').last, const TimeRange(15 * s, 23 * s));
      expect(t.rig.historyDepth, depth + 1);
    });

    _test('the start snaps to a clip edge within 12 px on touch with a haptic and a guide; snapping off does not', (tester) async {
      final haptics = HapticRecorder.install(tester);
      final t = await _pump(tester);
      final g = await t.dragTo(t.drop.at(14 * s, 'tr_main') + const Offset(6, 0));
      expect(t.ghost!.start, 14 * s, reason: '6 px right of it_c end snaps to it');
      expect(t.ghost!.guide?.time, 14 * s);
      expect(find.byKey(const ValueKey('drop-snap-pill')), findsOneWidget);
      expect(haptics.selectionClicks, 1);
      await g.moveTo(t.drop.at(15 * s, 'tr_main'));
      await tester.pump();
      expect(t.ghost!.guide, isNull);
      expect(t.ghost!.start, 15 * s);
      await g.up();
      await tester.pump();

      final off = await _pump(tester);
      off.rig.editor.setModes((m) => m.copyWith(snapping: false));
      final g2 = await off.dragTo(off.drop.at(14 * s, 'tr_main') + const Offset(6, 0));
      expect(off.ghost!.guide, isNull);
      expect(off.ghost!.start, isNot(14 * s));
      expect(off.ghost!.start, closeTo(14 * s + 0.1 * s, 0.05 * s));
      await g2.up();
      await tester.pump();
    });

    _test('a pointer snaps within 8 px only', (tester) async {
      final t = await _pump(tester, platform: TargetPlatform.macOS);
      final g = await t.dragTo(t.drop.at(14 * s, 'tr_main') + const Offset(10, 0), kind: PointerDeviceKind.mouse);
      expect(t.ghost!.guide, isNull, reason: '10 px is out of reach for a pointer');
      await g.moveTo(t.drop.at(14 * s, 'tr_main') + const Offset(6, 0));
      await tester.pump();
      expect(t.ghost!.start, 14 * s);
      await g.up();
      await tester.pump();
    });

    _test('a locked lane shows a red ghost and a refused drop explains and records nothing', (tester) async {
      final t = await _pump(tester);
      final g = await t.dragTo(t.drop.at(8 * s, 'tr_lock'));
      expect(t.ghost!.valid, isFalse);
      expect(t.ghost!.rejection, isA<TrackLocked>());
      expect(find.text(MediaStrings.dropRefused), findsOneWidget);
      final depth = t.rig.historyDepth;
      await g.up();
      await tester.pump();
      expect(t.rig.historyDepth, depth);
      expect(t.rig.eventsOf<EditorRejected>(), hasLength(1));
      expect(t.rig.eventsOf<EditorToast>(), isNotEmpty);
      await tester.pump(const Duration(seconds: 4));
    });

    _test('leaving the timeline, or dropping elsewhere, clears the ghost and changes nothing', (tester) async {
      final t = await _pump(tester);
      final depth = t.rig.historyDepth;
      final g = await t.dragTo(t.drop.at(15 * s, 'tr_main'));
      expect(t.ghost, isNotNull);
      expect(t.target.isDragging, isTrue);
      await g.moveTo(tester.getCenter(find.byKey(const ValueKey('drag-source'))));
      await tester.pump();
      expect(t.ghost, isNull);
      expect(t.target.isDragging, isFalse);
      await g.up();
      await tester.pump();
      expect(t.rig.historyDepth, depth);
    });

    _test('a drag from another project is not accepted', (tester) async {
      final t = await _pump(tester);
      await t.use(const [MediaId('m_free')], project: const ProjectId('other'));
      final depth = t.rig.historyDepth;
      final g = await t.dragTo(t.drop.at(15 * s, 'tr_main'));
      expect(t.ghost, isNull);
      await g.up();
      await tester.pump();
      expect(t.rig.historyDepth, depth);
    });

    _test('over the ruler the default lane is used; over the headers the time clamps to the left edge', (tester) async {
      final t = await _pump(tester);
      var g = await t.dragTo(t.drop.ruler(15 * s));
      expect(t.ghost!.lane, isNull);
      expect(t.ghost!.start, 15 * s);
      await g.up();
      await tester.pump();
      final c = t.drop.canvas();
      t.rig.viewport.jumpTo(scrollTimeSec: 3);
      await tester.pump();
      g = await t.dragTo(c.localToGlobal(const Offset(-20, 40)));
      expect(t.ghost!.start, 3 * s, reason: 'left of the lanes is the first visible time');
      await g.up();
      await tester.pump();
    });

    _test('near the edge the timeline scrolls and the ghost follows the pointer time', (tester) async {
      final t = await _pump(tester);
      t.rig.viewport.setPxPerSecond(200, anchorX: 0);
      await tester.pump();
      final g = await t.dragTo(t.drop.at(3 * s, 'tr_main'));
      final before = t.rig.viewport.scrollTimeSec;
      final c = t.drop.canvas();
      await g.moveTo(c.localToGlobal(Offset(t.rig.viewport.lanesWidth - 6, 20)));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(t.rig.viewport.scrollTimeSec, greaterThan(before));
      final start = t.ghost!.start;
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(t.ghost!.start, greaterThan(start), reason: 'the ghost keeps up with the scroll');
      await g.moveTo(t.drop.at(3 * s, 'tr_main'));
      await tester.pump();
      final settled = t.rig.viewport.scrollTimeSec;
      await tester.pump(const Duration(milliseconds: 200));
      expect(t.rig.viewport.scrollTimeSec, settled, reason: 'leaving the edge stops the scroll');
      await g.up();
      await tester.pump();
    });
  });

  group('external drops', () {
    _test('drops are enabled while the timeline is mounted and disabled after', (tester) async {
      final t = await _pump(tester);
      expect(t.rig.engine.drops.enabled, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(t.rig.engine.drops.enabled, isFalse);
    });

    _test('drops are paused while an opaque route covers the editor and resume when it is visible again', (tester) async {
      final t = await _pump(tester);
      expect(t.rig.engine.drops.enabled, isTrue);
      final context = tester.element(find.byType(TimelineDropTarget));
      final navigator = Navigator.of(context);
      unawaited(navigator.push(PageRouteBuilder<void>(opaque: true, pageBuilder: (_, __, ___) => const SizedBox.expand())));
      await tester.pumpAndSettle();
      expect(t.rig.engine.drops.enabled, isFalse, reason: 'a full-screen route covers the editor');
      navigator.pop();
      await tester.pumpAndSettle();
      expect(t.rig.engine.drops.enabled, isTrue);
    });

    _test('a drop is imported through the sheet and placed at the drop position and lane', (tester) async {
      final pool = ScriptedPool();
      final t = await _pump(tester, pool: pool);
      t.rig.engine.drops.simulateDrop(
          ExternalDrop(items: [pickOf('dropped.mp4', origin: MediaOrigin.drop, size: 1000)], position: t.drop.at(15 * s, 'tr_main')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(pool.imported, ['dropped.mp4']);
      expect(t.rig.project.pool.assets.values.any((a) => a.displayName == 'dropped.mp4'), isTrue);
      expect(t.lane('tr_main').last, const TimeRange(15 * s, 19 * s), reason: 'the dropped video is 4 s');
      expect(find.text(MediaStrings.dropTitle), findsNothing, reason: 'the sheet closes by itself');
      expect(t.rig.historyDepth, 1);
      // A second drop over the overlay lane goes there.
      t.rig.engine.drops.simulateDrop(
          ExternalDrop(items: [pickOf('second.mp4', origin: MediaOrigin.drop, size: 1000)], position: t.drop.at(8 * s, 'tr_ov')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(t.lane('tr_ov').last, const TimeRange(8 * s, 12 * s));
      expect(t.rig.historyDepth, 2);
    });

    _test('a drop outside the lanes goes to the playhead', (tester) async {
      final pool = ScriptedPool();
      final t = await _pump(tester, pool: pool);
      await t.rig.seek(14 * s); // the end of the project
      t.rig.engine.drops
          .simulateDrop(ExternalDrop(items: [pickOf('out.mp4', origin: MediaOrigin.drop, size: 1000)], position: const Offset(5, 5)));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(t.lane('tr_main').last, const TimeRange(14 * s, 18 * s));
    });

    _test('a rejected file shows the reason in the sheet and nothing is placed', (tester) async {
      final pool = ScriptedPool()..steps['bad.mkv'] = const RejectStep('containerUnsupportedIos');
      final t = await _pump(tester, pool: pool);
      final depth = t.rig.historyDepth;
      final poolSize = t.rig.project.pool.length;
      t.rig.engine.drops.simulateDrop(
          ExternalDrop(items: [pickOf('bad.mkv', origin: MediaOrigin.drop, size: 1000)], position: t.drop.at(15 * s, 'tr_main')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text(MediaStrings.dropTitle), findsOneWidget);
      expect(find.textContaining("can't be edited"), findsOneWidget);
      expect(t.rig.historyDepth, depth);
      expect(t.rig.project.pool.length, poolSize);
    });

    _test('not enough free space refuses before anything is copied', (tester) async {
      final pool = ScriptedPool();
      final t = await _pump(tester, pool: pool);
      t.rig.engine.freeBytesValue = 1024 * 1024;
      t.rig.engine.drops.simulateDrop(ExternalDrop(
          items: [pickOf('huge.mp4', origin: MediaOrigin.drop, size: 900 * 1024 * 1024)], position: t.drop.at(15 * s, 'tr_main')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Not enough space'), findsOneWidget);
      expect(pool.imported, isEmpty);
      expect(t.rig.historyDepth, 0);
    });

    _test('cancelling keeps what was added before and places it', (tester) async {
      final pool = ScriptedPool();
      final slow = CopyStep();
      pool.steps['slow.mp4'] = slow;
      final t = await _pump(tester, pool: pool);
      t.rig.engine.drops.simulateDrop(ExternalDrop(
        items: [pickOf('fast.mp4', origin: MediaOrigin.drop, size: 1000), pickOf('slow.mp4', origin: MediaOrigin.drop, size: 1000)],
        position: t.drop.at(15 * s, 'tr_main'),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() => slow.started.future);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('import-cancel')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(t.lane('tr_main').last, const TimeRange(15 * s, 19 * s), reason: 'fast.mp4 was complete and is placed');
      expect(t.lane('tr_main').where((r) => r.start >= 15 * s), hasLength(1), reason: 'slow.mp4 was cancelled');
      expect(t.rig.project.pool.assets.values.any((a) => a.displayName == 'slow.mp4'), isFalse);
      await tester.tap(find.byKey(const ValueKey('import-finish')));
      await tester.pumpAndSettle();
    });

    _test('a drop on a read-only project says so and opens no sheet', (tester) async {
      final pool = ScriptedPool();
      final t = await _pump(tester, pool: pool, project: (repo) {
        final p = _project(repo);
        repo.openResults[p.id] = (project) => LoadedProject(project: project, health: ProjectHealth.readOnlyNewer);
        return p;
      });
      t.rig.engine.drops
          .simulateDrop(ExternalDrop(items: [pickOf('x.mp4', origin: MediaOrigin.drop)], position: t.drop.at(15 * s, 'tr_main')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      expect(find.text(MediaStrings.dropNotEditable), findsOneWidget);
      expect(pool.imported, isEmpty);
      await tester.pump(const Duration(seconds: 4));
    });

    _test('two drops in a row are handled one after the other', (tester) async {
      final pool = ScriptedPool();
      final t = await _pump(tester, pool: pool);
      t.rig.engine.drops
        ..simulateDrop(
            ExternalDrop(items: [pickOf('one.mp4', origin: MediaOrigin.drop, size: 1000)], position: t.drop.at(14 * s + s ~/ 2, 'tr_main')))
        ..simulateDrop(ExternalDrop(
            items: [pickOf('two.mp4', origin: MediaOrigin.drop, size: 1000)], position: t.drop.at(15 * s + s ~/ 2, 'tr_main')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pumpAndSettle();
      expect(pool.imported, ['one.mp4', 'two.mp4']);
      final starts = [
        for (final track in t.rig.project.timeline.tracks)
          for (final item in track.items)
            if (item.start >= 14 * s) item.start,
      ]..sort();
      expect(starts, [14 * s + s ~/ 2, 15 * s + s ~/ 2], reason: 'the second landed on another lane because the first is there');
    });
  });
}
