// OWNER: CORE-17
//
// Marker commands and project-setting commands (BUILD_PLAN CORE-17): goldens and round trips.
// SetFrameRate is covered in requantize_test.dart. Regenerate with
// `UPDATE_GOLDENS=1 dart test test/ops/tracks` and review the diff.

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../framework/ops_support.dart';
import 'track_fixtures.dart';

MarkerId m(String s) => MarkerId(s);

final List<Case> markerCases = [
  ('add in the middle keeps the list sorted', lanes, AddMarker(f(60), name: 'Middle', colorIndex: 3)),
  ('add before every marker', lanes, AddMarker(f(0))),
  ('add after every marker', lanes, AddMarker(f(300), note: 'Fin')),
  ('add at the time of another marker keeps both, in order', lanes, AddMarker(f(90), name: 'Twin')),
  ('time is quantized to the nearest frame', lanes, AddMarker(f(60) + 12000)),
  ('name and note are trimmed; a blank note is none', lanes, AddMarker(f(60), name: '  Chorus  ', note: '   ')),
  ('add to an empty project', () => project([laneOf('v', TrackKind.video, const [], main: true)]), AddMarker(f(15), name: 'First')),
  ('negative time', lanes, const AddMarker(-1)),
  ('beyond 24 hours', lanes, const AddMarker(maxProjectDurationUs + 1)),
  ('colour out of the palette', lanes, AddMarker(f(60), colorIndex: 6)),
  ('negative colour', lanes, AddMarker(f(60), colorIndex: -1)),
  ('name too long', lanes, AddMarker(f(60), name: 'n' * 61)),
  ('note too long', lanes, AddMarker(f(60), note: 'n' * 1001)),
  ('rename', lanes, UpdateMarker(m('mk1'), name: 'Opening')),
  ('recolour', lanes, UpdateMarker(m('mk2'), colorIndex: 4)),
  ('set a note', lanes, UpdateMarker(m('mk2'), note: 'Check audio')),
  ('clear a note', lanes, UpdateMarker(m('mk1'), note: null)),
  ('a blank note clears it', lanes, UpdateMarker(m('mk1'), note: '  ')),
  ('move past the next marker re-sorts', lanes, UpdateMarker(m('mk1'), time: f(120))),
  ('move to the start', lanes, UpdateMarker(m('mk3'), time: 0)),
  ('move is quantized', lanes, UpdateMarker(m('mk2'), time: f(100) + 9000)),
  ('several fields at once', lanes, UpdateMarker(m('mk2'), time: f(45), name: 'Beat', colorIndex: 1, note: 'drop')),
  ('nothing changes: no-op', lanes, UpdateMarker(m('mk1'))),
  ('same values: no-op', lanes, UpdateMarker(m('mk1'), time: f(30), name: 'Intro', colorIndex: 2, note: 'Start here')),
  ('missing marker', lanes, UpdateMarker(m('nope'), name: 'x')),
  ('update with a negative time', lanes, UpdateMarker(m('mk1'), time: -f(1))),
  ('update with a bad colour', lanes, UpdateMarker(m('mk1'), colorIndex: 9)),
  ('update with a long name', lanes, UpdateMarker(m('mk1'), name: 'n' * 61)),
  ('update with a note that is not text', lanes, UpdateMarker(m('mk1'), note: 5)),
  ('delete', lanes, DeleteMarker(m('mk2'))),
  ('delete missing', lanes, DeleteMarker(m('nope'))),
];

final List<Case> projectCases = [
  ('canvas: aspect only', lanes, SetCanvas(aspect: AspectRatio.portrait9x16)),
  ('canvas: base short side only', lanes, const SetCanvas(baseShortSide: 2160)),
  ('canvas: both', lanes, SetCanvas(aspect: AspectRatio.square, baseShortSide: 720)),
  ('canvas: 4:5', lanes, SetCanvas(aspect: AspectRatio.portrait4x5)),
  ('canvas: custom ratio inside 1:4 .. 4:1', lanes, const SetCanvas(aspect: AspectRatio(239, 100))),
  ('canvas: same canvas is a no-op', lanes, SetCanvas(aspect: AspectRatio.landscape16x9, baseShortSide: 1080)),
  ('canvas: nothing given is a no-op', lanes, const SetCanvas()),
  ('canvas: ratio too wide', lanes, const SetCanvas(aspect: AspectRatio(5, 1))),
  ('canvas: ratio too tall', lanes, const SetCanvas(aspect: AspectRatio(1, 5))),
  ('canvas: unsupported short side', lanes, const SetCanvas(baseShortSide: 1000)),
  ('canvas: zero short side', lanes, const SetCanvas(baseShortSide: 0)),
  ('background: solid', lanes, const SetBackground(SolidBackground(0xFF336699))),
  ('background: the alpha is ignored (made opaque)', lanes, const SetBackground(SolidBackground(0x00336699))),
  ('background: blur of the main lane', lanes, const SetBackground(BlurOfMainBackground(0.6))),
  ('background: same is a no-op', lanes, const SetBackground(SolidBackground(0xFF000000))),
  ('background: blur 0 and 1 are fine', lanes, const SetBackground(BlurOfMainBackground(1))),
  ('background: blur above 1', lanes, const SetBackground(BlurOfMainBackground(1.1))),
  ('background: blur below 0', lanes, const SetBackground(BlurOfMainBackground(-0.1))),
  ('background: blur NaN', lanes, SetBackground(BlurOfMainBackground(double.nan))),
];

