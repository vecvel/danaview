// OWNER: UX-24
//
// The Filters & LUT panel (ux.md §10.7): the 12 built-in looks and None, look application and
// intensity, engine stills with swatch fallbacks, "My LUTs" (.cube import through the picker and the
// pool service, error copy with line numbers, rename, remove) and the surface matrix.

import 'dart:io';

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/app/strings/color_strings.dart';
import 'package:danaview_editor/src/editor/contracts/inspector_routes.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_header.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_rows.dart';
import 'package:danaview_editor/src/editor/inspector/keyframe_toggle.dart';
import 'package:danaview_editor/src/editor/panels/filters_panel.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show MediaPickKind, MediaPickSource;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';
import 'color_rig.dart';
import 'filters_support.dart';

const List<String> _names = [
  'None',
  'Teal & Orange',
  'Warm',
  'Cool',
  'Vivid',
  'Matte',
  'Fade',
  'Mono',
  'Noir',
  'Sepia',
  'Vintage',
  'Cinematic',
  'Pastel',
];

Finder tile(String key) => find.byKey(ValueKey<String>(key));

Finder get importButton => find.byKey(const ValueKey<String>('lut.import'));

Finder get intensityRow => find.widgetWithText(InspectorSliderRow, 'Intensity');

Finder get looksCarousel => find.byKey(const ValueKey<String>('looks.carousel'));

Finder get looksScroll => find.descendant(of: looksCarousel, matching: find.byType(SingleChildScrollView));

Finder get message => find.byKey(const ValueKey<String>('lut.message'));

bool selected(WidgetTester tester, String key) => tester.widget<DanaviewPressable>(find.descendant(of: tile(key), matching: find.byType(DanaviewPressable))).selected ?? false;

Future<void> tapTile(WidgetTester tester, String key) async {
  await tester.ensureVisible(tile(key));
  await tester.pump();
  await tester.tap(tile(key));
  await tester.pump();
}

Future<ColorRig> pumpFilters(
  WidgetTester tester, {
  EditorSurface surface = wideSurface,
  ItemId item = ColorIds.a,
  EditProject Function(FakeProjectRepository repo)? project,
  RecordingStills? stills,
  ApplyingPool? pool,
  List<PickedMedia> picks = const [],
}) async {
  late ColorRig rig;
  final pickerOverrides = [
    lutImporterProvider.overrideWith((ref) => LutImporter(picker: ref.watch(editorEngineProvider).picker, pool: pool ?? ApplyingPool())),
    if (stills != null) lookStillServiceProvider.overrideWithValue(stills),
  ];
  rig = await ColorRig.pump(tester, inspectorFrame, surface: surface, project: project, overrides: pickerOverrides);
  rig.engine.picker.nextPicks = picks;
  await rig.select(item);
  rig.editor.openInspector(FiltersInspector(item));
  await tester.pump();
  await tester.pump();
  return rig;
}

EditProject Function(FakeProjectRepository) withVisuals(Map<ItemId, VisualProps> visuals) => (repo) => colorProject(repo, visuals: visuals);

