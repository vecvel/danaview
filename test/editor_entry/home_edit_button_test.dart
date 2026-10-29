import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_features/chrome.dart' as chrome;
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../library_test_utils.dart';

const _editorTooltip = 'Video editor';
const _settingsTooltip = 'Settings';

Future<LibraryTestEnv> _pumpHome(
  WidgetTester tester, {
  required Size size,
  double textScale = 1.0,
  VoidCallback? onOpenEditor,
  VoidCallback? onOpenSettings,
}) async {
  useSurface(tester, TestSurface(size, textScale, padding: const EdgeInsets.only(top: 20)));
  final env = await LibraryTestEnv.create();
  await tester.pumpWidget(libraryTestApp(
    env,
    DanaviewHomeScreen(
      onOpenPlayer: () {},
      onOpenFolder: (_) {},
      onOpenPlaylist: (_) {},
      onOpenSettings: onOpenSettings,
      onOpenEditor: onOpenEditor,
    ),
    textScale: textScale,
  ));
  await pumpFrames(tester);
  return env;
}

Future<void> _finish(WidgetTester tester, LibraryTestEnv env) async {
  DanaviewToast.dismiss();
  await tester.pumpWidget(const SizedBox());
  await env.dispose();
}

Finder get _title => find.text('Danaview');

/// The slot the title text occupies in the header row.
Size _titleSlot(WidgetTester tester) =>
    tester.getSize(find.ancestor(of: _title, matching: find.byType(Expanded)).first);

/// The phone tab bar (DESIGN_SYSTEM §10.5).
Finder get _tabBar => find.byType(HomePhoneTabBar);

