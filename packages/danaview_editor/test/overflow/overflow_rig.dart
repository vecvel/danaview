// OWNER: QA-09
//
// The rig of the no-overflow matrix suite (BUILD_PLAN QA-09, ARCH §1.3 rule 5, §17.9):
//
// * [OverflowEditor] pumps the real EditorScreen (scaffold, every region, an opened
//   EditorController over FakeEditorEngine) on the long-content project of
//   `overflow_fixtures.dart`, with a manual playhead ticker and a resolving plan compiler.
// * [expectClean] is the per-state check every test runs: `takeException() == null`
//   (expectNoOverflow), the fixed chrome inside the screen (expectInside) and every visible
//   button label and header title fitting fully (fitsFully: not truncated by its line limit).
// * [overflowSurfaces] is `SurfaceMatrix.current` (the 6-surface PR subset, or the full matrix
//   under `--dart-define=DANAVIEW_SURFACE_MATRIX=full`), optionally narrowed to one surface with
//   `--dart-define=DANAVIEW_OVERFLOW_SURFACE=<name>` (for example `280x500 @1.35 kb40% android`) so
//   a nightly failure reproduces with a single command.

import 'dart:convert';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart' show isTestGroup;
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout_scope.dart';
import 'package:danaview_editor/src/editor/layout/editor_top_bar.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/state/plan_compiler_port.dart';
import 'package:danaview_editor/src/editor/state/playhead_controller.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_transcription/testing.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../inspector/inspector_rig.dart' show RigTicker;
import '../state/state_support.dart' show resolverFor;
import '../support/support.dart';
import 'overflow_fixtures.dart';

/// Loads every font of the test asset bundle (Figtree from danaview_ui_kit and the content fonts of
/// danaview_editor_fonts) under its package-qualified family, so labels are measured with the
/// glyphs users see instead of the test font's 1 em squares. Call from `setUpAll`.
Future<void> loadRealFonts() async {
  if (_fontsLoaded) return;
  final manifest = await rootBundle.loadStructuredData<List<Object?>>('FontManifest.json', (s) async => json.decode(s) as List<Object?>);
  for (final entry in manifest.cast<Map<String, Object?>>()) {
    final family = entry['family']! as String;
    if (!family.startsWith('packages/')) continue;
    final loader = FontLoader(family);
    for (final font in (entry['fonts']! as List<Object?>).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(font['asset']! as String));
    }
    await loader.load();
  }
  _fontsLoaded = true;
}

bool _fontsLoaded = false;

/// `--dart-define=DANAVIEW_OVERFLOW_SURFACE=<EditorSurface.name>` narrows every test to one surface.
const String overflowSurfaceFilter = String.fromEnvironment('DANAVIEW_OVERFLOW_SURFACE');

/// The surfaces of this run: [SurfaceMatrix.current], narrowed by [overflowSurfaceFilter].
List<EditorSurface> overflowSurfaces() {
  final all = SurfaceMatrix.current;
  if (overflowSurfaceFilter.isEmpty) return all;
  final pool = {...SurfaceMatrix.full, ...SurfaceMatrix.pr, ...all};
  final match = [for (final s in pool) if (s.name == overflowSurfaceFilter) s];
  if (match.isEmpty) {
    throw ArgumentError('DANAVIEW_OVERFLOW_SURFACE="$overflowSurfaceFilter" names no surface; '
        'use a name like "${SurfaceMatrix.narrowest.name}"');
  }
  return match;
}

/// `--dart-define=DANAVIEW_OVERFLOW_STRICT=true` fails on the open [knownDefects] too.
const bool overflowStrict = bool.fromEnvironment('DANAVIEW_OVERFLOW_STRICT');

/// Open defects in other tickets' files that this suite finds (reported to their owners; see
/// docs/v1.1/editor/qa/QA-09-overflow.md). A problem matching one is printed as KNOWN DEFECT and
/// does not fail the run unless [overflowStrict]. Remove an entry when its fix lands.
const List<({String id, String pattern, String what})> knownDefects = [
  (
    id: 'FIX-UX-22-2',
    pattern: 'property "transform.scale" does not apply to this item: MediaClip',
    what: 'ManipulationOverlay evaluates transform.scale on a selected audio clip (no visual) and throws while building',
  ),
];

