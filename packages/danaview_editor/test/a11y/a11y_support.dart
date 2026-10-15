// OWNER: QA-08
//
// Accessibility guideline checks for the editor (ARCH §17.9, ux.md §19.1) and the rig the QA-08
// suite pumps surfaces with.
//
// `a11yProblems(tester)` walks every semantics tree of the test binding and reports:
// * tappable nodes (tap or long press) smaller than 44×44 logical px (`minTapTarget`), unless the
//   node is timeline content (clips, captions, text items, markers, keyframes, transition chips):
//   those are painted at the size of their time range and lane (ARCH §17.2 lane heights, text and
//   subtitle lanes ≥ 32 px, ruler 24 px) and every action on them has a non-spatial equivalent
//   (custom actions, the context tool strip, the shortcuts) per WCAG 2.5.8's "equivalent"
//   exception; they are checked for labels and actions instead;
// * tappable nodes without a label, tooltip or value (screen readers would say "button");
// * timeline clip nodes without the edit custom actions (unless their track is locked).
// Nodes partly outside the screen (scrolled away, clipped by a sheet edge) are skipped, as Flutter's
// own `MinimumTapTargetGuideline` does.
//
// Text contrast is checked with Flutter's `textContrastGuideline` (pixels) on top, and the token
// pairs are checked by computation in `contrast_tokens_test.dart`.
//
// Known defects: `knownA11yDefects` lists problems that belong to another ticket (filed as FIX
// tickets in docs/v1.1/editor/qa/QA-08-a11y.md). They are reported, not failed, so this suite
// stays green while the owning ticket fixes them; anything not on the list fails.

import 'dart:async';

import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/editor_screen.dart';
import 'package:danaview_editor/src/editor/layout/editor_top_bar.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/state/playhead_controller.dart';
import 'package:danaview_editor/src/editor/state/render_preview_controller.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart';
import 'package:danaview_editor/src/editor/toolbar/tool_tile.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../inspector/inspector_rig.dart' show RigTicker;
import '../render_preview/support.dart' show MemoryRenderStore, basePlan;
import '../support/support.dart';
import '../timeline/canvas/canvas_fixtures.dart';

export '../timeline/canvas/canvas_fixtures.dart' show s, f;

/// Minimum tap target (ARCH §17.9: touch targets ≥ 44×44).
const Size minTapTarget = Size(44, 44);

/// One accessibility problem found in the semantics tree.
@immutable
class A11yProblem {
  /// Creates a problem.
  const A11yProblem(this.rule, this.label, this.rect, this.detail);

  /// `size`, `label` or `actions`.
  final String rule;

  /// The node's label (empty when it has none).
  final String label;

  /// The node's rect in logical screen pixels.
  final Rect rect;

  /// What is wrong.
  final String detail;

  @override
  String toString() => '[$rule] "${label.replaceAll('\n', ' | ')}" at ${_rect(rect)}: $detail';
}

/// A problem owned by another ticket, filed as a FIX ticket (QA-08-a11y.md, "Defects").
@immutable
class KnownA11yDefect {
  /// Creates the entry.
  const KnownA11yDefect(this.fixTicket, this.rule, this.label, this.why);

  /// The FIX ticket.
  final String fixTicket;

  /// The rule broken.
  final String rule;

  /// Matches the node label (an empty-label node matches `^$`).
  final Pattern label;

  /// One line on the defect.
  final String why;

  /// Whether [p] is this defect.
  bool matches(A11yProblem p) => p.rule == rule && _fullMatch(label, p.label);
}

bool _fullMatch(Pattern pattern, String s) {
  if (pattern is String) return pattern == s;
  final m = (pattern as RegExp).firstMatch(s);
  return m != null && m.start == 0 && m.end == s.length;
}

