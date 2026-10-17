// OWNER: UX-07
//
// PriorityRowPlanner (ux.md §6.7 rule 2) and measureTextWidth.

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/layout/priority_row_planner.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

void main() {
  const items = [
    PriorityRowItem('time', extent: 120, mandatory: true),
    PriorityRowItem('prevFrame', extent: 44, priority: 2),
    PriorityRowItem('play', extent: 44, mandatory: true),
    PriorityRowItem('nextFrame', extent: 44, priority: 2),
    PriorityRowItem('snap', extent: 60, priority: 5),
    PriorityRowItem('zoom', extent: 30, priority: 6),
  ];
  const more = 44.0;

  test('everything fits: every item in order, no "more"', () {
    final plan = PriorityRowPlanner.plan(items: items, width: 400, moreExtent: more);
    expect(plan.shown, ['time', 'prevFrame', 'play', 'nextFrame', 'snap', 'zoom']);
    expect(plan.overflow, isEmpty);
    expect(plan.showMore, isFalse);
    expect(plan.used, 342);
  });

  test('mandatory items and "more" first, then optional items by priority while they fit', () {
    final plan = PriorityRowPlanner.plan(items: items, width: 300, moreExtent: more);
    // 120 + 44 + more 44 = 208; prevFrame 252; nextFrame 296; snap (60) no; zoom (30) no.
    expect(plan.shown, ['time', 'prevFrame', 'play', 'nextFrame']);
    expect(plan.overflow, ['snap', 'zoom']);
    expect(plan.showMore, isTrue);
    expect(plan.used, 296);
  });

  test('an item that does not fit is skipped and smaller ones after it are still tried', () {
    final plan = PriorityRowPlanner.plan(items: items, width: 340, moreExtent: more);
    // 296 after the frame steps; snap 356 > 340 is skipped; zoom 326 fits.
    expect(plan.shown, ['time', 'prevFrame', 'play', 'nextFrame', 'zoom']);
    expect(plan.overflow, ['snap']);
  });

  test('mandatory items always show, even when they overflow on their own', () {
    final plan = PriorityRowPlanner.plan(items: items, width: 100, moreExtent: more);
    expect(plan.shown, ['time', 'play']);
    expect(plan.overflow, ['prevFrame', 'nextFrame', 'snap', 'zoom']);
    expect(plan.showMore, isTrue);
  });

  test('forceMore keeps "more" even when nothing overflows; ties keep their order', () {
    final plan = PriorityRowPlanner.plan(items: items, width: 1000, moreExtent: more, forceMore: true);
    expect(plan.showMore, isTrue);
    expect(plan.overflow, isEmpty);
    expect(plan.used, 342 + more);
    final tie = PriorityRowPlanner.plan(
      items: const [PriorityRowItem('a', extent: 50), PriorityRowItem('b', extent: 50), PriorityRowItem('c', extent: 50)],
      width: 120,
      moreExtent: 20,
    );
    expect(tie.shown, ['a', 'b']);
    expect(tie.overflow, ['c']);
  });

  test('the plan never exceeds the width once the mandatory items and "more" fit', () {
    // Mandatory items plus "more" take 208.
    for (var width = 208.0; width <= 1280; width += 7) {
      final plan = PriorityRowPlanner.plan(items: items, width: width, moreExtent: more);
      expect(plan.used, lessThanOrEqualTo(width + 1e-6), reason: 'width $width');
      expect(plan.shown.length + plan.overflow.length, items.length);
    }
  });

  test('measureTextWidth grows with the text scale and rounds up to whole pixels', () {
    final style = DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family);
    final w1 = measureTextWidth('00:12:15 / 01:30:00', style);
    final w135 = measureTextWidth('00:12:15 / 01:30:00', style, textScaler: const TextScaler.linear(1.35));
    expect(w1, greaterThan(0));
    expect(w1, w1.roundToDouble());
    expect(w135, greaterThan(w1));
  });
}
