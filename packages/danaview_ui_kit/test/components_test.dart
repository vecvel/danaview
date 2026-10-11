import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'test_utils.dart';

void main() {
  for (final surface in surfaces) {
    group('$surface', () {
      testWidgets('buttons never overflow with long labels', (tester) async {
        var taps = 0;
        await pumpKit(
          tester,
          surface,
          SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final variant in DanaviewButtonVariant.values)
                  for (final size in DanaviewButtonSize.values)
                    DanaviewButton(
                      label: longText,
                      variant: variant,
                      size: size,
                      icon: Icons.play_arrow_rounded,
                      trailingIcon: Icons.chevron_right_rounded,
                      onPressed: () => taps++,
                    ),
                DanaviewButton.primary(label: longText, expand: true, onPressed: () {}),
                const DanaviewButton.secondary(label: 'Disabled', onPressed: null),
                Row(
                  children: [
                    Expanded(child: DanaviewButton.tonal(label: longText, icon: Icons.add, onPressed: () {})),
                    const SizedBox(width: 8),
                    Expanded(child: DanaviewButton.ghost(label: longText, onPressed: () {})),
                  ],
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      DanaviewButton.primary(label: 'Short', onPressed: () {}),
                      DanaviewIconButton(icon: Icons.close, onPressed: () {}, tooltip: 'Close'),
                    ],
                  ),
                ),
                Wrap(
                  children: [
                    for (final variant in DanaviewIconButtonVariant.values)
                      DanaviewIconButton(icon: Icons.settings, variant: variant, onPressed: () {}),
                    const DanaviewIconButton(icon: Icons.lock, onPressed: null),
                    DanaviewIconButton(icon: Icons.push_pin, selected: true, onPressed: () {}),
                  ],
                ),
                const SizedBox(width: 48, child: DanaviewBadge(longText, icon: Icons.hd)),
                const DanaviewBadge('4K', solid: true, color: DanaviewColors.primary),
              ],
            ),
          ),
        );
        expectNoErrors(tester);
        await tester.tap(find.byType(DanaviewButton).first);
        await tester.pumpAndSettle();
        expect(taps, 1);
        expectNoErrors(tester);
      });

      testWidgets('list tiles and section headers ellipsize long text', (tester) async {
        var tapped = false;
        await pumpKit(
          tester,
          surface,
          ListView(
            children: [
              DanaviewSectionHeader(
                longText,
                subtitle: longText,
                action: DanaviewButton.ghost(label: longText, size: DanaviewButtonSize.sm, onPressed: () {}),
              ),
              DanaviewListTile(
                title: longText,
                subtitle: longText,
                leading: const DanaviewTileIcon(Icons.folder_rounded),
                trailing: const DanaviewBadge('NEW'),
                showChevron: true,
                onTap: () => tapped = true,
              ),
              const DanaviewListTile(title: longText, subtitle: longText, subtitleMaxLines: 2, dense: true),
              DanaviewListTile(title: longText, selected: true, onTap: () {}),
              DanaviewListTile(title: longText, enabled: false, onTap: () {}),
              DanaviewListTile(title: 'Delete', destructive: true, onTap: () {}),
            ],
          ),
        );
        expectNoErrors(tester);
        await tester.tap(find.byType(DanaviewListTile).first);
        await tester.pump();
        expect(tapped, isTrue);
      });

      testWidgets('switch and switch row toggle', (tester) async {
        var value = false;
        var rowValue = true;
        await pumpKit(
          tester,
          surface,
          StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                DanaviewSwitch(value: value, onChanged: (v) => setState(() => value = v)),
                DanaviewSwitchRow(
                  title: longText,
                  subtitle: longText,
                  value: rowValue,
                  onChanged: (v) => setState(() => rowValue = v),
                ),
                const DanaviewSwitchRow(title: 'Disabled', value: true, onChanged: null),
              ],
            ),
          ),
        );
        await tester.tap(find.byType(DanaviewSwitch).first);
        await tester.pumpAndSettle();
        expect(value, isTrue);
        await tester.tap(find.text(longText).first);
        await tester.pumpAndSettle();
        expect(rowValue, isFalse);
        expectNoErrors(tester);
      });

      testWidgets('chips and segmented control fit or fall back to chips', (tester) async {
        var selected = 'a';
        var segment = 1;
        await pumpKit(
          tester,
          surface,
          StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DanaviewChipGroup(
                    children: [
                      for (final id in ['a', 'b', longText])
                        DanaviewChoiceChip(
                          label: id,
                          icon: Icons.aspect_ratio,
                          selected: selected == id,
                          onTap: () => setState(() => selected = id),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  DanaviewSegmentedControl<int>(
                    key: const ValueKey('long'),
                    value: segment,
                    onChanged: (v) => setState(() => segment = v),
                    options: [
                      for (var i = 0; i < 6; i++) DanaviewOption(value: i, label: '$longText $i'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  DanaviewSegmentedControl<int>(
                    key: const ValueKey('short'),
                    value: segment,
                    onChanged: (v) => setState(() => segment = v),
                    options: const [
                      DanaviewOption(value: 0, label: 'A'),
                      DanaviewOption(value: 1, label: 'B', icon: Icons.star),
                      DanaviewOption(value: 2, label: 'C'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
        expectNoErrors(tester);
        final longControl = find.byKey(const ValueKey('long'));
        expect(find.descendant(of: longControl, matching: find.byType(DanaviewChoiceChip)), findsNWidgets(6));
        final shortControl = find.byKey(const ValueKey('short'));
        expect(find.descendant(of: shortControl, matching: find.byType(DanaviewChoiceChip)), findsNothing);

        await tester.tap(find.text('C'));
        await tester.pumpAndSettle();
        expect(segment, 2);
        await tester.tap(find.text('b'));
        await tester.pumpAndSettle();
        expect(selected, 'b');
        expectNoErrors(tester);
      });

      testWidgets('horizontal and vertical sliders change value by drag and tap', (tester) async {
        var h = 0.2;
        var v = 0.0;
        var tight = 0.5;
        await pumpKit(
          tester,
          surface,
          StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                SizedBox(
                  width: 200,
                  child: DanaviewSlider(
                    key: const ValueKey('h'),
                    value: h,
                    onChanged: (x) => setState(() => h = x),
                  ),
                ),
                SizedBox(
                  width: 24,
                  height: 160,
                  child: DanaviewSlider(
                    key: const ValueKey('v'),
                    value: v,
                    min: -12,
                    max: 12,
                    origin: 0,
                    axis: Axis.vertical,
                    onChanged: (x) => setState(() => v = x),
                  ),
                ),
                SizedBox(
                  width: 24,
                  child: DanaviewSlider(value: tight, divisions: 4, onChanged: (x) => setState(() => tight = x)),
                ),
                const SizedBox(width: 120, child: DanaviewSlider(value: 0.5, onChanged: null)),
              ],
            ),
          ),
        );
        expectNoErrors(tester);

        await tester.drag(find.byKey(const ValueKey('h')), const Offset(80, 0));
        await tester.pumpAndSettle();
        expect(h, greaterThan(0.6));

        await tester.drag(find.byKey(const ValueKey('v')), const Offset(0, -50));
        await tester.pumpAndSettle();
        expect(v, greaterThan(3));

        final hRect = tester.getRect(find.byKey(const ValueKey('h')));
        await tester.tapAt(Offset(hRect.left + 2, hRect.center.dy));
        await tester.pumpAndSettle();
        expect(h, lessThan(0.05));
        expect(tight, anyOf(0.0, 0.25, 0.5, 0.75, 1.0));
        expectNoErrors(tester);
      });

      testWidgets('volume slider and seek bar survive tight widths', (tester) async {
        var volume = 250.0;
        Duration? seeked;
        await pumpKit(
          tester,
          surface,
          StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                for (final width in [30.0, 70.0, 120.0, 300.0])
                  SizedBox(
                    width: width,
                    child: DanaviewVolumeSlider(
                      volume: volume,
                      muted: false,
                      onVolumeChanged: (x) => setState(() => volume = x),
                      onToggleMute: () {},
                    ),
                  ),
                Row(
                  children: [
                    DanaviewVolumeSlider(volume: 80, muted: true, onVolumeChanged: (_) {}, onToggleMute: () {}),
                  ],
                ),
                DanaviewSeekBar(
                  position: const Duration(seconds: 30),
                  duration: const Duration(minutes: 2),
                  buffer: const Duration(minutes: 1),
                  chapters: const [
                    Chapter(id: 0, title: 'Intro', start: Duration.zero),
                    Chapter(id: 1, title: 'Main', start: Duration(seconds: 40)),
                  ],
                  abLoop: const AbLoop(a: Duration(seconds: 10), b: Duration(seconds: 50)),
                  onSeek: (d) => seeked = d,
                ),
              ],
            ),
          ),
        );
        expectNoErrors(tester);
        final seekRect = tester.getRect(find.byType(DanaviewSeekBar));
        await tester.tapAt(Offset(seekRect.right - 3, seekRect.center.dy));
        await tester.pumpAndSettle();
        expect(seeked, isNotNull);
        expect(seeked!.inSeconds, greaterThan(100));
        expectNoErrors(tester);
      });

      testWidgets('empty state, text field, logo and spinner render in small boxes', (tester) async {
        final controller = TextEditingController(text: 'hello');
        addTearDown(controller.dispose);
        await pumpKit(
          tester,
          surface,
          Column(
            children: [
              SizedBox(
                height: 160,
                child: DanaviewEmptyState(
                  icon: Icons.video_library_rounded,
                  title: longText,
                  message: longText,
                  actions: [
                    DanaviewButton.primary(label: 'Open files', icon: Icons.folder_open, onPressed: () {}),
                    DanaviewButton.secondary(label: 'Open URL', icon: Icons.link, onPressed: () {}),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: DanaviewTextField(
                  controller: controller,
                  hint: longText,
                  prefixIcon: Icons.search,
                  errorText: longText,
                ),
              ),
              const Row(
                children: [
                  DanaviewLogo(size: 16),
                  DanaviewLogo(size: 64),
                  DanaviewSpinner(),
                ],
              ),
              const DanaviewSurface(
                shadow: DanaviewShadow.soft,
                padding: EdgeInsets.all(12),
                child: Text('Surface'),
              ),
            ],
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expectNoErrors(tester);

        await tester.tap(find.byIcon(Icons.cancel_rounded));
        await tester.pump();
        expect(controller.text, isEmpty);
        expectNoErrors(tester);
      });
    });
  }

  testWidgets('segmented control drops its icons before falling back to chips', (tester) async {
    const surface = Surface('wide', Size(1200, 800), 1.0, TargetPlatform.macOS);
    late TextStyle base;
    await pumpKit(tester, surface, Builder(builder: (context) {
      base = DefaultTextStyle.of(context).style;
      return const SizedBox();
    }));
    final painter = TextPainter(
      text: TextSpan(text: 'Option', style: base.merge(const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
      textDirection: TextDirection.ltr,
    )..layout();
    final label = painter.width;
    painter.dispose();

    Future<void> pumpAt(double segment) => pumpKit(
          tester,
          surface,
          Center(
            child: SizedBox(
              // Two segments plus the 3pt inset on each side.
              width: segment * 2 + 6,
              child: DanaviewSegmentedControl<int>(
                value: 0,
                onChanged: (_) {},
                options: const [
                  DanaviewOption(value: 0, label: 'Option', icon: Icons.star),
                  DanaviewOption(value: 1, label: 'Option', icon: Icons.bolt),
                ],
              ),
            ),
          ),
        );

    // Label, 6pt gap and 15pt icon, plus 10pt padding each side.
    await pumpAt(label + 21 + 20 + 4);
    expect(find.byIcon(Icons.star), findsOneWidget);
    expect(find.byType(DanaviewChoiceChip), findsNothing);

    await pumpAt(label + 20 + 8);
    expect(find.byIcon(Icons.star), findsNothing, reason: 'the icons make way for the labels');
    expect(find.byType(DanaviewChoiceChip), findsNothing, reason: 'still a segmented control');
    expect(find.text('Option'), findsNWidgets(2));

    await pumpAt(label + 20 - 8);
    expect(find.byType(DanaviewChoiceChip), findsNWidgets(2));
    expectNoErrors(tester);
  });
}
