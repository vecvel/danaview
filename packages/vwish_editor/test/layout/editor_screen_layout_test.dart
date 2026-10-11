// OWNER: UX-07
//
// EditorScreen with the region placeholders (D-33) in every layout kind (ux.md §6.3): each region
// widget sits exactly at its EditorLayoutSpec rect, the scaffold resolves the same spec as the pure
// planner, the ladder's visible effects (transport in the top bar, hidden preview) happen, nothing
// overflows and the owner UI rules hold. Plus the splitter (persisted per kind, reset, semantics),
// the opening and unavailable states and the rebuild contract (ux.md §16.6).

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/editor_prefs.dart';
import 'package:vwish_editor/src/app/editor_providers.dart';
import 'package:vwish_editor/src/debug/rebuild_counters.dart';
import 'package:vwish_editor/src/editor/editor_screen.dart';
import 'package:vwish_editor/src/editor/inspector/inspector_dock.dart';
import 'package:vwish_editor/src/editor/inspector/inspector_host.dart';
import 'package:vwish_editor/src/editor/layout/editor_layout.dart';
import 'package:vwish_editor/src/editor/layout/editor_scaffold.dart';
import 'package:vwish_editor/src/editor/layout/editor_shell_strings.dart';
import 'package:vwish_editor/src/editor/layout/editor_splitter.dart';
import 'package:vwish_editor/src/editor/layout/editor_top_bar.dart';
import 'package:vwish_editor/src/editor/preview/preview_region.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_view.dart';
import 'package:vwish_editor/src/editor/toolbar/tool_rail.dart';
import 'package:vwish_editor/src/editor/toolbar/tool_strip.dart';
import 'package:vwish_editor/src/editor/transport/transport_bar.dart';
import 'package:vwish_editor_core/model.dart' show ProjectId;
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../support/support.dart';
import 'fake_editor_shell.dart';

/// One layout case: a surface, whether the inspector is open, and what the planner must pick.
typedef _Case = ({String name, EditorSurface surface, bool open, EditorLayoutKind kind, Set<DegradeStep> steps});

const List<_Case> _cases = [
  (
    name: 'phone portrait',
    surface: EditorSurface(Size(390, 844)),
    open: false,
    kind: EditorLayoutKind.compactPortrait,
    steps: {DegradeStep.none}
  ),
  (
    name: 'phone portrait, inspector docked',
    surface: EditorSurface(Size(390, 844)),
    open: true,
    kind: EditorLayoutKind.compactPortrait,
    steps: {DegradeStep.none}
  ),
  (
    name: 'phone portrait, docked + keyboard',
    surface: EditorSurface(Size(390, 844), keyboardFraction: 0.4, platform: TargetPlatform.iOS),
    open: true,
    kind: EditorLayoutKind.compactPortrait,
    steps: {DegradeStep.none},
  ),
  (name: 'narrowest', surface: SurfaceMatrix.narrowest, open: false, kind: EditorLayoutKind.compactPortrait, steps: {DegradeStep.none}),
  (
    name: 'narrowest, docked',
    surface: SurfaceMatrix.narrowest,
    open: true,
    kind: EditorLayoutKind.compactPortrait,
    steps: {DegradeStep.previewReduced}
  ),
  (
    name: 'narrowest, docked + keyboard',
    surface: EditorSurface(Size(280, 500), textScale: 1.35, keyboardFraction: 0.4),
    open: true,
    kind: EditorLayoutKind.compactPortrait,
    steps: {DegradeStep.previewHidden},
  ),
  (
    name: 'phone landscape',
    surface: EditorSurface(Size(844, 390)),
    open: false,
    kind: EditorLayoutKind.compactLandscape,
    steps: {DegradeStep.none}
  ),
  (
    name: 'phone landscape, inspector',
    surface: EditorSurface(Size(844, 390)),
    open: true,
    kind: EditorLayoutKind.compactLandscape,
    steps: {DegradeStep.none}
  ),
  (
    name: 'small landscape @1.35',
    surface: EditorSurface(Size(568, 320), textScale: 1.35),
    open: false,
    kind: EditorLayoutKind.compactLandscape,
    steps: {DegradeStep.previewReduced},
  ),
  (
    name: 'small landscape + keyboard',
    surface: EditorSurface(Size(568, 320), textScale: 1.35, keyboardFraction: 0.4),
    open: true,
    kind: EditorLayoutKind.compactLandscape,
    steps: {DegradeStep.previewHidden},
  ),
  (
    name: 'tablet portrait',
    surface: EditorSurface(Size(834, 1194), platform: TargetPlatform.iOS),
    open: false,
    kind: EditorLayoutKind.medium,
    steps: {DegradeStep.none}
  ),
  (
    name: 'tablet portrait, inspector',
    surface: EditorSurface(Size(744, 1133), textScale: 1.35, platform: TargetPlatform.iOS),
    open: true,
    kind: EditorLayoutKind.medium,
    steps: {DegradeStep.none},
  ),
  (
    name: 'tablet landscape',
    surface: EditorSurface(Size(1194, 834), platform: TargetPlatform.iOS),
    open: false,
    kind: EditorLayoutKind.expanded,
    steps: {DegradeStep.none}
  ),
  (
    name: 'tablet landscape, inspector + keyboard',
    surface: EditorSurface(Size(1133, 744), keyboardFraction: 0.4, platform: TargetPlatform.iOS),
    open: true,
    kind: EditorLayoutKind.expanded,
    steps: {DegradeStep.none},
  ),
  (
    name: 'desktop-class pointer',
    surface: EditorSurface(Size(1280, 800), textScale: 0.85, platform: TargetPlatform.macOS),
    open: false,
    kind: EditorLayoutKind.expanded,
    steps: {DegradeStep.none},
  ),
];

