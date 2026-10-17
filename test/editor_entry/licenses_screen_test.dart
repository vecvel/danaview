// OWNER: UX-42 (FIX-LICENSES)
//
// Settings › About › Open-source licences (ARCH §17.1, §20.3, §20.4; owner decision 2026-10-16):
// list contents (every explicit notice, the Figtree app font, the 10 content fonts, Flutter
// packages from the registry), rows open in place, the About row, accessibility (labelled tap
// targets ≥ 44, computed contrast, Figtree) and no overflow over 280–1280 px at 0.85–1.35.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/danaview_editor.dart' show contentFontFamilies, registerContentFontLicenses;
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/licenses.dart';
import 'package:danaview_features/src/more/legal_texts.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../library_test_utils.dart';

/// A registry entry for a package, as Flutter's NOTICES would give it.
LicenseEntry _entry(String package, String text) => LicenseEntryWithLineBreaks([package], text);

final List<LicenseEntry> _fakeRegistry = [
  _entry('go_router', 'Copyright 2013 The Flutter Authors. BSD-3-Clause.'),
  _entry('flutter_riverpod', 'MIT License\n\nCopyright (c) 2020 Remi Rousselet'),
  _entry('media_kit', 'MIT License\n\nCopyright (c) 2021 Hitesh Kumar Saini'),
  _entry(
      figtreeAppFontLicensePackage, 'Copyright 2022 The Figtree Project Authors\n\nSIL Open Font License, Version 1.1'),
  // An explicit notice's name in the registry is not listed twice.
  _entry('FFmpeg', 'duplicate'),
  for (final f in contentFontFamilies)
    _entry('${f.family} (video editor content font)',
        'Copyright the ${f.family} authors.\n\nSIL Open Font License, Version 1.1'),
];

Stream<LicenseEntry> _fakeSource() => Stream.fromIterable(_fakeRegistry);

Future<LibraryTestEnv> _pump(
  WidgetTester tester, {
  TestSurface? surface,
  Stream<LicenseEntry> Function()? source,
  VoidCallback? onBack,
}) async {
  final s = surface ?? const TestSurface(Size(390, 844), 1.0, padding: EdgeInsets.only(top: 20));
  useSurface(tester, s);
  final env = await LibraryTestEnv.create();
  await tester.pumpWidget(libraryTestApp(
    env,
    DanaviewLicensesScreen(onBack: onBack ?? () {}, licenseSource: source ?? _fakeSource),
    textScale: s.textScale,
  ));
  await pumpFrames(tester);
  return env;
}

Future<void> _finish(WidgetTester tester, LibraryTestEnv env) async {
  await tester.pumpWidget(const SizedBox());
  await env.dispose();
}

Finder get _list => find.byType(Scrollable).first;

Future<void> _show(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(find.text(text), 300, scrollable: _list);
  await tester.pump();
}