/// The known defect [problem] matches, if any.
String? knownDefectOf(String problem) {
  for (final d in knownDefects) {
    if (problem.contains(d.pattern)) return d.id;
  }
  return null;
}

final List<FlutterErrorDetails> _errors = [];

/// Records [details] for the next [takeErrors] (a `FlutterError.onError` handler).
void collectError(FlutterErrorDetails details) => _errors.add(details);

/// Every error reported since the last call (overflow, layout and build errors), cleared.
List<FlutterErrorDetails> takeErrors() {
  final out = List<FlutterErrorDetails>.of(_errors);
  _errors.clear();
  return out;
}

/// One `testWidgets` per surface of [overflowSurfaces]. Errors reported by the framework are
/// collected (each with its own message) instead of failing at the first one; [ProblemLog.current]
/// gathers every problem of the test and fails once at the end, listing all of them.
@isTestGroup
void testOverflow(String description, Future<void> Function(WidgetTester tester, EditorSurface surface) body) {
  for (final surface in overflowSurfaces()) {
    testWidgets('$description [$surface]', (tester) async {
      final previous = FlutterError.onError;
      _errors.clear();
      FlutterError.onError = collectError;
      final log = ProblemLog.current = ProblemLog();
      try {
        await body(tester, surface);
        // Let toasts and throttled announcements expire so no timer outlives the test.
        await tester.pump(const Duration(seconds: 6));
        log.check(tester, 'end');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        log.check(tester, 'teardown');
      } finally {
        FlutterError.onError = previous;
        DanaviewToast.dismiss();
        EditorAnnouncer.instance.reset();
      }
      log.expectNone();
    });
  }
}

/// Every [DanaviewButton] and kit section header that is visible on the screen shows its whole
/// label: not truncated by its line limit (fitsFully for button labels and titles).
List<String> truncatedChrome(WidgetTester tester) {
  final bounds = screenRect(tester);
  final problems = <String>[];
  for (final type in const [DanaviewButton, DanaviewSectionHeader]) {
    for (final element in find.byType(type, skipOffstage: true).evaluate()) {
      final ro = element.renderObject;
      if (ro is! RenderBox || !ro.hasSize || !ro.attached) continue;
      final rect = MatrixUtils.transformRect(ro.getTransformTo(null), Offset.zero & ro.size);
      if (!rect.overlaps(bounds)) continue;
      void visit(Element e) {
        final p = e.renderObject;
        if (e.widget is RichText && p is RenderParagraph && p.hasSize && p.didExceedMaxLines) {
          final text = p.text.toPlainText();
          problems.add('$type label "${text.length > 40 ? '${text.substring(0, 40)}…' : text}" is truncated');
        }
        e.visitChildren(visit);
      }

      visit(element);
    }
  }
  return problems;
}

/// The problems of one state: an exception (overflow, layout or build error), a widget of
/// [inside] outside the screen, text under [fits] truncated, or a truncated button label or
/// section header anywhere on screen.
List<String> problemsOf(WidgetTester tester, {List<Finder> inside = const [], List<Finder> fits = const [], String? state}) {
  final where = state == null ? '' : '[$state] ';
  final out = <String>[];
  for (final e in takeErrors()) {
    out.add('${where}exception: ${e.exceptionAsString().split('\n').first}');
  }
  final error = tester.takeException();
  if (error != null) out.add('${where}exception: ${'$error'.split('\n').first}');
  final bounds = screenRect(tester);
  for (final f in inside) {
    for (final element in f.evaluate()) {
      final ro = element.renderObject;
      if (ro is! RenderBox || !ro.hasSize) continue;
      final rect = MatrixUtils.transformRect(ro.getTransformTo(null), Offset.zero & ro.size);
      if (rect.left < bounds.left - 0.01 || rect.top < bounds.top - 0.01 || rect.right > bounds.right + 0.01 || rect.bottom > bounds.bottom + 0.01) {
        out.add('$where${element.widget.runtimeType} at $rect is outside $bounds');
      }
    }
  }
  for (final f in fits) {
    if (f.evaluate().isEmpty) continue;
    out.addAll(fitsFullyProblems(tester, f).map((p) => '$where$p'));
  }
  out.addAll(truncatedChrome(tester).map((p) => '$where$p'));
  return out;
}