Future<(EditorTestHarness, FakeEditorShell)> _pump(WidgetTester tester, EditorSurface surface,
    {bool open = false, EditorPrefs? prefs}) async {
  final shell = FakeEditorShell(
    status: EditorShellStatus(
      phase: EditorShellPhase.ready,
      projectName: 'Goa trip with a very long name that must ellipsize in the title button',
      inspectorOpen: open,
    ),
  );
  final h = EditorTestHarness(prefs: prefs, overrides: [overrideShell(shell)]);
  await h.pumpEditor(tester, surface: surface);
  return (h, shell);
}

void _expectRect(WidgetTester tester, Finder finder, Rect expected, String what) {
  expect(finder, findsOneWidget, reason: what);
  final rect = tester.getRect(finder);
  expect(rect.left, moreOrLessEquals(expected.left), reason: '$what $rect != $expected');
  expect(rect.top, moreOrLessEquals(expected.top), reason: '$what $rect != $expected');
  expect(rect.right, moreOrLessEquals(expected.right), reason: '$what $rect != $expected');
  expect(rect.bottom, moreOrLessEquals(expected.bottom), reason: '$what $rect != $expected');
}

/// Every region widget is where the spec puts it.
void _expectRegionsPlaced(WidgetTester tester, EditorLayoutSpec spec, EditorSurface surface) {
  _expectRect(tester, find.byType(EditorTopBar), spec.rectOf(EditorRegion.topBar)!, 'top bar');
  if (spec.shows(EditorRegion.preview)) {
    _expectRect(tester, find.byType(PreviewRegion), spec.rectOf(EditorRegion.preview)!, 'preview');
  } else {
    expect(find.byType(PreviewRegion), findsNothing);
  }
  if (spec.shows(EditorRegion.transport)) {
    _expectRect(tester, find.byType(TransportBar), spec.rectOf(EditorRegion.transport)!, 'transport');
  } else if (spec.transportInTopBar) {
    expect(find.descendant(of: find.byType(EditorTopBar), matching: find.byType(TransportBar)), findsOneWidget);
  }
  _expectRect(tester, find.byType(TimelineView), spec.rectOf(EditorRegion.timeline)!, 'timeline');
  if (spec.shows(EditorRegion.toolStrip)) {
    _expectRect(tester, find.byType(ToolStrip), spec.rectOf(EditorRegion.toolStrip)!, 'tool strip');
  } else {
    expect(find.byType(ToolStrip), findsNothing);
  }
  switch (spec.kind) {
    case EditorLayoutKind.compactPortrait:
      expect(find.byType(ToolRail), findsNothing);
      expect(find.byType(InspectorHost), findsNothing);
      if (spec.inspectorOpen) {
        final dock = spec.rectOf(EditorRegion.dock)!;
        final rect = tester.getRect(find.byType(InspectorDock));
        // The dock slot reaches the screen bottom (the panel lifts itself above the keyboard).
        expect(rect.top, moreOrLessEquals(dock.top));
        expect(rect.bottom, moreOrLessEquals(surface.size.height));
        expect(rect.width, moreOrLessEquals(dock.width));
      } else {
        expect(find.byType(InspectorDock), findsNothing);
      }
    case EditorLayoutKind.compactLandscape || EditorLayoutKind.medium:
      final pane = spec.rectOf(EditorRegion.pane)!;
      _expectRect(tester, spec.inspectorOpen ? find.byType(InspectorHost) : find.byType(ToolRail), pane, 'side pane');
      expect(spec.inspectorOpen ? find.byType(ToolRail) : find.byType(InspectorHost), findsNothing);
    case EditorLayoutKind.expanded:
      _expectRect(tester, find.byType(ToolRail), spec.rectOf(EditorRegion.rail)!, 'rail');
      _expectRect(tester, find.byType(InspectorHost), spec.rectOf(EditorRegion.pane)!, 'pane');
  }
  if (spec.shows(EditorRegion.splitter)) {
    final slop = spec.touch ? EditorScaffold.splitterTouchSlop : 0.0;
    final r = spec.rectOf(EditorRegion.splitter)!;
    _expectRect(tester, find.byType(EditorSplitter), Rect.fromLTRB(r.left, r.top - slop, r.right, r.bottom + slop), 'splitter');
  } else {
    expect(find.byType(EditorSplitter), findsNothing);
  }
}