void main() {
  testWidgets('tablet header order is logo, title, edit, import, settings with DanaviewSpacing.sm between the buttons',
      (tester) async {
    final env = await _pumpHome(tester, size: const Size(820, 1180), onOpenEditor: () {}, onOpenSettings: () {});
    final logo = tester.getRect(find.byType(DanaviewLogo));
    final title = tester.getRect(_title);
    final edit = tester.getRect(find.byTooltip(_editorTooltip));
    final import = tester.getRect(find.byTooltip(HomeChromeLabels.import));
    final gear = tester.getRect(find.byTooltip(_settingsTooltip));

    expect(_tabBar, findsNothing);
    expect(logo.right, lessThanOrEqualTo(title.left));
    expect(title.right, lessThanOrEqualTo(edit.left));
    expect(edit.right, lessThanOrEqualTo(import.left));
    expect(import.right, lessThanOrEqualTo(gear.left));
    expect(import.left - edit.right, DanaviewSpacing.sm);
    expect(gear.left - import.right, DanaviewSpacing.sm);
    // 34 pt toolbar circles inside 44 pt targets.
    expect(edit.size, const Size(44, 44));
    expect(gear.size, const Size(44, 44));
    expect(edit.center.dy, closeTo(gear.center.dy, 0.01));

    final button = tester.widget<DanaviewIconButton>(find.widgetWithIcon(DanaviewIconButton, Icons.movie_edit));
    expect(button.variant, DanaviewIconButtonVariant.toolbar);
    expect(button.size, DanaviewIconButton.toolbarSize);
    expect(button.tooltip, _editorTooltip);
    expect(button.semanticLabel, 'Open video editor');
    expect(find.bySemanticsLabel('Open video editor'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finish(tester, env);
  });

  testWidgets('phones keep Import in the header and move the editor and settings to the tab bar', (tester) async {
    final env = await _pumpHome(tester, size: const Size(390, 844), onOpenEditor: () {}, onOpenSettings: () {});
    final header = find.byKey(const ValueKey('home-top-bar'));
    expect(find.descendant(of: header, matching: find.byTooltip(HomeChromeLabels.import)), findsOneWidget);
    expect(find.descendant(of: header, matching: find.byTooltip(_editorTooltip)), findsNothing);
    expect(find.descendant(of: header, matching: find.byTooltip(_settingsTooltip)), findsNothing);

    expect(_tabBar, findsOneWidget);
    final library = tester.getRect(find.descendant(of: _tabBar, matching: find.text('Library')));
    final edit = tester.getRect(find.descendant(of: _tabBar, matching: find.byTooltip(_editorTooltip)));
    final more = tester.getRect(find.descendant(of: _tabBar, matching: find.byTooltip(_settingsTooltip)));
    expect(library.right, lessThanOrEqualTo(edit.left));
    expect(edit.right, lessThanOrEqualTo(more.left));
    expect(edit.height, greaterThanOrEqualTo(44));
    expect(find.descendant(of: _tabBar, matching: find.text('More')), findsOneWidget);
    expect(find.bySemanticsLabel('Open video editor'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finish(tester, env);
  });

  testWidgets('the edit button is hidden when the callback is null', (tester) async {
    for (final size in const [Size(390, 844), Size(820, 1180)]) {
      final env = await _pumpHome(tester, size: size, onOpenSettings: () {});
      expect(find.byTooltip(_editorTooltip), findsNothing, reason: '$size');
      expect(find.byIcon(Icons.movie_edit), findsNothing, reason: '$size');
      expect(find.byTooltip(_settingsTooltip), findsOneWidget, reason: '$size');
      await _finish(tester, env);
    }
  });

  testWidgets('the edit button works without a settings button', (tester) async {
    var env = await _pumpHome(tester, size: const Size(820, 1180), onOpenEditor: () {});
    expect(find.byTooltip(_settingsTooltip), findsNothing);
    final edit = tester.getRect(find.byTooltip(_editorTooltip));
    expect(tester.getRect(_title).right, lessThanOrEqualTo(edit.left));
    await _finish(tester, env);
    env = await _pumpHome(tester, size: const Size(390, 844), onOpenEditor: () {});
    expect(find.descendant(of: _tabBar, matching: find.byTooltip(_editorTooltip)), findsOneWidget);
    expect(find.text('More'), findsNothing);
    await _finish(tester, env);
  });

  for (final size in const [Size(390, 844), Size(820, 1180)]) {
    testWidgets('tapping the edit button invokes only the editor callback at ${size.width.toInt()} px', (tester) async {
      var editor = 0;
      var settings = 0;
      final env = await _pumpHome(
        tester,
        size: size,
        onOpenEditor: () => editor++,
        onOpenSettings: () => settings++,
      );
      await tester.tap(find.byTooltip(_editorTooltip));
      await tester.pump();
      expect(editor, 1);
      expect(settings, 0);
      await tester.tap(find.byTooltip(_settingsTooltip));
      await tester.pump();
      expect(editor, 1);
      expect(settings, 1);
      await _finish(tester, env);
    });
  }

  group('no overflow', () {
    for (final width in [280.0, 320.0, 390.0]) {
      for (final scale in [0.85, 1.0, 1.35]) {
        testWidgets('Home header at ${width.toInt()} px, text scale $scale', (tester) async {
          final env = await _pumpHome(
            tester,
            size: Size(width, 700),
            textScale: scale,
            onOpenEditor: () {},
            onOpenSettings: () {},
          );
          expect(tester.takeException(), isNull);
          expect(find.byTooltip(_editorTooltip), findsOneWidget);
          final screen = Rect.fromLTWH(0, 0, width, 700);
          for (final finder in [
            find.byTooltip(_editorTooltip),
            find.byTooltip(_settingsTooltip),
            find.byTooltip(HomeChromeLabels.import),
            _title,
          ]) {
            final rect = tester.getRect(finder);
            // Inside the screen (the tab bar's items reach its bottom and side edges).
            expect(screen.expandToInclude(rect), screen, reason: '$rect');
          }
          // The buttons never shrink; the title gives way first and keeps at least 96 px.
          expect(tester.getSize(find.byTooltip(HomeChromeLabels.import)), const Size(44, 44));
          expect(tester.getSize(find.byTooltip(_editorTooltip)).height, greaterThanOrEqualTo(44));
          expect(tester.getSize(find.byTooltip(_settingsTooltip)).height, greaterThanOrEqualTo(44));
          expect(_titleSlot(tester).width, greaterThanOrEqualTo(96));
          await _finish(tester, env);
        });
      }
    }
  });

  testWidgets('at 280 px and 1.35x the title takes all the width the logo and Import leave', (tester) async {
    final env = await _pumpHome(
      tester,
      size: const Size(280, 700),
      textScale: 1.35,
      onOpenEditor: () {},
      onOpenSettings: () {},
    );
    // 280 - 2 x 16 gutter - 28 logo - 8 gap - (8 gap + 44 Import).
    expect(_titleSlot(tester).width, closeTo(280 - 32 - 28 - 8 - 52, 0.01));
    expect(tester.takeException(), isNull);
    await _finish(tester, env);
  });

  testWidgets('the features chrome entry point exports the shared library chrome', (tester) async {
    // Compile-time proof that `package:danaview_features/chrome.dart` exposes what danaview_editor reuses.
    expect(chrome.danaviewLibraryInsets(390), isA<EdgeInsets>());
    final types = <Type>[
      chrome.DanaviewLibraryFrame,
      chrome.DanaviewLibraryTopBar,
      chrome.DanaviewLibrarySectionHeader,
      chrome.DanaviewLibraryGroup,
      chrome.DanaviewInlineEmpty,
      chrome.DanaviewRefreshOnReturn,
    ];
    expect(types.toSet(), hasLength(6));
  });
}