/// [problemsOf] as an expectation.
void expectClean(WidgetTester tester, {List<Finder> inside = const [], List<Finder> fits = const [], String? state}) {
  final problems = problemsOf(tester, inside: inside, fits: fits, state: state);
  expect(problems, isEmpty, reason: problems.join('\n'));
}

/// Collects the problems of every state of one test and fails once, listing all of them.
class ProblemLog {
  /// The log of the running [testOverflow] test.
  static ProblemLog current = ProblemLog();

  final List<String> _problems = [];

  /// Records the problems of the current state.
  void check(WidgetTester tester, String state, {List<Finder> inside = const [], List<Finder> fits = const []}) =>
      _problems.addAll(problemsOf(tester, inside: inside, fits: fits, state: state));

  /// Adds one problem.
  void add(String problem) => _problems.add(problem);

  /// Fails with every recorded problem; problems of a [knownDefects] entry only print unless
  /// [overflowStrict].
  void expectNone() {
    final failing = <String>[];
    for (final p in _problems.toSet()) {
      final known = knownDefectOf(p);
      if (known != null && !overflowStrict) {
        // ignore: avoid_print
        print('KNOWN DEFECT $known: $p');
      } else {
        failing.add(known == null ? p : '$known: $p');
      }
    }
    expect(failing, isEmpty, reason: failing.join('\n'));
  }
}

/// The real EditorScreen on the long-content project.
class OverflowEditor {
  OverflowEditor._(this.harness, this.id, this.tester, this.ticker);

  /// The harness (fakes for every root provider).
  final EditorTestHarness harness;

  /// The project id.
  final ProjectId id;

  /// The tester.
  final WidgetTester tester;

  /// The playhead's manual ticker.
  final RigTicker ticker;

  /// The container of the pumped app.
  ProviderContainer get container => harness.containerOf(tester);

  /// The editor controller.
  EditorController get editor => container.read(editorControllerProvider(id).notifier);

  /// The editor state.
  EditorState get state => container.read(editorControllerProvider(id));

  /// The layout the scaffold resolved.
  EditorLayoutSpec get spec => tester.widget<EditorLayoutScope>(find.byType(EditorLayoutScope).first).spec;

  /// Pumps the editor on [surface] and waits until it is ready.
  static Future<OverflowEditor> pump(
    WidgetTester tester,
    EditorSurface surface, {
    EditProject Function(FakeProjectRepository repo)? project,
    FakeEditorEngine? engine,
    FakeMediaPoolService? mediaPool,
    FakeTranscriptionService? transcription,
    List<Override> overrides = const [],
  }) async {
    final repo = FakeProjectRepository();
    final id = (project ?? seedLongProject)(repo).id;
    final ticker = RigTicker();
    final harness = EditorTestHarness(
      engine: engine ?? FakeEditorEngine(validatePlans: false),
      repository: repo,
      mediaPool: mediaPool,
      transcription: transcription,
      overrides: [
        playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: () => Duration.zero)),
        planCompilerPortProvider.overrideWithValue(ResolvingPlanCompilerPort((_, p) => resolverFor(p))),
        ...overrides,
      ],
    );
    final rig = OverflowEditor._(harness, id, tester, ticker);
    await tester.runAsync(() async {
      await harness.pumpEditor(tester, projectId: id, surface: surface);
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await rig.settle();
    expect(rig.state.phase, EditorPhase.ready, reason: 'the editor opened');
    return rig;
  }

  /// Pumps a few frames and lets the first route transition finish.
  Future<void> settle() async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Runs [body] with real async, then pumps.
  Future<void> real(Future<void> Function() body) async {
    await tester.runAsync(() async {
      await body();
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await settle();
  }

  /// A context inside the editor (under its EditorScope and Navigator) for actions and sheets.
  BuildContext get context => tester.element(find.byType(EditorTopBar).first);

  /// The app's navigator.
  NavigatorState get navigator => tester.state<NavigatorState>(find.byType(Navigator).first);

  /// The fixed editor chrome that must lie inside the screen.
  List<Finder> get chrome => [find.byType(EditorTopBar)];

  /// The problems of this test.
  ProblemLog get log => ProblemLog.current;

  /// Records the problems of [state] (editor chrome plus [inside] inside the screen).
  void check(String state, {List<Finder> inside = const [], List<Finder> fits = const []}) =>
      log.check(tester, state, inside: [...chrome, ...inside], fits: fits);
}