/// Problems that belong to other tickets (each one is a FIX ticket in QA-08-a11y.md).
final List<KnownA11yDefect> knownA11yDefects = [
  KnownA11yDefect(
    'FIX-UX-14-1',
    'size',
    RegExp(r'Playhead position(\nPlayhead position)?'),
    'transport time readout button is 35-41 px tall and its label is read twice',
  ),
  KnownA11yDefect(
    'FIX-UX-14-2',
    'size',
    RegExp(r'Play|Pause|Previous frame|Next frame|Previous edit point|Next edit point|Add marker|Snapping|Ripple editing|Zoom out|Zoom in|Fit timeline|More'),
    'transport bar buttons are 40 px tall when the bar is 40 px (compact landscape and the narrowest surfaces at text scale 1.35)',
  ),
  KnownA11yDefect(
    'FIX-UX-11-1',
    'size',
    RegExp(r'(.+, (video|audio|overlay|text|subtitles|voice|music) track.*|(Lock|Unlock|Show|Hide|Mute|Unmute|Solo|Unsolo) .+)'),
    'track header buttons on 32 px text and subtitle lanes are 32 px tall',
  ),
  KnownA11yDefect(
    'FIX-UX-16-1',
    'size',
    RegExp(r'([^\n]+), ([^\n]+)\n\2'),
    'inspector slider-row value chips (tap to type a value) are 32 px tall and read their value twice',
  ),
  KnownA11yDefect(
    'FIX-UX-22-1',
    'label',
    '',
    'ManipulationOverlay with nothing selected exposes an unlabeled tap/long-press node over the preview',
  ),
  KnownA11yDefect(
    'FIX-KIT-1',
    'size',
    RegExp(r'([^\n]+)\n\1'),
    'DanaviewSegmentedControl segments are 38 px tall inside the 44 px control and read their label twice',
  ),
];

/// A thrown error owned by another ticket (QA-08-a11y.md, "Defects").
@immutable
class KnownErrorDefect {
  /// Creates the entry.
  const KnownErrorDefect(this.fixTicket, this.message, this.why);

  /// The FIX ticket.
  final String fixTicket;

  /// Matches `error.toString()`.
  final Pattern message;

  /// One line on the defect.
  final String why;
}

/// Errors that belong to other tickets.
final List<KnownErrorDefect> knownErrorDefects = [
  KnownErrorDefect(
    'FIX-UX-22-2',
    RegExp(r'property "transform\.\w+" does not apply to this item: MediaClip'),
    'selecting an audio clip throws in ManipulationOverlay.build (the semantics label reads the transform of a clip without visual props)',
  ),
];

/// Behaviour defects found by the timeline semantics tests (QA-08-a11y.md, "Defects").
const List<String> knownTimelineDefects = ['FIX-UX-12-1', 'FIX-UX-12-2'];

/// Whether FIX-UX-22-2 (selecting an audio clip throws) is still listed.
bool get audioSelectionCrashOpen => knownErrorDefects.any((k) => k.fixTicket == 'FIX-UX-22-2');

/// Takes the pending exception; fails unless it is null or a [knownErrorDefects] entry. Returns the
/// FIX ticket of a known one.
String? takeKnownException(WidgetTester tester, {String where = ''}) {
  final error = tester.takeException();
  if (error == null) return null;
  for (final k in knownErrorDefects) {
    if (k.message.allMatches(error.toString()).isNotEmpty) return k.fixTicket;
  }
  fail('unexpected exception $where: $error');
}

