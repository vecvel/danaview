// OWNER: UX-16
//
// A rig for the toolbar and inspector widget tests: the editor harness with a real
// EditorController opened on a seeded project over FakeEditorEngine, a manual playhead ticker, and
// `RegionFrame`, which resolves the EditorLayoutSpec for the test surface and places one widget in
// one region rect (so the toolbar and inspector are tested without the other regions).

import 'package:flutter/material.dart' show Theme;
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/editor_scope.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout_scope.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/state/playhead_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../support/support.dart';

const int s = microsPerSecond;

/// A ticker that fires only when a test calls [tick].
class RigTicker implements PlayheadTicker {
  VoidCallback? _onFrame;
  bool _active = false;

  @override
  void start(VoidCallback onFrame) {
    _onFrame = onFrame;
    _active = true;
  }

  @override
  void stop() => _active = false;

  @override
  bool get isActive => _active;

  @override
  void dispose() {
    _active = false;
    _onFrame = null;
  }

  /// One frame.
  void tick() {
    if (_active) _onFrame?.call();
  }
}

/// The items of [inspectorProject].
class RigItems {
  RigItems(EditProject p)
      : project = p.id,
        textA = _items(p, TrackKind.text)[0],
        textB = _items(p, TrackKind.text)[1],
        cue = _items(p, TrackKind.subtitle)[0],
        marker = p.timeline.markers.first.id;

  /// The project.
  final ProjectId project;

  /// Text 0-3 s.
  final ItemId textA;

  /// Text 5-7 s.
  final ItemId textB;

  /// Caption 1-3 s.
  final ItemId cue;

  /// Marker at 4 s.
  final MarkerId marker;

  static List<ItemId> _items(EditProject p, TrackKind kind) => [
        for (final t in p.timeline.tracks)
          if (t.kind == kind)
            for (final i in t.items) i.id,
      ];
}

/// Two text items (0-3 s, 5-7 s), a caption (1-3 s) and a marker (4 s) at 30 fps.
EditProject inspectorProject(FakeProjectRepository repo, {String name = 'Inspector'}) {
  final empty = repo.seedEmpty(name);
  final edit = EditSession(empty, ids: SeededIdGenerator(16));
  for (final cmd in <EditCommand>[
    const AddText(0, duration: 3 * s),
    const AddText(5 * s, duration: 2 * s),
    const AddCue(1 * s, 'Hello there', duration: 2 * s),
    const AddMarker(4 * s),
  ]) {
    final out = edit.apply(cmd);
    if (!out.changed) throw StateError('$cmd -> $out');
  }
  final project = edit.committedProject;
  repo.seed(project);
  return project;
}

/// The harness around a toolbar or inspector widget with a real, opened EditorController.
class InspectorRig {
  InspectorRig._(this.harness, this.id, this.tester, this.ticker, this.items);

  /// Harness.
  final EditorTestHarness harness;

  /// Project id.
  final ProjectId id;

  /// Tester.
  final WidgetTester tester;

  /// The playhead's ticker.
  final RigTicker ticker;

  /// The seeded items.
  final RigItems items;

  /// The container of the pumped app.
  ProviderContainer get container => harness.containerOf(tester);

  /// The editor controller.
  EditorController get editor => container.read(editorControllerProvider(id).notifier);

  /// The editor state.
  EditorState get state => container.read(editorControllerProvider(id));

  /// The playhead.
  PlayheadController get playhead => container.read(playheadProvider(id));

  /// The committed project.
  EditProject get project => state.project!;

  /// Pumps [home] (built from the project id) and opens the editor.
  static Future<InspectorRig> pump(
    WidgetTester tester,
    Widget Function(ProjectId id) home, {
    EditorSurface surface = SurfaceMatrix.phone,
    List<Override> overrides = const [],
  }) =>
      pumpWith(tester, (items) => home(items.project), surface: surface, overrides: overrides);