void main() {
  final golden = GoldenFile('test/ops/tracks/goldens/markers_project.golden');
  tearDownAll(golden.save);

  group('markers', () => goldenCases(golden, 'marker', markerCases));
  group('project settings', () => goldenCases(golden, 'project', projectCases));

  group('marker details', () {
    test('add / update / delete round trip back to the original markers', () {
      final p = lanes();
      final added = applyCommand(p, AddMarker(f(60), name: 'Temp'), ctx());
      final id = added.project.markers.firstWhere((x) => x.name == 'Temp').id;
      expect(added.project.markers.map((x) => x.time), [f(30), f(60), f(90), f(150)]);
      final moved = applyCommand(added.project, UpdateMarker(id, time: f(200), colorIndex: 4, note: 'x'), ctx());
      expect(moved.project.markers.last.id, id);
      final gone = applyCommand(moved.project, DeleteMarker(id), ctx());
      expect(gone.project.markers, p.markers);
    });

    test('markers touch no lane and no item', () {
      final p = lanes();
      for (final c in <EditCommand>[AddMarker(f(60)), UpdateMarker(m('mk1'), time: f(70)), DeleteMarker(m('mk1'))]) {
        final out = applyCommand(p, c, ctx());
        expect(out.changedTracks, isEmpty, reason: '$c');
        expect(out.affected, isEmpty);
        expect(out.project.tracks, p.tracks);
      }
    });

    test('marker ids are fresh and the validator is happy with 200 random operations', () {
      var p = lanes();
      var step = 0;
      for (var i = 0; i < 200; i++) {
        final marks = p.markers;
        final EditCommand c;
        switch (i % 4) {
          case 0:
            c = AddMarker(f((i * 13) % 400) + (i % 7) * 1000, name: 'm$i', colorIndex: i % 6);
          case 1:
            c = marks.isEmpty ? AddMarker(f(1)) : UpdateMarker(marks[i % marks.length].id, time: f((i * 29) % 400));
          case 2:
            c = marks.isEmpty ? AddMarker(f(2)) : UpdateMarker(marks[i % marks.length].id, name: 'r$i', note: i.isEven ? null : 'n$i');
          default:
            c = marks.length < 4 ? AddMarker(f(3)) : DeleteMarker(marks[i % marks.length].id);
        }
        final out = applyCommand(p, c, ctx(seed: 900 + i));
        if (out.rejection != null || out.noop) continue;
        p = out.project;
        step++;
        expectValid(p, 'step $i');
      }
      expect(step, greaterThan(100));
      expect({for (final x in p.markers) x.id}.length, p.markers.length);
    });
  });

  group('project settings details', () {
    test('SetCanvas never touches items, lanes, markers or the pool', () {
      final p = lanes();
      final out = applyCommand(p, SetCanvas(aspect: AspectRatio.portrait9x16, baseShortSide: 720), ctx());
      expect(out.project.tracks, p.tracks);
      expect(out.project.markers, p.markers);
      expect(out.project.pool, p.pool);
      expect(out.changedTracks, isEmpty);
      expect(out.project.settings.canvas.widthPx, 720);
      expect(out.project.settings.canvas.heightPx, 1280);
      expect(out.project.settings.frameRate, p.settings.frameRate);
    });

    test('every supported short side and standard aspect gives a valid canvas', () {
      for (final a in AspectRatio.standard) {
        for (final s in CanvasSpec.supportedShortSides) {
          final out = applyCommand(lanes(), SetCanvas(aspect: a, baseShortSide: s), ctx());
          expect(out.rejection, isNull, reason: '$a $s');
          expectValid(out.project, '$a $s');
        }
      }
    });

    test('settings commands are one history entry each and bump the timeline stamp', () {
      final out = applyCommand(lanes(), const SetBackground(SolidBackground(0xFF112233)), ctx(stamp: 4));
      expect(out.project.revision, 4);
      expect(out.changedTracks, isEmpty);
      expect((out.project.settings.background as SolidBackground).color, 0xFF112233);
    });
  });
}
