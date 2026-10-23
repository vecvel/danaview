import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'test_utils.dart';

void main() {
  for (final (size, expected) in [(const Size(375, 812), 375.0), (const Size(800, 900), 752.0), (const Size(1280, 800), 1216.0)]) {
    testWidgets('sheet has no width cap at ${size.width.toInt()} px (full width on phones, gutters beyond)', (tester) async {
      late BuildContext ctx;
      await pumpKit(tester, Surface('$size', size, 1.0, TargetPlatform.iOS), Builder(builder: (context) {
        ctx = context;
        return const SizedBox.expand();
      }));
      showDanaviewSheet<void>(ctx, builder: (context) => const SizedBox(height: 120, child: Text('Wide')));
      await tester.pumpAndSettle();
      // Content sits inside the sheet's default 16 px side padding.
      expect(tester.getSize(find.text('Wide')).width, expected - 32);
      expect(tester.getCenter(find.text('Wide')).dx, size.width / 2);
      expectNoErrors(tester);
    });
  }

  testWidgets('menu is keyboard navigable', (tester) async {
    String? picked;
    await pumpKit(
      tester,
      surfaces[2],
      Center(
        child: DanaviewMenuIconTrigger(
          icon: Icons.more_horiz,
          entries: [
            const DanaviewMenuHeader('Speed'),
            const DanaviewMenuItem(label: '0.5x', enabled: false),
            DanaviewMenuItem(label: '1.0x', selected: true, onTap: () => picked = '1.0x'),
            DanaviewMenuItem(label: '1.5x', onTap: () => picked = '1.5x'),
          ],
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, '1.5x');
    expect(find.text('1.5x'), findsNothing);
    expectNoErrors(tester);
  });

  testWidgets('Esc closes an open menu even when focus is outside it; the next Esc goes on (FIX-QA02-M2-2)', (tester) async {
    final outside = FocusNode(debugLabel: 'outside');
    addTearDown(outside.dispose);
    var outsideEsc = 0;
    await pumpKit(
      tester,
      surfaces[2],
      Focus(
        focusNode: outside,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) outsideEsc++;
          return KeyEventResult.handled;
        },
        child: Center(
          child: DanaviewMenuIconTrigger(
            icon: Icons.more_horiz,
            entries: [DanaviewMenuItem(label: 'Split', onTap: () {})],
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('Split'), findsOneWidget);
    expect(DanaviewMenuAnchor.anyOpen, isTrue);
    // Focus leaves the menu's scope (as on the Android tablet): Esc must still close the menu.
    outside.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Split'), findsNothing);
    expect(DanaviewMenuAnchor.anyOpen, isFalse);
    expect(outsideEsc, 0, reason: 'the Esc that closed the menu reaches nothing behind it');
    expect(FocusManager.instance.primaryFocus, outside);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(outsideEsc, 1, reason: 'with the menu closed, Esc does what it did before');
    expectNoErrors(tester);
  });

  for (final surface in surfaces) {
    group('$surface', () {
      testWidgets('dropdown menus near screen edges stay on screen and select', (tester) async {
        var value = 0;
        final options = [
          for (var i = 0; i < 30; i++) DanaviewOption(value: i, label: 'Track $i $longText', icon: Icons.subtitles),
        ];
        await pumpKit(
          tester,
          surface,
          StatefulBuilder(
            builder: (context, setState) => Stack(
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  child: DanaviewDropdown<int>(
                    key: const ValueKey('top'),
                    value: value,
                    label: 'Subtitles',
                    options: options,
                    onChanged: (v) => setState(() => value = v),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: DanaviewDropdown<int>(
                    key: const ValueKey('bottom'),
                    value: value,
                    compact: true,
                    options: options,
                    onChanged: (v) => setState(() => value = v),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  child: DanaviewMenuIconTrigger(
                    icon: Icons.more_horiz,
                    tooltip: 'More',
                    entries: [
                      const DanaviewMenuHeader('Actions'),
                      DanaviewMenuItem(label: longText, icon: Icons.edit, onTap: () {}),
                      const DanaviewMenuDivider(),
                      DanaviewMenuItem(label: 'Delete', destructive: true, onTap: () {}),
                      const DanaviewMenuItem(label: 'Disabled', enabled: false),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
        expectNoErrors(tester);

        for (final (index, key) in [(3, 'top'), (5, 'bottom')]) {
          await tester.tap(find.byKey(ValueKey(key)));
          await tester.pumpAndSettle();
          expectNoErrors(tester);
          final item = find.text('Track $index $longText');
          final menu = find.ancestor(of: item, matching: find.byType(DanaviewSurface));
          expect(menu, findsOneWidget);
          expectInside(tester, menu, surface.size);

          await tester.ensureVisible(item);
          await tester.pumpAndSettle();
          await tester.tap(item);
          await tester.pumpAndSettle();
          expect(value, index);
          expect(menu, findsNothing);
        }

        await tester.tap(find.byIcon(Icons.more_horiz));
        await tester.pumpAndSettle();
        final actions = find.ancestor(of: find.text('Delete'), matching: find.byType(DanaviewSurface));
        expectInside(tester, actions, surface.size);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Delete'), findsNothing);

        await tester.tap(find.byIcon(Icons.more_horiz));
        await tester.pumpAndSettle();
        await tester.tapAt(Offset(surface.size.width / 2, 8));
        await tester.pumpAndSettle();
        expect(find.text('Delete'), findsNothing);
        expectNoErrors(tester);
      });

      testWidgets('sheet with tall content is capped, scrolls and closes', (tester) async {
        Future<String?>? result;
        await pumpKit(
          tester,
          surface,
          Builder(
            builder: (context) => DanaviewButton.primary(
              label: 'Open',
              onPressed: () {
                result = showDanaviewSheet<String>(
                  context,
                  title: longText,
                  builder: (context) => Column(
                    children: [
                      for (var i = 0; i < 60; i++)
                        DanaviewListTile(title: 'Row $i $longText', onTap: () => Navigator.of(context).pop('row $i')),
                    ],
                  ),
                );
              },
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expectNoErrors(tester);

        final sheet = find.ancestor(of: find.text('Row 0 $longText'), matching: find.byType(SafeArea)).first;
        expect(tester.getSize(sheet).height, lessThanOrEqualTo(surface.size.height * 0.85 + 1));

        await tester.dragUntilVisible(
          find.text('Row 59 $longText'),
          find.byType(SingleChildScrollView).last,
          const Offset(0, -300),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Row 59 $longText'));
        await tester.pumpAndSettle();
        expect(await result, 'row 59');
        expectNoErrors(tester);
      });

      testWidgets('sheet closes via close button and drag down', (tester) async {
        late BuildContext ctx;
        await pumpKit(tester, surface, Builder(builder: (context) {
          ctx = context;
          return const SizedBox.expand();
        }));

        final first = showDanaviewSheet<void>(
          ctx,
          title: 'Speed',
          builder: (context) => const Text('Content'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.close_rounded));
        await tester.pumpAndSettle();
        await first;
        expect(find.text('Content'), findsNothing);

        showDanaviewSheet<void>(ctx, builder: (context) => const SizedBox(height: 200, child: Text('Drag me')));
        await tester.pumpAndSettle();
        await tester.drag(find.text('Drag me'), const Offset(0, 400));
        await tester.pumpAndSettle();
        expect(find.text('Drag me'), findsNothing);
        expectNoErrors(tester);
      });

      testWidgets('dialogs: tall content, confirm and prompt validation', (tester) async {
        late BuildContext ctx;
        await pumpKit(tester, surface, Builder(builder: (context) {
          ctx = context;
          return const SizedBox.expand();
        }));

        showDanaviewDialog<void>(
          ctx,
          builder: (context) => DanaviewDialog(
            icon: Icons.info_rounded,
            title: longText,
            message: List.filled(30, longText).join(' '),
            actions: [
              DanaviewButton.secondary(label: longText, onPressed: () => Navigator.of(context).pop()),
              DanaviewButton.primary(label: 'OK', onPressed: () => Navigator.of(context).pop()),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expectNoErrors(tester);
        expectInside(tester, find.byType(DanaviewDialog), surface.size);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();

        final confirm = showDanaviewConfirm(ctx, title: 'Delete playlist?', message: longText, confirmLabel: 'Delete', destructive: true);
        await tester.pumpAndSettle();
        expectNoErrors(tester);
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(await confirm, isTrue);

        final cancelled = showDanaviewConfirm(ctx, title: 'Sure?');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(await cancelled, isFalse);

        final prompt = showDanaviewPrompt(
          ctx,
          title: 'New playlist',
          hint: 'Name',
          confirmLabel: 'Create',
          validator: (v) => v.isEmpty ? 'Name is required' : null,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();
        expect(find.text('Name is required'), findsOneWidget);
        expectNoErrors(tester);

        await tester.enterText(find.byType(TextField), '  Road trip  ');
        await tester.pumpAndSettle();
        expect(find.text('Name is required'), findsNothing);
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();
        expect(await prompt, 'Road trip');
        expectNoErrors(tester);
      });

      testWidgets('toast shows above the bottom inset and auto-dismisses', (tester) async {
        late BuildContext ctx;
        await pumpKit(tester, surface, Builder(builder: (context) {
          ctx = context;
          return const SizedBox.expand();
        }));
        DanaviewToast.show(ctx, longText, kind: DanaviewToastKind.success);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text(longText), findsOneWidget);
        expectInside(tester, find.text(longText), surface.size);
        DanaviewToast.show(ctx, 'Replaced', kind: DanaviewToastKind.error);
        await tester.pump();
        expect(find.text(longText), findsNothing);
        await tester.pumpAndSettle();
        expect(find.text('Replaced'), findsNothing);
        expectNoErrors(tester);
      });
    });
  }
}
