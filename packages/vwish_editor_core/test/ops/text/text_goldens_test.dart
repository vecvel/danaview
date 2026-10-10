// OWNER: CORE-14
//
// Before/after golden tests for the text commands (lane selection, animations, rejections as
// data). Every applied result validates fully and the dry run agrees with the apply (`runCase`).
// Regenerate with `UPDATE_GOLDENS=1 dart test test/ops/text` and review the diff.

import 'package:test/test.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';

import '../framework/ops_support.dart';

typedef Case = (String, EditProject Function(), EditCommand, EditPolicy?);

ItemId id(String s) => ItemId(s);

EditProject twoLanes({bool lockTop = false}) => project([
      lane('tr_main', TrackKind.video, [vclip('it_v', 0, 300)], main: true),
      lane('tr_t1', TrackKind.text, [text('it_a', 0, 60)]),
      lane('tr_t2', TrackKind.text, [text('it_b', 30, 60)], locked: lockTop),
      lane('tr_sub', TrackKind.subtitle, [cue('it_s1', 0, 30)]),
    ]);

final List<Case> cases = [
  ('add text goes to a new text lane when the only lane is busy', standard, AddText(f(30)), null),
  ('add text uses the free text lane', standard, AddText(f(60), text: 'Hello'), null),
  (
    'add text prefers the topmost free lane',
    () => project([
          lane('tr_main', TrackKind.video, [vclip('it_v', 0, 300)], main: true),
          lane('tr_t1', TrackKind.text, []),
          lane('tr_t2', TrackKind.text, []),
        ]),
    AddText(f(10)),
    null
  ),
  ('add text falls back to the lower free lane', twoLanes, AddText(f(60), duration: 1000000), null),
  (
    'add text with every lane busy creates a lane on top',
    () => project([
          lane('tr_main', TrackKind.video, [vclip('it_v', 0, 300)], main: true),
          lane('tr_t1', TrackKind.text, [text('it_a', 0, 90)]),
          lane('tr_t2', TrackKind.text, [text('it_b', 0, 90)]),
        ]),
    AddText(f(10)),
    null
  ),
  ('add text skips a locked lane', () => twoLanes(lockTop: true), AddText(f(100)), null),
  (
    'add text with policy reject and no room',
    twoLanes,
    AddText(f(40)),
    const EditPolicy(overlap: OverlapPolicy.reject)
  ),
  (
    'add text on an explicit busy lane moves to the nearest free one',
    twoLanes,
    AddText(f(40), track: const TrackId('tr_t1')),
    null
  ),
  (
    'add text with a style',
    standard,
    AddText(f(100), text: 'Big', style: const TextStyleSpec(fontSizePt: 120, bold: true)),
    null
  ),
  ('add empty text', standard, AddText(f(100), text: '  '), null),
  ('add text with a bad size', standard, AddText(f(100), style: const TextStyleSpec(fontSizePt: 500)), null),
  ('set text', standard, SetText(id('it_t1'), 'Another title'), null),
  ('set blank text', standard, SetText(id('it_t1'), '   '), null),
  ('set text on a cue', standard, SetText(id('it_s1'), 'x'), null),
  ('set text style', standard, SetTextStyle([id('it_t1')], bold: true, fontSizePt: 72), null),
  ('set text style out of range', standard, SetTextStyle([id('it_t1')], letterSpacing: 500), null),
  (
    'set text animation fits in + out to the duration',
    standard,
    SetTextAnimation(
        [id('it_t1')],
        TextAnimation(
            inKind: TextAnimKind.typewriter, inDuration: f(30), outKind: TextAnimKind.fade, outDuration: f(30))),
    null
  ),
  (
    'set text animation with a typewriter out',
    standard,
    SetTextAnimation([id('it_t1')], TextAnimation(outKind: TextAnimKind.typewriter, outDuration: f(5))),
    null
  ),
  (
    'text commands on a locked lane',
    () => project([
          lane('tr_txt', TrackKind.text, [text('it_t', 0, 30)], locked: true),
        ]),
    SetText(id('it_t'), 'x'),
    null
  ),
];

void main() {
  final golden = GoldenFile('test/ops/text/goldens/text.golden');
  tearDownAll(golden.save);
  for (final c in cases) {
    test(c.$1, () => golden.check(c.$1, runCase(c.$1, c.$2(), c.$3, policy: c.$4 ?? const EditPolicy())));
  }
}