/// Every problem in the current semantics trees (see the file comment).
List<A11yProblem> a11yProblems(WidgetTester tester) {
  final out = <A11yProblem>[];
  for (final view in tester.binding.renderViews) {
    final root = view.owner?.semanticsOwner?.rootSemanticsNode;
    if (root == null) continue;
    final screen = Offset.zero & (view.size);
    final dpr = view.flutterView.devicePixelRatio;
    void visit(SemanticsNode node) {
      _check(node, screen, dpr, out);
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(root);
  }
  return out;
}

/// The problems of [a11yProblems] that are not [knownA11yDefects].
List<A11yProblem> unexpectedA11yProblems(WidgetTester tester, {List<KnownA11yDefect>? known}) {
  final list = known ?? knownA11yDefects;
  return [
    for (final p in a11yProblems(tester))
      if (!list.any((k) => k.matches(p))) p,
  ];
}

/// Fails on any problem that is not a known defect; also runs Flutter's text contrast guideline
/// unless [contrast] is false.
Future<void> expectA11yGuidelines(WidgetTester tester, {bool contrast = true, String where = ''}) async {
  final problems = unexpectedA11yProblems(tester);
  expect(problems, isEmpty, reason: 'accessibility (ARCH §17.9) $where:\n${problems.map((p) => '  $p').join('\n')}');
  if (contrast) await expectTextContrast(tester, where: where);
}

/// Flutter's `textContrastGuideline` (≥ 4.5:1 below 18 pt, measured on the rendered pixels),
/// minus the disabled tool tiles: they stay tappable at 40 % opacity so a tap can explain why
/// they are disabled (ux.md §9.2), which WCAG 1.4.3 exempts as inactive components, but the
/// guideline only skips nodes flagged disabled. A failure is exempt only when its node carries the
/// tile's disabled reason as hint.
Future<void> expectTextContrast(WidgetTester tester, {String where = ''}) async {
  final evaluation = await textContrastGuideline.evaluate(tester);
  if (evaluation.passed) return;
  final reasons = disabledToolReasons(tester);
  final failures = (evaluation.reason ?? '')
      .split(RegExp(r'(?=SemanticsNode#)'))
      .where((chunk) => chunk.trim().isNotEmpty)
      .where((chunk) => !reasons.any((r) => chunk.contains('hint: "$r"')))
      .toList();
  expect(failures, isEmpty, reason: 'text contrast (ARCH §1.3 rule 4) $where:\n${failures.join('\n')}');
}

/// The disabled reasons of the visible disabled tool tiles.
Set<String> disabledToolReasons(WidgetTester tester) => {
      for (final tile in tester.widgetList<ToolTile>(find.byType(ToolTile)))
        if (!tile.data.enabled && tile.data.reason != null) tile.data.reason!,
    };

/// Whether [label] names timeline content (clips and the nodes of `TimelineSemanticsLayer`).
bool isTimelineContentLabel(String label) => _timelineContent.hasMatch(label);

final RegExp _timelineContent = RegExp(
  r'^(Video clip|Image|Freeze frame|Audio clip|Text|Caption)(, .*)?, length .*, starts at .*'
  // Render marker strip ranges (UX-44): painted at their time span in a 10 px strip; the "Render
  // preview" action (tool tile, shortcut, range of the selection or loop) is their equivalent.
  r'|^(Rendered|Needs rendering|Plays live), [\d:]+ to [\d:]+(, .*)?$'
  r'|^Marker( .*)? at \d'
  r'|^.* transition at \d'
  r'|^Add transition at \d'
  r'|^.* keyframe at \d',
);

final RegExp _clipLabel = RegExp(r'^(Video clip|Image|Freeze frame|Audio clip|Text|Caption)(, .*)?, length ');

/// The labels of the edit actions every unlocked clip node carries (ARCH §17.9).
const List<String> clipEditActionLabels = [
  TimelineSemanticsStrings.split,
  TimelineSemanticsStrings.delete,
  TimelineSemanticsStrings.moveFrameEarlier,
  TimelineSemanticsStrings.moveFrameLater,
  TimelineSemanticsStrings.moveSecondEarlier,
  TimelineSemanticsStrings.moveSecondLater,
  TimelineSemanticsStrings.trimStartFrameEarlier,
  TimelineSemanticsStrings.trimStartFrameLater,
  TimelineSemanticsStrings.trimEndFrameEarlier,
  TimelineSemanticsStrings.trimEndFrameLater,
];

/// Labels of the custom actions on [node].
List<String> customActionLabels(SemanticsNode node) => [
      for (final id in node.getSemanticsData().customSemanticsActionIds ?? const <int>[])
        CustomSemanticsAction.getAction(id)?.label ?? '',
    ];

/// [node]'s rect in logical screen pixels, or null when it touches the edge of a scrollable
/// ancestor (it may be partly scrolled away; Flutter's `MinimumTapTargetGuideline` skips those too).
Rect? globalRectOf(SemanticsNode node, double dpr) {
  var rect = node.rect;
  SemanticsNode? current = node;
  while (current != null) {
    final transform = current.transform;
    if (transform != null) rect = MatrixUtils.transformRect(transform, rect);
    if (current.flagsCollection.hasImplicitScrolling && _atBoundary(rect, current.rect)) return null;
    current = current.parent;
  }
  return Rect.fromLTRB(rect.left / dpr, rect.top / dpr, rect.right / dpr, rect.bottom / dpr);
}

bool _atBoundary(Rect child, Rect parent) =>
    !(child.left - parent.left > 0.001 &&
        parent.right - child.right > 0.001 &&
        child.top - parent.top > 0.001 &&
        parent.bottom - child.bottom > 0.001);

void _check(SemanticsNode node, Rect screen, double dpr, List<A11yProblem> out) {
  if (node.isMergedIntoParent || node.isInvisible) return;
  final data = node.getSemanticsData();
  if (data.flagsCollection.isHidden || data.flagsCollection.isLink) return;
  final tappable = data.hasAction(SemanticsAction.tap) || data.hasAction(SemanticsAction.longPress);
  if (!tappable) return;
  final rect = globalRectOf(node, dpr);
  if (rect == null || rect.isEmpty) return;
  final label = data.label;
  final named = label.trim().isNotEmpty || data.tooltip.trim().isNotEmpty || data.value.trim().isNotEmpty;
  if (!named) out.add(A11yProblem('label', label, rect, 'tappable node has no label, tooltip or value'));
  if (isTimelineContentLabel(label)) {
    if (_clipLabel.hasMatch(label) && !label.contains('track locked')) {
      final have = customActionLabels(node).toSet();
      final missing = clipEditActionLabels.where((a) => !have.contains(a)).toList();
      if (missing.isNotEmpty) out.add(A11yProblem('actions', label, rect, 'clip node lacks custom actions $missing'));
    }
    return;
  }
  // Touching the screen edge: may be partly off screen; skipped like MinimumTapTargetGuideline.
  if (_atBoundary(rect, screen)) return;
  if (rect.width < minTapTarget.width - 0.01 || rect.height < minTapTarget.height - 0.01) {
    out.add(A11yProblem('size', label, rect, 'tap target ${rect.width.toStringAsFixed(1)}×${rect.height.toStringAsFixed(1)} < 44×44'));
  }
}

String _rect(Rect r) =>
    '(${r.left.toStringAsFixed(0)},${r.top.toStringAsFixed(0)} ${r.width.toStringAsFixed(0)}×${r.height.toStringAsFixed(0)})';

// -------------------------------------------------------------------------------------------------
// App and editor rig
// -------------------------------------------------------------------------------------------------

/// A dark Danaview app for [surface] with a text direction and the platform's reduce-motion flag
/// (applied above the navigator, so sheets and dialogs inherit both).
Widget a11yApp(EditorSurface surface, Widget home, {TextDirection textDirection = TextDirection.ltr, bool reduceMotion = false}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: DanaviewTheme.darkTheme.copyWith(platform: surface.platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(surface.textScale), disableAnimations: reduceMotion),
        child: Directionality(textDirection: textDirection, child: child ?? const SizedBox.shrink()),
      ),
      home: home,
    );