/// Lets real async (isolates, file I/O) run until [done] or five seconds pass.
Future<void> settle(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  await tester.pump();
  await tester.pump();
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('danaview_filters_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('looks carousel', () {
    testWidgets('None and the 12 built-in looks in the order of ux.md §10.7', (tester) async {
      await pumpFilters(tester);
      expect(find.descendant(of: find.byType(InspectorHeader), matching: find.text('Filters')), findsOneWidget);
      final shown = [for (final t in _names) find.text(t)];
      for (final f in shown) {
        expect(f, findsOneWidget);
      }
      final xs = [for (final f in shown) tester.getTopLeft(f).dx];
      expect(xs, orderedEquals([...xs]..sort()), reason: 'carousel order');
      expect([for (final l in BuiltinLooks.all) l.name], _names.skip(1));
      expect(selected(tester, 'look.none'), isTrue);
      expect(intensityRow, findsNothing, reason: 'no look, no intensity');
    });

    testWidgets('tapping a look applies SetLook in one entry; None removes it; the selection and intensity row follow', (tester) async {
      final rig = await pumpFilters(tester);
      await tapTile(tester, 'look.teal_orange');
      expect(rig.visual(ColorIds.a).look, const BuiltinLook('teal_orange'));
      expect(rig.entries, 1);
      expect(rig.undoLabel, 'Apply look');
      expect(selected(tester, 'look.teal_orange'), isTrue);
      expect(selected(tester, 'look.none'), isFalse);
      expect(intensityRow, findsOneWidget);
      await tapTile(tester, 'look.noir');
      expect(rig.visual(ColorIds.a).look, const BuiltinLook('noir'));
      expect(rig.entries, 2);
      await tapTile(tester, 'look.none');
      expect(rig.visual(ColorIds.a).look, isNull);
      expect(rig.undoLabel, 'Remove look');
      expect(intensityRow, findsNothing);
      rig.editor.undo();
      await tester.pump();
      expect(rig.visual(ColorIds.a).look, const BuiltinLook('noir'));
    });

    testWidgets('every one of the 12 looks applies its own preset id', (tester) async {
      final rig = await pumpFilters(tester);
      for (final info in BuiltinLooks.all) {
        await tapTile(tester, 'look.${info.id}');
        expect(rig.visual(ColorIds.a).look, BuiltinLook(info.id), reason: info.id);
      }
    });

    testWidgets('the intensity slider writes look.intensity and survives switching looks', (tester) async {
      final rig = await pumpFilters(tester, project: withVisuals({ColorIds.a: const VisualProps(look: BuiltinLook('warm'))}));
      final row = tester.widget<InspectorSliderRow>(intensityRow);
      expect((row.min, row.max, row.defaultValue, row.displayScale, row.unit), (0, 1, 1, 100, '%'));
      expect(find.descendant(of: intensityRow, matching: find.byType(KeyframeToggle)), findsNothing, reason: 'not keyframable in v1');
      final slider = find.descendant(of: intensityRow, matching: find.byType(DanaviewSlider));
      final g = await tester.startGesture(tester.getCenter(slider));
      for (var i = 0; i < 6; i++) {
        await g.moveBy(const Offset(-14, 0));
        await tester.pump();
      }
      await g.up();
      await tester.pump();
      await tester.pump();
      final intensity = (rig.visual(ColorIds.a).look as BuiltinLook).intensity;
      expect(intensity, lessThan(1));
      expect(rig.entries, 1);
      expect(rig.undoLabel, 'Change look intensity');
      await tapTile(tester, 'look.vivid');
      expect(rig.visual(ColorIds.a).look, BuiltinLook('vivid', intensity: intensity));
    });

    testWidgets('the header reset removes the look', (tester) async {
      final rig = await pumpFilters(tester, project: withVisuals({ColorIds.a: const VisualProps(look: BuiltinLook('warm', intensity: 0.4))}));
      await tester.tap(find.byTooltip(InspectorStrings.reset));
      await tester.pump();
      expect(rig.visual(ColorIds.a).look, isNull);
      expect(rig.entries, 1);
    });

    testWidgets('a locked lane disables the tiles and the import', (tester) async {
      final rig = await pumpFilters(tester, project: (repo) => colorProject(repo, lockMain: true));
      expect(find.text(ColorStrings.trackLocked), findsOneWidget);
      await tapTile(tester, 'look.warm');
      expect(rig.visual(ColorIds.a).look, isNull);
      expect(tester.widget<DanaviewButton>(importButton).onPressed, isNull);
    });

    testWidgets('re-targets with the selection', (tester) async {
      final rig = await pumpFilters(tester, project: withVisuals({ColorIds.b: const VisualProps(look: BuiltinLook('sepia'))}));
      expect(selected(tester, 'look.none'), isTrue);
      await rig.select(ColorIds.b);
      expect(rig.state.inspector, FiltersInspector(ColorIds.b));
      expect(selected(tester, 'look.sepia'), isTrue);
    });
  });

  group('thumbnails (renderLookStills)', () {
    testWidgets('asks for the 12 looks and the LUTs of the pool for the clip at the playhead; swatches until a still arrives', (tester) async {
      final stills = RecordingStills(stills: {'warm': tinyPng});
      await pumpFilters(tester, stills: stills);
      await tester.pump(const Duration(milliseconds: 10));
      expect(stills.requests, hasLength(1));
      final (item, ids, height) = stills.requests.single;
      expect(item, ColorIds.a);
      expect(ids, [...BuiltinLooks.all.map((l) => l.id), ColorIds.lut]);
      expect(height, FiltersPanel.stillHeightPx);
      expect(find.descendant(of: tile('look.warm'), matching: find.byType(Image)), findsOneWidget);
      expect(find.descendant(of: tile('look.cool'), matching: find.byType(Image)), findsNothing);
      expect(find.descendant(of: tile('look.cool'), matching: find.byType(DecoratedBox)), findsWidgets, reason: 'the swatch');
    });

    testWidgets('a failing renderer leaves the swatches and nothing else', (tester) async {
      await pumpFilters(tester, stills: RecordingStills(fail: true));
      await tester.pump(const Duration(milliseconds: 10));
      expectNoOverflow(tester);
      expect(find.byType(Image), findsNothing);
      await tapTile(tester, 'look.warm');
    });

    testWidgets('without a renderer (no engine runtime) the swatches show', (tester) async {
      await pumpFilters(tester);
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.byType(Image), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('the playhead settling re-renders once; no request when the playhead leaves the clip', (tester) async {
      final stills = RecordingStills();
      final rig = await pumpFilters(tester, stills: stills);
      await tester.pump(const Duration(milliseconds: 10));
      expect(stills.requests, hasLength(1));
      // The seek notifies from real async, so its debounce timer is a real one: wait it out.
      Future<void> quiet() async {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
        await tester.pump();
        await tester.pump();
      }

      await rig.seek(f(30));
      await quiet();
      expect(stills.requests, hasLength(2));
      await rig.seek(f(36));
      await rig.seek(f(40));
      await quiet();
      expect(stills.requests, hasLength(3), reason: 'rapid seeks coalesce into one request');
      await rig.seek(6 * s);
      await quiet();
      expect(stills.requests, hasLength(3), reason: 'clip A ends at 4 s');
    });
  });

  group('My LUTs', () {
    testWidgets('lists the pool\'s LUTs by name without the extension; a hint before the first import', (tester) async {
      await pumpFilters(tester);
      expect(find.text('Film'), findsOneWidget);
      expect(find.text('Film.cube'), findsNothing);
      expect(find.text(ColorStrings.noLuts), findsNothing);
    });

    testWidgets('a hint shows before the first import', (tester) async {
      await pumpFilters(tester, project: (repo) => colorProject(repo, withLut: false));
      expect(find.text(ColorStrings.noLuts), findsOneWidget);
    });

    testWidgets('tapping a LUT applies ImportedLut with the current intensity', (tester) async {
      final rig = await pumpFilters(tester, project: withVisuals({ColorIds.a: const VisualProps(look: BuiltinLook('warm', intensity: 0.5))}));
      await tapTile(tester, 'lut.${ColorIds.lut}');
      expect(rig.visual(ColorIds.a).look, ImportedLut(ColorIds.lut, intensity: 0.5));
      expect(selected(tester, 'lut.${ColorIds.lut}'), isTrue);
      expect(selected(tester, 'look.warm'), isFalse);
    });

    testWidgets('import: picker, parse, pool, then the LUT is the clip\'s look and a tile', (tester) async {
      final pool = ApplyingPool(name: 'Sunset.cube');
      final pick = writePick(tmp, 'Sunset.cube', identityCube);
      final rig = await pumpFilters(tester, pool: pool, picks: [pick]);
      await tester.tap(importButton);
      await tester.pump();
      expect(tester.widget<DanaviewButton>(importButton).label, ColorStrings.importing);
      await settle(tester, () => rig.visual(ColorIds.a).look != null);
      final look = rig.visual(ColorIds.a).look;
      expect(look, isA<ImportedLut>());
      expect(rig.engine.picker.requests.single.kinds, {MediaPickKind.lut});
      expect(rig.engine.picker.requests.single.source, MediaPickSource.files);
      expect(pool.imported.single.displayName, 'Sunset.cube');
      final asset = rig.project.pool[(look! as ImportedLut).lut]!;
      expect((asset.kind, asset.ownership), (MediaKind.lut, MediaOwnership.projectOwned));
      expect(find.text('Sunset'), findsOneWidget);
      expect(find.text(ColorStrings.lutAdded('Sunset')), findsOneWidget);
      expect(tester.widget<DanaviewButton>(importButton).label, ColorStrings.importCube);
      expect(message, findsNothing);
      expect(rig.entries, 1, reason: 'the import itself is sticky; applying the look is one entry');
    });

    testWidgets('a bad file says why with its line and changes nothing', (tester) async {
      final pool = ApplyingPool();
      final rig = await pumpFilters(tester, pool: pool, picks: [writePick(tmp, 'Broken.cube', brokenCube)]);
      await tester.tap(importButton);
      await tester.pump();
      await settle(tester, () => message.evaluate().isNotEmpty);
      expect(find.descendant(of: message, matching: find.text('This LUT couldn\'t be read (line 5: expected 3 numbers).')), findsOneWidget);
      expect(pool.imported, isEmpty, reason: 'a file that does not parse never reaches the pool');
      expect(rig.visual(ColorIds.a).look, isNull);
      expect(rig.entries, 0);
      // The message is dismissable and the button works again.
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      expect(message, findsNothing);
      expect(tester.widget<DanaviewButton>(importButton).onPressed, isNotNull);
    });

    testWidgets('an error message keeps the neutral hairline; the error reads from its icon and text', (tester) async {
      await pumpFilters(tester, picks: [writePick(tmp, 'Broken.cube', brokenCube)]);
      await tester.tap(importButton);
      await tester.pump();
      await settle(tester, () => message.evaluate().isNotEmpty);
      final box = tester.widget<Container>(message).decoration! as BoxDecoration;
      expect(box.border, const Border.fromBorderSide(DanaviewBorders.hairline), reason: 'no red outline');
      expect(tester.widget<Icon>(find.descendant(of: message, matching: find.byType(Icon)).first).color, DanaviewColors.errorLight);
      expectNeutralBorders(tester, of: message);
    });

    testWidgets('an oversize LUT says what is supported', (tester) async {
      await pumpFilters(tester, picks: [writePick(tmp, 'Big.cube', oversizeCube)]);
      await tester.tap(importButton);
      await tester.pump();
      await settle(tester, () => message.evaluate().isNotEmpty);
      expect(find.descendant(of: message, matching: find.text('LUTs up to 65×65×65 are supported.')), findsOneWidget);
    });

    testWidgets('the service\'s own rejections have copy too', (tester) async {
      final cases = {
        'lutInvalid': ColorStrings.lutUnreadable(),
        'diskFull': ColorStrings.lutDiskFull,
        'notFound': ColorStrings.lutCannotOpen,
        'io': ColorStrings.lutFailed,
      };
      for (final MapEntry(key: reason, value: copy) in cases.entries) {
        final pool = ApplyingPool(reject: reason);
        await pumpFilters(tester, pool: pool, picks: [writePick(tmp, 'Ok.cube', identityCube)]);
        await tester.tap(importButton);
        await tester.pump();
        await settle(tester, () => message.evaluate().isNotEmpty);
        expect(find.descendant(of: message, matching: find.text(copy)), findsOneWidget, reason: reason);
      }
    });

    testWidgets('a dismissed picker is silent', (tester) async {
      final pool = ApplyingPool();
      final rig = await pumpFilters(tester, pool: pool);
      await tester.tap(importButton);
      await tester.pump();
      await settle(tester, () => tester.widget<DanaviewButton>(importButton).label == ColorStrings.importCube);
      expect(message, findsNothing);
      expect(pool.imported, isEmpty);
      expect(rig.entries, 0);
    });

    testWidgets('a 1D LUT\'s conversion notice is shown after the import', (tester) async {
      final text = StringBuffer('LUT_1D_SIZE 4\n');
      for (var i = 0; i < 4; i++) {
        final v = i / 3;
        text.writeln('$v $v $v');
      }
      final rig = await pumpFilters(tester, picks: [writePick(tmp, 'Curve.cube', text.toString())]);
      await tester.tap(importButton);
      await tester.pump();
      await settle(tester, () => rig.visual(ColorIds.a).look != null);
      expect(find.descendant(of: message, matching: find.textContaining('33×33×33')), findsOneWidget);
    });

    testWidgets('long press opens Rename and Remove from project', (tester) async {
      await pumpFilters(tester);
      await tester.ensureVisible(tile('lut.${ColorIds.lut}'));
      await tester.longPress(tile('lut.${ColorIds.lut}'));
      await tester.pumpAndSettle();
      expect(find.text(ColorStrings.rename), findsOneWidget);
      expect(find.text(ColorStrings.removeFromProject), findsOneWidget);
    });

    testWidgets('rename updates the asset (not history) and the tile', (tester) async {
      final rig = await pumpFilters(tester);
      await tester.ensureVisible(tile('lut.${ColorIds.lut}'));
      await tester.longPress(tile('lut.${ColorIds.lut}'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(ColorStrings.rename));
      await tester.pumpAndSettle();
      expect(find.text(ColorStrings.renameTitle), findsOneWidget);
      await tester.enterText(find.byType(EditableText), '  Warm film  ');
      await tester.tap(find.widgetWithText(DanaviewButton, ColorStrings.renameConfirm));
      await tester.pumpAndSettle();
      expect(rig.project.pool[ColorIds.lut]!.displayName, 'Warm film');
      expect(find.text('Warm film'), findsOneWidget);
      expect(find.text('Film'), findsNothing);
      expect(rig.entries, 0);
    });

    testWidgets('remove asks, clears the look from the clips that use it, then removes the asset; cancel keeps everything', (tester) async {
      final rig = await pumpFilters(tester, project: withVisuals({
        ColorIds.a: ImportedLutVisual.of(ColorIds.lut),
        ColorIds.c: ImportedLutVisual.of(ColorIds.lut),
        ColorIds.b: const VisualProps(look: BuiltinLook('warm')),
      }));
      Future<void> openRemove() async {
        await tester.ensureVisible(tile('lut.${ColorIds.lut}'));
        await tester.longPress(tile('lut.${ColorIds.lut}'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(ColorStrings.removeFromProject));
        await tester.pumpAndSettle();
      }

      await openRemove();
      expect(find.text(ColorStrings.removeTitle('Film')), findsOneWidget);
      expect(find.text(ColorStrings.removeMessage(2)), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(rig.project.pool.contains(ColorIds.lut), isTrue);
      expect(rig.entries, 0);

      await openRemove();
      await tester.tap(find.widgetWithText(DanaviewButton, ColorStrings.removeConfirm));
      await tester.pumpAndSettle();
      expect(rig.project.pool.contains(ColorIds.lut), isFalse);
      expect(rig.visual(ColorIds.a).look, isNull);
      expect(rig.visual(ColorIds.c).look, isNull);
      expect(rig.visual(ColorIds.b).look, const BuiltinLook('warm'), reason: 'other looks stay');
      expect(rig.entries, 2, reason: 'clearing the looks, then the pool edit');
      expect(find.text('Film'), findsNothing);
      expect(find.text(ColorStrings.noLuts), findsOneWidget);
      rig.editor.undo();
      await tester.pump();
      expect(rig.project.pool.contains(ColorIds.lut), isTrue);
    });

    testWidgets('an unused LUT is removed in one entry with the short message', (tester) async {
      final rig = await pumpFilters(tester);
      await tester.ensureVisible(tile('lut.${ColorIds.lut}'));
      await tester.longPress(tile('lut.${ColorIds.lut}'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(ColorStrings.removeFromProject));
      await tester.pumpAndSettle();
      expect(find.text(ColorStrings.removeMessage(0)), findsOneWidget);
      await tester.tap(find.widgetWithText(DanaviewButton, ColorStrings.removeConfirm));
      await tester.pumpAndSettle();
      expect(rig.project.pool.contains(ColorIds.lut), isFalse);
      expect(rig.entries, 1);
    });

    testWidgets('assistive technology gets Rename and Remove as custom actions', (tester) async {
      await pumpFilters(tester);
      final handle = tester.ensureSemantics();
      final node = tester.getSemantics(find.descendant(of: tile('lut.${ColorIds.lut}'), matching: find.byType(DanaviewPressable)).first);
      var current = node;
      SemanticsNode? withActions;
      void walk(SemanticsNode n) {
        final labels = [for (final id in (n.getSemanticsData().customSemanticsActionIds ?? const <int>[])) CustomSemanticsAction.getAction(id)?.label];
        if (labels.contains(ColorStrings.rename) && labels.contains(ColorStrings.removeFromProject)) withActions = n;
        n.visitChildren((c) {
          walk(c);
          return true;
        });
      }

      while (current.parent != null && current.parent!.parent != null) {
        current = current.parent!;
      }
      walk(current);
      expect(withActions, isNotNull);
      handle.dispose();
    });
  });

  group('looks strip polish (owner screenshots 4/5)', () {
    Finder ring(String key) => find.descendant(of: tile(key), matching: find.byKey(const ValueKey<String>('look.ring')));
    Finder picture(String key) => find.descendant(of: tile(key), matching: find.byType(ClipRRect));

    testWidgets('the selection ring sits outside the clipped picture with matching, uncut corners', (tester) async {
      final rig = await pumpFilters(tester);
      await tapTile(tester, 'look.teal_orange');
      expect(rig.visual(ColorIds.a).look, const BuiltinLook('teal_orange'));
      final box = tester.widget<DecoratedBox>(ring('look.teal_orange')).decoration as BoxDecoration;
      final border = box.border! as Border;
      expect(border.top.color, DanaviewColors.primaryLight);
      expect(border.top.width, DanaviewSpacing.xxs);
      const inset = DanaviewSpacing.xxs * 2;
      expect(box.borderRadius, const BorderRadius.all(Radius.circular(DanaviewRadius.md + inset)), reason: 'concentric with the picture');
      // The ring is not inside any clip of the tile (the old ring was cut by the picture's clip).
      expect(find.ancestor(of: ring('look.teal_orange'), matching: find.byType(ClipRRect)), findsNothing);
      expect(find.descendant(of: ring('look.teal_orange'), matching: find.byType(ClipRRect)), findsOneWidget);
      final ringRect = tester.getRect(ring('look.teal_orange'));
      final picRect = tester.getRect(picture('look.teal_orange'));
      expect(ringRect.left, closeTo(picRect.left - inset, 0.01));
      expect(ringRect.top, closeTo(picRect.top - inset, 0.01));
      expect(ringRect.right, closeTo(picRect.right + inset, 0.01));
      expect(ringRect.bottom, closeTo(picRect.bottom + inset, 0.01));
      expect(picRect.size, const Size(88, 56));
      // Unselected tiles reserve the ring's room with a transparent ring (no layout shift).
      final other = (tester.widget<DecoratedBox>(ring('look.warm')).decoration as BoxDecoration).border! as Border;
      expect(other.top.color.a, 0);
      expect(tester.getSize(ring('look.warm')), ringRect.size);
    });

    testWidgets('rings never overlap the neighbouring tile', (tester) async {
      await pumpFilters(tester);
      final keys = ['look.none', for (final l in BuiltinLooks.all.take(4)) 'look.${l.id}'];
      for (var i = 1; i < keys.length; i++) {
        final prev = tester.getRect(ring(keys[i - 1]));
        final next = tester.getRect(ring(keys[i]));
        expect(next.left - prev.right, greaterThanOrEqualTo(DanaviewSpacing.xs), reason: '${keys[i - 1]} | ${keys[i]}');
      }
    });

    testWidgets('tiles have no press or hover effect; selection stays in semantics', (tester) async {
      await pumpFilters(tester);
      final p = tester.widget<DanaviewPressable>(find.descendant(of: tile('look.none'), matching: find.byType(DanaviewPressable)));
      expect(p.selected, isTrue);
      await expectNoHoverOrPressEffect(tester, tile('look.warm'), what: 'look tile');
      await expectNoHoverOrPressEffect(tester, tile('look.none'), what: 'selected look tile');
    });

    testWidgets('the strip spans the panel and clips to it, so scrolled tiles never paint over the rail or the preview', (tester) async {
      await pumpFilters(tester);
      final panel = tester.getRect(find.byType(FiltersPanel));
      final strip = tester.getRect(looksCarousel);
      expect(strip.left, closeTo(panel.left, 0.01));
      expect(strip.right, closeTo(panel.right, 0.01));
      expect(tester.widget<SingleChildScrollView>(looksScroll).clipBehavior, Clip.hardEdge);
      // The first picture lines up with the panel's 16 px content inset.
      expect(tester.getRect(picture('look.none')).left, closeTo(panel.left + DanaviewSpacing.lg, 0.01));
      // Scroll to the end: None leaves the strip and the viewport clips it.
      await tester.ensureVisible(tile('look.pastel'));
      await tester.pump();
      expect(tester.getRect(tile('look.none')).right, lessThan(strip.left));
      expect(tester.getRect(tile('look.pastel')).right, lessThanOrEqualTo(strip.right + 0.01));
    });

    testSurfaces('the strips stay inside the panel at every surface', (tester, surface) async {
      final rig = await ColorRig.pump(tester, inspectorFrame,
          surface: surface, project: withVisuals({ColorIds.a: const VisualProps(look: BuiltinLook('warm'))}));
      await rig.select(ColorIds.a);
      rig.editor.openInspector(FiltersInspector(ColorIds.a));
      await tester.pump();
      await tester.pump();
      final panel = tester.getRect(find.byType(FiltersPanel));
      final strip = tester.getRect(looksCarousel);
      expect(strip.left, greaterThanOrEqualTo(panel.left - 0.01));
      expect(strip.right, lessThanOrEqualTo(panel.right + 0.01));
      expect(tester.widget<SingleChildScrollView>(looksScroll).clipBehavior, Clip.hardEdge);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });
  });

  group('matrix (ARCH §17.9)', () {
    testSurfaces('the carousels, intensity and import fit', (tester, surface) async {
      final rig = await ColorRig.pump(tester, inspectorFrame, surface: surface, project: withVisuals({ColorIds.a: const VisualProps(look: BuiltinLook('warm'))}));
      await rig.select(ColorIds.a);
      rig.editor.openInspector(FiltersInspector(ColorIds.a));
      await tester.pump();
      await tester.pump();
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await tester.ensureVisible(importButton);
      await tester.pump();
      expectNoOverflow(tester);
      expectInside(tester, importButton);
      await tester.ensureVisible(tile('look.pastel'));
      await tester.pump();
      expectNoOverflow(tester);
    });
  });
}

/// A look that is the LUT [lut].
abstract final class ImportedLutVisual {
  /// Visual props with [lut] as the look.
  static VisualProps of(MediaId lut) => VisualProps(look: ImportedLut(lut));
}