  /// Pumps the widget [build] makes from the seeded items and opens the editor.
  static Future<InspectorRig> pumpWith(
    WidgetTester tester,
    Widget Function(RigItems items) build, {
    EditorSurface surface = SurfaceMatrix.phone,
    List<Override> overrides = const [],
  }) async {
    final repo = FakeProjectRepository();
    final project = inspectorProject(repo);
    final ticker = RigTicker();
    final harness = EditorTestHarness(
      engine: FakeEditorEngine(validatePlans: false),
      repository: repo,
      overrides: [
        playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: () => Duration.zero)),
        ...overrides,
      ],
    );
    final rig = InspectorRig._(harness, project.id, tester, ticker, RigItems(project));
    await harness.pumpApp(tester, EditorScope(projectId: project.id, child: build(rig.items)), surface: surface);
    await rig.real(() => rig.editor.open());
    await tester.pump();
    return rig;
  }

  /// Runs [body] with real async and pumps.
  Future<void> real(Future<void> Function() body) async {
    await tester.runAsync(() async {
      await body();
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
  }

  /// Seeks the playhead exactly to [t] and settles.
  Future<void> seek(TimeUs t) async {
    await real(() async {
      await playhead.seekExact(t);
    });
    await tester.pump();
  }

  /// Selects [item].
  Future<void> select(ItemId item) async {
    editor.select(item);
    await tester.pump();
  }

  /// The item [id] of the committed project.
  TimelineItem item(ItemId id) => project.index.item(id)!;
}

/// Resolves the EditorLayoutSpec for the screen and places each widget of [regions] at its
/// region's rect, and [dock] in a bottom slot like the scaffold's dock slot (unbounded height, at
/// least the dock height plus the keyboard).
class RegionFrame extends StatelessWidget {
  /// Creates the frame.
  const RegionFrame({super.key, this.regions = const {}, this.dock, this.inspectorOpen = false});

  /// Widgets by region (regions the spec does not show are skipped).
  final Map<EditorRegion, Widget> regions;

  /// The dock content, placed when the spec shows the dock.
  final Widget? dock;

  /// Plans the layout with the inspector open.
  final bool inspectorOpen;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final platform = Theme.of(context).platform;
    final touch = platform == TargetPlatform.iOS || platform == TargetPlatform.android;
    final spec = EditorLayoutSpec.resolve(
      size: media.size,
      padding: media.padding,
      viewInsets: media.viewInsets,
      textScaler: media.textScaler,
      touch: touch,
      splitRatio: null,
      inspectorOpen: inspectorOpen,
    );
    final dockRect = spec.rectOf(EditorRegion.dock);
    // The editor screen's Scaffold supplies the theme's (Figtree) default text style.
    return EditorLayoutScope(
      spec: spec,
      child: DefaultTextStyle(
        style: DanaviewTextStyles.body.copyWith(fontFamily: DanaviewFonts.family),
        child: Stack(children: [
          for (final MapEntry(key: region, value: child) in regions.entries)
            if (spec.rectOf(region) case final rect?) Positioned.fromRect(key: ValueKey<EditorRegion>(region), rect: rect, child: child),
          if (dock != null && dockRect != null)
            Positioned(
              key: const ValueKey<EditorRegion>(EditorRegion.dock),
              left: dockRect.left,
              width: dockRect.width,
              bottom: 0,
              child: OverflowBox(
                alignment: Alignment.bottomCenter,
                fit: OverflowBoxFit.deferToChild,
                minHeight: dockRect.height + spec.viewInsets.bottom,
                maxHeight: double.infinity,
                child: dock,
              ),
            ),
        ]),
      ),
    );
  }
}

/// The spec [RegionFrame] resolved.
EditorLayoutSpec frameSpec(WidgetTester tester) => tester.widget<EditorLayoutScope>(find.byType(EditorLayoutScope).first).spec;
