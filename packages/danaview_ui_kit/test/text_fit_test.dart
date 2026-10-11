import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'test_utils.dart';

/// True when [finder]'s text is laid out in full: not ellipsized, faded or clipped.
bool fitsFully(WidgetTester tester, Finder finder) {
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  return !paragraph.didExceedMaxLines && paragraph.size.width + 0.5 >= paragraph.getMaxIntrinsicWidth(double.infinity);
}

void main() {
  const narrowLarge = Surface('narrow touch 1.35x', Size(320, 568), 1.35, TargetPlatform.iOS);

  testWidgets('a toast moves to the top while the keyboard is up', (tester) async {
    late BuildContext ctx;
    await pumpKit(tester, narrowLarge, Builder(builder: (context) {
      ctx = context;
      return const SizedBox.expand();
    }));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();

    DanaviewToast.show(ctx, 'Nothing to paste');
    await tester.pump(const Duration(milliseconds: 300));
    final toast = tester.getRect(find.ancestor(of: find.text('Nothing to paste'), matching: find.byType(DanaviewSurface)));
    expect(toast.bottom, lessThan(568 - 300), reason: 'toast $toast must stay clear of the keyboard band');
    expect(toast.top, lessThan(100));
    DanaviewToast.dismiss();
  });

  // The test font draws every glyph a full em wide, so these check how space is shared rather
  // than whether a given label fits.
  testWidgets('row menus widen with the text size', (tester) async {
    Future<double> menuWidth(double textScale) async {
      await pumpKit(
        tester,
        Surface('wide touch ${textScale}x', const Size(402, 874), textScale, TargetPlatform.iOS),
        Center(
          child: DanaviewMenuIconTrigger(
            icon: Icons.more_horiz,
            entries: [DanaviewMenuItem(label: 'Remove from playlist', destructive: true, onTap: () {})],
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      final menu = find.ancestor(of: find.text('Remove from playlist'), matching: find.byType(DanaviewSurface));
      final width = tester.getSize(menu).width;
      expectInside(tester, menu, const Size(402, 874));
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      return width;
    }

    final regular = await menuWidth(1.0);
    final large = await menuWidth(1.35);
    expect(large, closeTo(regular * 1.35, 1));
    expectNoErrors(tester);
  });

  testWidgets('a section header value gets the room a short title leaves', (tester) async {
    const value = '1:00:05 – 1:20:30';
    await pumpKit(
      tester,
      narrowLarge,
      const DanaviewSectionHeader(
        'Loop',
        padding: EdgeInsets.zero,
        action: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    final title = tester.renderObject<RenderParagraph>(find.text('Loop'));
    final action = tester.renderObject<RenderParagraph>(find.text(value));
    expect(fitsFully(tester, find.text('Loop')), isTrue);
    expect(action.constraints.maxWidth, closeTo(320 - 12 - title.size.width, 1));
    expect(action.constraints.maxWidth, greaterThan(320 / 2));
    expectNoErrors(tester);
  });

  testWidgets('the seek preview fits an hour-long timestamp at large text sizes', (tester) async {
    await pumpKit(
      tester,
      narrowLarge,
      Padding(
        padding: const EdgeInsets.only(top: 200, left: 16, right: 16),
        child: DanaviewSeekBar(
          position: const Duration(minutes: 10),
          duration: const Duration(hours: 1, minutes: 30),
          buffer: Duration.zero,
          chapters: const <Chapter>[],
          onSeek: (_) {},
        ),
      ),
    );
    final bar = tester.getRect(find.byType(DanaviewSeekBar));
    final gesture = await tester.startGesture(Offset(bar.left + bar.width * 0.8, bar.center.dy));
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(12, 0));
      await tester.pump();
    }
    final preview = find.byWidgetPredicate((w) => w is Text && RegExp(r'^\d:\d\d:\d\d$').hasMatch(w.data ?? ''));
    expect(preview, findsOneWidget);
    expect(fitsFully(tester, preview), isTrue);
    expectInside(tester, preview, narrowLarge.size);
    await gesture.up();
    await tester.pumpAndSettle();
    expectNoErrors(tester);
  });
}