/// The QA-08 fixture: `richProject` (every item kind and state, a cross dissolve, keyframes, a
/// marker, a locked and a hidden lane) with visual props on every video and image clip, as the
/// app's import gives them (the canvas fixture leaves some null, which the transform rows reject).
EditProject a11yProject() {
  final p = richProject();
  final tracks = [
    for (final t in p.timeline.tracks)
      t.kind == TrackKind.audio
          ? t
          : t.copyWith(items: [
              for (final i in t.items)
                if (i is MediaClip && i.visual == null) i.copyWith(visual: const VisualProps()) else i,
            ]),
  ];
  return p.copyWith(timeline: p.timeline.copyWith(tracks: tracks));
}

/// Every inspector route of ARCH §17.7 on an item of [a11yProject] that it applies to.
const List<InspectorRoute> everyInspectorRoute = [
  MediaInspector(),
  VoiceoverInspector(),
  OverlayInspector(),
  CanvasInspector(),
  TransformInspector(ItemId('it_v1')),
  CropInspector(ItemId('it_v1')),
  MaskInspector(ItemId('it_v6')),
  SpeedInspector(ItemId('it_v3')),
  AudioInspector(ItemId('it_v1')),
  AudioInspector(ItemId('it_a1'), focus: AudioPanelFocus.fades),
  AdjustInspector(ItemId('it_v1')),
  FiltersInspector(ItemId('it_v1')),
  ChromaInspector(ItemId('it_v6')),
  KeyframesInspector(ItemId('it_o1')),
  TextInspector(ItemId('it_t1')),
  TextInspector(ItemId('it_t1'), tab: TextPanelTab.style),
  ClipInfoInspector(ItemId('it_v1')),
  SubtitlesInspector(),
  TransitionInspector(TransitionRef(TrackId('tr_main'), ItemId('it_v1'), ItemId('it_v2'))),
];

/// The four layout kinds of ARCH §17.2 on representative surfaces (largest supported text scale).
const List<({String kind, EditorSurface surface})> layoutSurfaces = [
  (kind: 'compactPortrait', surface: EditorSurface(Size(390, 844), textScale: 1.35)),
  (kind: 'compactLandscape', surface: EditorSurface(Size(844, 390), textScale: 1.35)),
  (kind: 'medium', surface: EditorSurface(Size(834, 1194), textScale: 1.35, platform: TargetPlatform.iOS)),
  (kind: 'expanded', surface: EditorSurface(Size(1194, 834), textScale: 1.35, platform: TargetPlatform.iOS)),
];

/// The real `EditorScreen` over [a11yProject] (every item kind, a transition, keyframes, a marker)
/// with an opened `EditorController`, `FakeEditorEngine` and a manual playhead ticker.
class A11yEditorRig {
  A11yEditorRig._(this.tester, this.harness, this.id);

  /// The tester.
  final WidgetTester tester;

  /// The harness (fakes).
  final EditorTestHarness harness;