void main() {
  setUp(() => EditorRebuildCounters.reset());

  group('each layout with placeholders', () {
    for (final c in _cases) {
      testWidgets('${c.name} [${c.surface}]', (tester) async {
        await _pump(tester, c.surface, open: c.open);
        final spec = specOf(tester);
        expect(spec.kind, c.kind);
        expect(c.steps, contains(spec.degrade), reason: '$spec');
        expect(spec.fitsMinimums, isTrue);
        // The scaffold feeds the planner exactly what the screen has.
        expect(
          spec,
          EditorLayoutSpec.resolve(
            size: c.surface.size,
            padding: EdgeInsets.zero,
            viewInsets: EdgeInsets.only(bottom: c.surface.keyboardInset),
            textScaler: TextScaler.linear(c.surface.textScale),
            touch: c.surface.touch,
            inspectorOpen: c.open,
          ),
        );
        _expectRegionsPlaced(tester, spec, c.surface);
        expectNoOverflow(tester);
        expectOwnerUiRules(tester);
        expectInside(tester, find.byType(EditorTopBar));
      });
    }

    testSurfaces('PR matrix, inspector closed and open: no overflow, regions placed', (tester, surface) async {
      for (final open in [false, true]) {
        await _pump(tester, surface, open: open);
        _expectRegionsPlaced(tester, specOf(tester), surface);
        expectNoOverflow(tester);
        expectOwnerUiRules(tester);
      }
    });

    testWidgets('a safe area keeps every region clear of the notch and the home indicator', (tester) async {
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      await _pump(tester, const EditorSurface(Size(390, 844)));
      final spec = specOf(tester);
      expect(spec.padding, const EdgeInsets.only(top: 47, bottom: 34));
      expect(spec.rectOf(EditorRegion.topBar)!.top, 47);
      expect(spec.rectOf(EditorRegion.toolStrip)!.bottom, 844 - 34);
      _expectRegionsPlaced(tester, spec, const EditorSurface(Size(390, 844)));
      // Regions see no padding of their own (the planner already applied it).
      expect(MediaQuery.paddingOf(tester.element(find.byType(TimelineView))), EdgeInsets.zero);
      expectNoOverflow(tester);
    });
  });

  group('rotation and ladder transitions keep region state', () {
    testWidgets('portrait -> landscape keeps the preview and timeline elements', (tester) async {
      await _pump(tester, const EditorSurface(Size(390, 844)));
      final preview = tester.element(find.byType(PreviewRegion));
      final timeline = tester.element(find.byType(TimelineView));
      tester.view.physicalSize = const Size(844, 390);
      await tester.pump();
      expect(specOf(tester).kind, EditorLayoutKind.compactLandscape);
      expect(identical(tester.element(find.byType(PreviewRegion)), preview), isTrue);
      expect(identical(tester.element(find.byType(TimelineView)), timeline), isTrue);
      expectNoOverflow(tester);
    });

    testWidgets('the transport keeps its element when it moves into the top bar (step 4) and back', (tester) async {
      final (_, shell) = await _pump(tester, SurfaceMatrix.narrowest, open: true);
      final transport = tester.element(find.byType(TransportBar));
      expect(specOf(tester).transportInTopBar, isFalse);
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      await tester.pump();
      expect(specOf(tester).transportInTopBar, isTrue);
      expect(find.descendant(of: find.byType(EditorTopBar), matching: find.byType(TransportBar)), findsOneWidget);
      expect(identical(tester.element(find.byType(TransportBar)), transport), isTrue);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      expect(specOf(tester).transportInTopBar, isFalse);
      expect(identical(tester.element(find.byType(TransportBar)), transport), isTrue);
      expect(shell.calls, ['open']);
      expectNoOverflow(tester);
    });
  });

  group('splitter (ux.md §6.5)', () {
    testWidgets('dragging resizes preview and timeline and persists the ratio for the kind', (tester) async {
      final prefs = EditorPrefs.memory();
      await _pump(tester, const EditorSurface(Size(390, 844)), prefs: prefs);
      final before = specOf(tester);
      final g = await tester.startGesture(tester.getCenter(find.byType(EditorSplitter)));
      await g.moveBy(const Offset(0, 30));
      await tester.pump();
      await g.moveBy(const Offset(0, 60));
      await tester.pump();
      final during = specOf(tester);
      expect(during.previewHeight, greaterThan(before.previewHeight));
      expect(prefs.splitRatio(EditorLayoutKind.compactPortrait.name), isNull, reason: 'persisted at the end of the drag');
      await g.up();
      await tester.pump(const Duration(milliseconds: 500));
      final after = specOf(tester);
      expect(after.previewHeight, during.previewHeight);
      expect(after.previewHeight + after.timelineHeight, before.previewHeight + before.timelineHeight);
      expect(prefs.splitRatio(EditorLayoutKind.compactPortrait.name), closeTo(after.splitRatio, 1e-9));
      expect(prefs.splitRatio(EditorLayoutKind.medium.name), isNull, reason: 'per kind');
      _expectRegionsPlaced(tester, after, const EditorSurface(Size(390, 844)));

      // A new editor opens with the persisted ratio.
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, const EditorSurface(Size(390, 844)), prefs: prefs);
      expect(specOf(tester).previewHeight, after.previewHeight);

      // The other kind keeps its own default.
      tester.view.physicalSize = const Size(834, 1194);
      await tester.pump();
      expect(specOf(tester).splitRatio, closeTo(EditorLayoutSpec.defaultSplitRatioFor(EditorLayoutKind.medium), 0.01));
      expectNoOverflow(tester);
    });

    testWidgets('dragging is clamped to the minimums', (tester) async {
      final prefs = EditorPrefs.memory();
      await _pump(tester, const EditorSurface(Size(390, 844)), prefs: prefs);
      await tester.drag(find.byType(EditorSplitter), const Offset(0, 2000));
      await tester.pump(const Duration(milliseconds: 500));
      var spec = specOf(tester);
      expect(spec.splitRatio, closeTo(spec.maxSplitRatio, 0.005));
      expect(spec.timelineHeight, greaterThanOrEqualTo(spec.timelineMinHeight));
      await tester.drag(find.byType(EditorSplitter), const Offset(0, -2000));
      await tester.pump(const Duration(milliseconds: 500));
      spec = specOf(tester);
      expect(spec.splitRatio, closeTo(spec.minSplitRatio, 0.005));
      expect(spec.previewHeight, greaterThanOrEqualTo(spec.previewMinHeight));
      expectNoOverflow(tester);
    });

    testWidgets('double-tap resets to the default and clears the preference', (tester) async {
      final prefs = EditorPrefs.memory();
      await prefs.setSplitRatio(EditorLayoutKind.compactPortrait.name, 0.65);
      await _pump(tester, const EditorSurface(Size(390, 844)), prefs: prefs);
      expect(specOf(tester).splitRatio, closeTo(0.65, 0.01));
      await tester.tap(find.byType(EditorSplitter));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.byType(EditorSplitter));
      await tester.pump(const Duration(milliseconds: 400));
      expect(specOf(tester).splitRatio, closeTo(0.5, 0.01));
      expect(prefs.splitRatio(EditorLayoutKind.compactPortrait.name), isNull);
    });

    testWidgets('semantics: an adjustable "Preview size" slider stepping 5 percent', (tester) async {
      final semantics = tester.ensureSemantics();
      final prefs = EditorPrefs.memory();
      await _pump(tester, const EditorSurface(Size(390, 844)), prefs: prefs);
      final node = find.semantics.byLabel(EditorShellStrings.splitter);
      expect(node, findsOne);
      expect(
          tester.getSemantics(find.byType(EditorSplitter)),
          matchesSemantics(
            label: EditorShellStrings.splitter,
            value: '50 percent',
            increasedValue: '55 percent',
            decreasedValue: '45 percent',
            isSlider: true,
            isFocusable: true,
            hasIncreaseAction: true,
            hasDecreaseAction: true,
          ));
      tester.semantics.performAction(node, SemanticsAction.increase);
      await tester.pump();
      expect(specOf(tester).splitRatio, closeTo(0.55, 0.005));
      expect(prefs.splitRatio(EditorLayoutKind.compactPortrait.name), closeTo(0.55, 0.005));
      semantics.dispose();
    });

    testWidgets('keyboard: Down/Up step the focused splitter', (tester) async {
      await _pump(tester, const EditorSurface(Size(1194, 834), platform: TargetPlatform.iOS));
      final start = specOf(tester).splitRatio;
      tester.widget<Focus>(find.descendant(of: find.byType(EditorSplitter), matching: find.byType(Focus)).first).focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(specOf(tester).splitRatio, closeTo(start + 0.05, 0.005));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(specOf(tester).splitRatio, closeTo(start, 0.005));
    });
  });

  group('phases', () {
    testWidgets('opening: the top bar and a progress indicator, no regions yet', (tester) async {
      final shell = FakeEditorShell(status: EditorShellStatus.opening);
      final h = EditorTestHarness(overrides: [overrideShell(shell)]);
      await h.pumpEditor(tester, surface: SurfaceMatrix.narrowest);
      expect(find.byType(VwishSpinner), findsOneWidget);
      expect(find.text(EditorShellStrings.opening), findsOneWidget);
      expect(find.byType(PreviewRegion), findsNothing);
      expect(find.byType(TimelineView), findsNothing);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      shell.status.value = const EditorShellStatus(phase: EditorShellPhase.ready, projectName: 'Goa trip');
      await tester.pump();
      expect(find.byType(VwishSpinner), findsNothing);
      expect(find.byType(PreviewRegion), findsOneWidget);
      expect(find.text('Goa trip'), findsOneWidget);
      expect(shell.count('open'), 1, reason: 'opened once, when the route entered');
    });

    testSurfaces('unknown project: "This project isn\'t available" with "Go to Projects"', (tester, surface) async {
      final h = EditorTestHarness();
      await h.pumpEditor(tester, projectId: ProjectId('pr_missing0000'), surface: surface);
      await tester.pump();
      expect(find.text(EditorShellStrings.unavailableTitle), findsOneWidget);
      expect(find.byType(EditorScaffold), findsNothing);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      // On screen without scrolling (labels may ellipsize with the square test font, never overflow).
      expectInside(tester, find.text(EditorShellStrings.goToProjects));
      expectInside(tester, find.text(EditorShellStrings.unavailableTitle));
      expectInside(tester, find.bySemanticsLabel(EditorShellStrings.closeEditor));
      await tester.tap(find.text(EditorShellStrings.goToProjects));
      await tester.pump();
      expect(h.openProjectsRequests, 1);
      expect(h.closeRequests, 0);
    });

    testWidgets('unknown project without a Projects route offers Close', (tester) async {
      final h = EditorTestHarness();
      applySurface(tester, SurfaceMatrix.phone);
      await tester.pumpWidget(h.app(EditorScreen(projectId: ProjectId('pr_missing0000'), onClose: () => h.closeRequests++)));
      await tester.pump();
      expect(find.text(EditorShellStrings.goToProjects), findsNothing);
      await tester.tap(find.text(EditorShellStrings.close));
      await tester.pump();
      expect(h.closeRequests, 1);
    });

    testWidgets('detached shell: resolves the name; a project deleted while open becomes unavailable', (tester) async {
      final h = EditorTestHarness(overrides: [
        editorShellProvider.overrideWith((ref, id) {
          final shell = DetachedEditorShell(id: id, repository: ref.watch(projectRepositoryProvider));
          ref.onDispose(shell.dispose);
          return shell;
        }),
      ]);
      final id = await h.pumpEditor(tester);
      await tester.pump();
      expect(find.text('Test project'), findsOneWidget, reason: 'the detached shell resolves the name');
      await h.repository.delete(id);
      await tester.pump();
      expect(find.text(EditorShellStrings.unavailableTitle), findsOneWidget);
    });

    testWidgets('failure: the controller\'s headline and next step, Close and Go to Projects', (tester) async {
      final shell = FakeEditorShell(
        status: const EditorShellStatus(
          phase: EditorShellPhase.failed,
          failureTitle: 'This project was made by a newer version',
          failureMessage: 'Update Vwish to open it.',
        ),
      );
      final h = EditorTestHarness(overrides: [overrideShell(shell)]);
      await h.pumpEditor(tester, surface: SurfaceMatrix.narrowest);
      expect(find.text('This project was made by a newer version'), findsOneWidget);
      expect(find.text('Update Vwish to open it.'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await tester.tap(find.bySemanticsLabel(EditorShellStrings.closeEditor));
      await tester.pump();
      expect(h.closeRequests, 1);
      expect(shell.calls, isNot(contains('flush')));
    });
  });

  group('rebuild contract (ux.md §16.6)', () {
    testWidgets('name, save status and history changes rebuild the top bar, not the scaffold', (tester) async {
      final (_, shell) = await _pump(tester, const EditorSurface(Size(390, 844)));
      final counts = await EditorRebuildCounters.record(() async {
        for (final save in EditorSaveIndicator.values) {
          shell.status.value =
              shell.status.value.copyWith(save: save, canUndo: true, undoLabel: 'Split clip', projectName: 'Renamed ${save.name}');
          await tester.pump();
        }
      });
      expect(counts['EditorScaffold'], isNull);
      expect(find.text('Renamed failed'), findsOneWidget);
    });

    testWidgets('opening the inspector re-plans the layout', (tester) async {
      final (_, shell) = await _pump(tester, const EditorSurface(Size(390, 844)));
      final counts = await EditorRebuildCounters.record(() async {
        shell.status.value = shell.status.value.copyWith(inspectorOpen: true);
        await tester.pump();
      });
      expect(counts['EditorScaffold'], 1);
      expect(specOf(tester).shows(EditorRegion.dock), isTrue);
      expect(find.byType(InspectorDock), findsOneWidget);
    });
  });
}
