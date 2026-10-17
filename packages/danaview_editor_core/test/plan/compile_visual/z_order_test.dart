// OWNER: CORE-30
//
// z = band·10000 + (laneIndexInBand + 1)·10 + sub (ARCH §11.4) and the lane enumeration, pinned
// against CORE-36's laneZ so the compiler and LayerLimits agree.

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

import 'support.dart';

void main() {
  test('ARCH §11.4 examples', () {
    final main = PlanZ.lane(TrackKind.video, 0);
    expect(main, 10);
    expect(PlanZ.backdrop(main), 5);
    expect(PlanZ.transitionHelper(main), 15);
    expect(PlanZ.lane(TrackKind.overlay, 0), 10010);
    expect(PlanZ.lane(TrackKind.text, 0), 20010);
    expect(PlanZ.lane(TrackKind.subtitle, 0), 30010);
    expect(PlanZ.of(band: 1, laneIndexInBand: 2, sub: -5), 10025);
  });

  test('bands order every lane of a lower band below every lane of a higher one', () {
    final top = PlanZ.of(band: 0, laneIndexInBand: PlanZ.maxLanesPerBand - 1, sub: PlanZ.transitionHelperSub);
    final bottom = PlanZ.of(band: 1, laneIndexInBand: 0, sub: PlanZ.backdropSub);
    expect(top, lessThan(bottom));
    for (var band = 0; band <= 3; band++) {
      for (final lane in [0, 1, 57, PlanZ.maxLanesPerBand - 1]) {
        for (final sub in [-5, 0, 5]) {
          expect(PlanZ.bandOf(PlanZ.of(band: band, laneIndexInBand: lane, sub: sub)), band);
        }
      }
    }
  });

  test('out-of-range inputs are rejected', () {
    expect(() => PlanZ.of(band: 4, laneIndexInBand: 0), throwsRangeError);
    expect(() => PlanZ.of(band: 0, laneIndexInBand: -1), throwsRangeError);
    expect(() => PlanZ.of(band: 0, laneIndexInBand: PlanZ.maxLanesPerBand), throwsRangeError);
    expect(() => PlanZ.of(band: 0, laneIndexInBand: 0, sub: 6), throwsRangeError);
    expect(() => PlanZ.lane(TrackKind.audio, 0), throwsArgumentError);
  });

  test('the clip z equals CORE-36 laneZ for every visual kind and lane index', () {
    for (final kind in TrackKind.values.where((k) => k.isVisual)) {
      for (var i = 0; i < 50; i++) {
        expect(PlanZ.lane(kind, i), laneZ(kind, i));
      }
    }
  });

  test('planLanesOf counts each kind from 0 in canonical order, hidden lanes included, audio skipped', () {
    final tracks = [
      mainLane(const []),
      lane('tr_v2', TrackKind.video, const [], hidden: true),
      lane('tr_v3', TrackKind.video, const []),
      lane('tr_o1', TrackKind.overlay, const []),
      lane('tr_t1', TrackKind.text, const []),
      lane('tr_s1', TrackKind.subtitle, const [], subtitle: const SubtitleTrackData()),
      lane('tr_a1', TrackKind.audio, const []),
    ];
    final lanes = planLanesOf(tracks);
    expect([for (final l in lanes) (l.track.id as String, l.band, l.laneIndexInBand, l.z)], [
      ('tr_main', 0, 0, 10),
      ('tr_v2', 0, 1, 20),
      ('tr_v3', 0, 2, 30),
      ('tr_o1', 1, 0, 10010),
      ('tr_t1', 2, 0, 20010),
      ('tr_s1', 3, 0, 30010),
    ]);
    expect(lanes.first.isMain, isTrue);
    expect(lanes[1].hidden, isTrue);
    expect(lanes.first.backdropZ, 5);
    expect(lanes.first.transitionHelperZ, 15);
  });
}