  /// The project.
  final ProjectId id;

  /// The container of the pumped app.
  ProviderContainer get container => harness.containerOf(tester);

  /// The controller.
  EditorController get editor => container.read(editorControllerProvider(id).notifier);

  /// The state.
  EditorState get state => container.read(editorControllerProvider(id));

  /// The working project.
  EditProject get project => state.project!;

  /// The action registry.
  EditorActionRegistry get registry => container.read(editorActionRegistryProvider);

  /// An action context over the top bar (like a top-bar button's).
  WidgetActionContext get ctx =>
      WidgetActionContext.container(projectId: id, context: tester.element(find.byType(EditorTopBar)), container: container);

  /// Pumps the editor on [surface].
  static Future<A11yEditorRig> pump(
    WidgetTester tester, {
    EditorSurface surface = SurfaceMatrix.phone,
    TextDirection textDirection = TextDirection.ltr,
    bool reduceMotion = false,
    EditProject? project,
    bool renderPreview = false,
  }) async {
    final store = renderPreview ? MemoryRenderStore() : null;
    if (store != null) await tester.runAsync(store.open);
    final repo = FakeProjectRepository();
    final id = repo.seed(project ?? a11yProject());
    final ticker = RigTicker();
    final harness = EditorTestHarness(
      engine: FakeEditorEngine(validatePlans: false),
      repository: repo,
      overrides: [
        playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: () => Duration.zero)),
        if (store != null) renderPreviewStoreProvider.overrideWithValue(store),
      ],
    );
    final rig = A11yEditorRig._(tester, harness, id);
    applySurface(tester, surface);
    EditorAnnouncer.instance.reset();
    addTearDown(EditorAnnouncer.instance.reset);
    addTearDown(DanaviewToast.dismiss);
    await tester.runAsync(() async {
      await tester.pumpWidget(ProviderScope(
        overrides: harness.overrides,
        child: a11yApp(
          surface,
          EditorScreen(projectId: id, onClose: () {}, onOpenProjects: () {}),
          textDirection: textDirection,
          reduceMotion: reduceMotion,
        ),
      ));
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
    await tester.pump();
    expect(rig.state.phase, EditorPhase.ready, reason: 'editor did not open');
    return rig;
  }

  /// Runs [body] with real async, then pumps.
  Future<void> real(Future<void> Function() body) async {
    await tester.runAsync(() async {
      await body();
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
  }

  /// Frames for sheets and panels to animate in (bounded: progress indicators may repeat).
  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Opens [route] in the inspector (selecting its item first) and settles. Audio clips are not
  /// selected while FIX-UX-22-2 is open (selecting one throws in the preview overlay); the panel
  /// itself does not need the selection.
  Future<void> openInspector(InspectorRoute route) async {
    if (route is ItemInspectorRoute && !(_isAudioClip(route.item) && audioSelectionCrashOpen)) editor.select(route.item);
    await tester.pump();
    editor.openInspector(route);
    await settle();
  }

  bool _isAudioClip(ItemId id) {
    final item = project.index.locate(id)?.item;
    return item is MediaClip && item.visual == null;
  }

  /// The project's render-preview controller (UX-44); available when pumped with `renderPreview`.
  RenderPreviewController get renderPreview => container.read(renderPreviewControllerProvider(id));

  /// Shows heavy ranges on the render marker strip: feeds the render-preview controller the UX-44
  /// fixture plan (`basePlan`, 0–4 s: live [0, 1), heavy chroma [1, 2), live [2, 3), heavy chroma
  /// [3, 4)). The rig's own plan has no heavy range (its media are offline placeholders, which
  /// lower to solid layers without effects). Needs `renderPreview: true`.
  Future<RenderPreviewController> showHeavyRanges() async {
    final controller = renderPreview;
    // Not awaited: the controller's send queue may chain onto futures of the fake-async zone.
    unawaited(controller.planChanged(basePlan(rev: 1 << 20)));
    for (var i = 0; i < 3; i++) {
      await real(() async {});
    }
    await settle();
    expect(controller.value.available, isTrue, reason: 'render preview needs a store (pump with renderPreview: true)');
    expect(controller.value.heavyUnrendered, isNotEmpty, reason: 'the fixture plan has heavy ranges');
    return controller;
  }

  /// Pops the top route (a sheet or dialog) and settles.
  Future<void> popRoute() async {
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.pop();
    await settle();
  }

  /// Invokes [action] like a top-bar button and settles.
  Future<EditorActionResult> invoke(EditorActionId action) async {
    final result = registry.invoke(action, ctx);
    await settle();
    return result;
  }
}