double _luminance(Color c) {
  double channel(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double _contrast(Color fg, Color bg) {
  final blended = Color.alphaBlend(fg, bg);
  final a = _luminance(blended) + 0.05;
  final b = _luminance(bg) + 0.05;
  return a > b ? a / b : b / a;
}

void main() {
  group('contents', () {
    testWidgets('lists every explicit notice the owner named, with its licence', (tester) async {
      final env = await _pump(tester);
      expect(find.text('Open-source licences'), findsOneWidget);
      const required = {
        'mpv': 'LGPL-2.1-or-later',
        'FFmpeg': 'LGPL-2.1-or-later',
        'whisper.cpp and ggml': 'MIT',
        'OpenAI Whisper speech models': 'MIT',
        'Silero VAD': 'MIT',
        'AndroidX Media3': 'Apache-2.0',
      };
      for (final MapEntry(key: name, value: licence) in required.entries) {
        final notice = danaviewBundledNotices.singleWhere((n) => n.name == name);
        expect(notice.licence, licence, reason: name);
        await _show(tester, name);
        expect(find.text(name), findsOneWidget);
        expect(find.textContaining(licence), findsWidgets);
      }
      // Every native library of the player build (media_kit libmpv) is listed too.
      for (final name in [
        'FriBidi',
        'libass',
        'dav1d',
        'FreeType',
        'HarfBuzz',
        'libpng',
        'libxml2',
        'Mbed TLS',
        'uchardet'
      ]) {
        expect(danaviewBundledNotices.map((n) => n.name), contains(name));
      }
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    });

    test('the notices carry their copyright lines and terms', () {
      String text(String name) => danaviewBundledNotices.singleWhere((n) => n.name == name).text;
      expect(text('whisper.cpp and ggml'), contains('Copyright © 2023-2026 The ggml authors'));
      expect(text('OpenAI Whisper speech models'), contains('Copyright © 2022 OpenAI'));
      // V-A12: upstream snakers4/silero-vad LICENSE.
      expect(text('Silero VAD'), contains('Copyright © 2020-present Silero Team'));
      for (final name in ['whisper.cpp and ggml', 'OpenAI Whisper speech models', 'Silero VAD']) {
        expect(text(name), contains('Permission is hereby granted, free of charge'), reason: name);
      }
      expect(text('FFmpeg'), contains('https://ffmpeg.org/download.html'));
      expect(text('mpv'), contains('GNU Lesser General Public License'));
      expect(text('AndroidX Media3'), contains('Apache License, Version 2.0'));
      expect(danaviewBundledNotices.map((n) => n.name).toSet(), hasLength(danaviewBundledNotices.length));
    });

    testWidgets('registry packages follow, sorted, with Figtree and the 10 content fonts', (tester) async {
      final env = await _pump(tester);
      expect(contentFontFamilies, hasLength(10));
      final names = [
        figtreeAppFontLicensePackage,
        for (final f in contentFontFamilies) '${f.family} (video editor content font)',
        'flutter_riverpod',
        'go_router',
        'media_kit',
      ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      for (final name in names) {
        await _show(tester, name);
        expect(find.text(name), findsOneWidget, reason: name);
      }
      // FFmpeg came from the registry too, but is listed once (as the explicit notice).
      await tester.scrollUntilVisible(find.text('FFmpeg'), -300, scrollable: _list);
      expect(find.text('FFmpeg'), findsOneWidget);

      final items = groupLicenseEntries(_fakeRegistry);
      final sorted = [...items.map((i) => i.name)]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      expect(items.map((i) => i.name), sorted);
      expect(items.map((i) => i.name), isNot(contains('FFmpeg')));
      expect(items.firstWhere((i) => i.name == figtreeAppFontLicensePackage).subtitle, 'OFL-1.1 · Font');
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    });

    test('groupLicenseEntries merges entries of one package and drops duplicates', () {
      final items = groupLicenseEntries([
        _entry('a', 'one'),
        _entry('a', 'two'),
        _entry('a', 'one'),
        const LicenseEntryWithLineBreaks(['b', 'a'], 'shared'),
      ]);
      expect(items.map((i) => i.name), ['a', 'b']);
      expect(items.first.subtitle, '3 licences');
      expect(items.first.text, allOf(contains('one'), contains('two'), contains('shared')));
      expect(items.last.subtitle, '1 licence');
    });

    testWidgets('the real registry carries the Figtree app font and every bundled content font (OFL-1.1)',
        (tester) async {
      registerDanaviewLicenses();
      registerDanaviewLicenses();
      registerContentFontLicenses();
      final entries = (await tester.runAsync(() => LicenseRegistry.licenses.toList()))!;
      final items = groupLicenseEntries(entries);
      final byName = {for (final i in items) i.name: i};
      expect(byName[figtreeAppFontLicensePackage]?.text, contains('SIL Open Font License'));
      expect(entries.where((e) => e.packages.contains(figtreeAppFontLicensePackage)), hasLength(1));
      final bundled = contentFontFamilies.where((f) => f.isBundled).toList();
      expect(bundled, hasLength(10));
      for (final f in bundled) {
        final item = byName['${f.family} (video editor content font)'];
        expect(item, isNotNull, reason: f.family);
        expect(item!.text, contains('SIL Open Font License'), reason: f.family);
        expect(item.subtitle, 'OFL-1.1 · Font');
      }
    });

    testWidgets('a row opens in place to show its licence text and closes again', (tester) async {
      final env = await _pump(tester);
      const name = 'whisper.cpp and ggml';
      await _show(tester, name);
      expect(find.textContaining('Permission is hereby granted'), findsNothing);
      await tester.tap(find.text(name));
      await tester.pump();
      expect(find.textContaining('The ggml authors'), findsOneWidget);
      expect(tester.getSemantics(find.text(name)).getSemanticsData().flagsCollection.isExpanded, Tristate.isTrue);
      await tester.tap(find.text(name));
      await tester.pump();
      expect(find.textContaining('The ggml authors'), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    });

    testWidgets('a failing or slow registry still shows the explicit notices', (tester) async {
      final env = await _pump(tester, source: () => Stream<LicenseEntry>.error(StateError('no NOTICES')));
      expect(find.text('mpv'), findsOneWidget);
      await _show(tester, 'No package licences were found.');
      expect(tester.takeException(), isNull);
      await _finish(tester, env);

      final controller = StreamController<LicenseEntry>();
      addTearDown(controller.close);
      final pending = await _pump(tester, source: () => controller.stream);
      expect(find.text('mpv'), findsOneWidget);
      await _show(tester, 'Loading the package licences…');
      expect(find.text('Loading the package licences…'), findsOneWidget);
      await _finish(tester, pending);
    });

    testWidgets('Back calls onBack', (tester) async {
      var back = 0;
      final env = await _pump(tester, onBack: () => back++);
      await tester.tap(find.byTooltip('Back'));
      expect(back, 1);
      await _finish(tester, env);
    });
  });

  group('About › Open-source licences row', () {
    testWidgets('shown with onOpenLicenses and opens the page; hidden without it', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      var opened = 0;
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewAboutScreen(onBack: () {}, onOpenPrivacy: () {}, onOpenTerms: () {}, onOpenLicenses: () => opened++),
      ));
      await pumpFrames(tester);
      await tester.scrollUntilVisible(find.text('Open-source licences'), 200);
      await tester.tap(find.text('Open-source licences'));
      expect(opened, 1);

      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewAboutScreen(onBack: () {}, onOpenPrivacy: () {}, onOpenTerms: () {}),
      ));
      await pumpFrames(tester);
      expect(find.text('Open-source licences'), findsNothing);
      await _finish(tester, env);
    });

    test('the Auto captions terms point to the page', () {
      final section = termsOfUseText.sections.singleWhere((s) => s.heading == 'Auto captions');
      final text = section.blocks.map((b) => b.text ?? '').join('\n');
      expect(openSourceLicencesLocation, 'Settings › About › Open-source licences');
      expect(text, contains(openSourceLicencesLocation));
    });
  });

  group('accessibility', () {
    for (final surface in [
      const TestSurface(Size(280, 500), 1.35),
      const TestSurface(Size(390, 844), 1.0, padding: EdgeInsets.only(top: 20)),
      const TestSurface(Size(1194, 834), 1.35),
    ]) {
      testWidgets('labelled tap targets ≥ 44, contrast ≥ 4.5:1 and Figtree at ${surface.size} @${surface.textScale}',
          (tester) async {
        final handle = tester.ensureSemantics();
        final env = await _pump(tester, surface: surface);
        bool expanded(String name) =>
            tester.getSemantics(find.text(name)).getSemanticsData().flagsCollection.isExpanded == Tristate.isTrue;
        expect(tester.getSemantics(find.text('mpv')).getSemanticsData().label, 'mpv\nLGPL-2.1-or-later · Video player');
        expect(expanded('mpv'), isFalse);
        await tester.tap(find.text('mpv'));
        await tester.pump();

        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));

        // Every tappable node is at least 44 × 44 (ARCH §17.9).
        final root = tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!;
        void visit(SemanticsNode node) {
          final data = node.getSemanticsData();
          if (data.hasAction(SemanticsAction.tap) && !node.isInvisible && !node.isMergedIntoParent) {
            final size = node.rect.size;
            expect(size.width, greaterThanOrEqualTo(44), reason: data.label);
            expect(size.height, greaterThanOrEqualTo(44), reason: data.label);
          }
          node.visitChildren((child) {
            visit(child);
            return true;
          });
        }

        visit(root);

        // Computed contrast of every visible text colour against the page background.
        final paragraphs = tester.allRenderObjects.whereType<RenderParagraph>().where((p) => p.attached && p.hasSize);
        expect(paragraphs, isNotEmpty);
        for (final p in paragraphs) {
          final style = p.text.style;
          final color = style?.color ?? DanaviewColors.textPrimary;
          if (p.text.toPlainText().trim().isEmpty) continue;
          // Icons are glyphs of the icon font; everything else is chrome text in Figtree.
          final family = style?.fontFamily ?? '';
          if (family == 'MaterialIcons') continue;
          expect(family, contains('Figtree'), reason: p.text.toPlainText());
          expect(_contrast(color, DanaviewColors.background), greaterThanOrEqualTo(4.5), reason: p.text.toPlainText());
        }

        // Rows announce their state.
        expect(expanded('mpv'), isTrue);
        expect(tester.takeException(), isNull);
        handle.dispose();
        await _finish(tester, env);
      });
    }
  });

  group('no overflow', () {
    const sizes = [
      Size(280, 500),
      Size(320, 568),
      Size(360, 740),
      Size(390, 844),
      Size(568, 320),
      Size(844, 390),
      Size(834, 1194),
      Size(1280, 800),
    ];
    for (final size in sizes) {
      for (final scale in [0.85, 1.0, 1.35]) {
        testWidgets('$size @$scale with long rows open', (tester) async {
          final env = await _pump(tester, surface: TestSurface(size, scale));
          for (final name in ['mpv', 'OpenAI Whisper speech models', figtreeAppFontLicensePackage]) {
            await _show(tester, name);
            await tester.tap(find.text(name));
            await tester.pump();
            expect(tester.takeException(), isNull, reason: name);
          }
          // Scroll through to the end of the list.
          await _show(tester, 'Pacifico (video editor content font)');
          await tester.drag(_list, const Offset(0, -100000));
          await tester.pump();
          expect(tester.takeException(), isNull);
          final view = tester.view.physicalSize / tester.view.devicePixelRatio;
          final title = tester.getRect(find.text('Open-source licences'));
          expect(title.left, greaterThanOrEqualTo(0));
          expect(title.right, lessThanOrEqualTo(view.width));
          await _finish(tester, env);
        });
      }
    }
  });
}
