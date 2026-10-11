// OWNER: UX-14
//
// `playheadProvider` / `transportProvider` wiring on a real EditorController over FakeEditorEngine:
// the playhead starts at the opened position, follows the session's preview (attached when the
// editor opens, replaced by "Restart preview", detached on close), tracks the project's duration,
// writes the settled position to the view state and autosave, and both providers end with the
// editor.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/playhead_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show AddText;
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show EngineErrorCode, EngineFailure;

import '../support/support.dart';
import 'transport_rig.dart';
import 'transport_support.dart';

class Wired {
  Wired._(this.harness, this.repo, this.id, this.ticker, this.clock);

  final EditorTestHarness harness;
  final FakeProjectRepository repo;
  final ProjectId id;
  final ManualTicker ticker;
  final ManualClock clock;
  late final ProviderContainer container = harness.container();

  EditorController get editor => container.read(editorControllerProvider(id).notifier);
  PlayheadController get playhead => container.read(playheadProvider(id));
  FakePreviewSession get preview => harness.engine.sessions.last;

  static Wired create({FakeEditorEngine? engine}) {
    final repo = FakeProjectRepository();
    final id = sampleProject(repo).id;
    final ticker = ManualTicker();
    final clock = ManualClock();
    final harness = EditorTestHarness(
      engine: engine ?? FakeEditorEngine(validatePlans: false),
      repository: repo,
      overrides: [playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: clock.call))],
    );
    return Wired._(harness, repo, id, ticker, clock);
  }

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

void main() {
  test('the playhead starts at the opened position, attached to the preview', () async {
    final w = Wired.create();
    final playhead = w.playhead; // created before the editor opens
    expect(playhead.value, 0);
    expect(playhead.preview, isNull);
    await w.editor.open(initialPlayhead: 2 * s + 17);
    await w.settle();
    final rate = w.editor.session.committedProject!.settings.frameRate;
    expect(playhead.value, rate.quantize(2 * s + 17));
    expect(identical(playhead.preview, w.preview), isTrue);
    expect(playhead.duration, 7 * s);
    expect(playhead.frameRate, rate);
  });

  test('a playhead created after the editor opened picks up the position and the preview', () async {
    final w = Wired.create();
    await w.editor.open(initialPlayhead: 3 * s);
    await w.settle();
    expect(w.playhead.value, 3 * s);
    expect(identical(w.playhead.preview, w.preview), isTrue);
  });

  test('the project\'s saved playhead is where a project reopens', () async {
    final w = Wired.create();
    await w.editor.open();
    await w.settle();
    await w.container.read(transportProvider(w.id)).seekTo(5 * s);
    await w.settle();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(w.editor.session.committedProject!.view.playhead, 5 * s, reason: 'written to the view state when the seek settled');
    expect(w.repo.autosaveRequests, greaterThan(0), reason: 'an autosave was requested (the repository debounces it)');
  });

  test('transport actions drive the real preview', () async {
    final w = Wired.create();
    await w.editor.open();
    await w.settle();
    final t = w.container.read(transportProvider(w.id));
    expect(t.canPlay, isTrue);
    await t.play();
    await w.settle();
    expect(w.preview.playing, isTrue);
    expect(t.playing.value, isTrue);
    await t.nextEditPoint();
    await w.settle();
    expect(w.preview.playing, isFalse, reason: 'jumping pauses first');
    expect(w.preview.time, 3 * s);
    expect(w.playhead.value, 3 * s);
  });

  test('the duration follows edits', () async {
    final w = Wired.create();
    await w.editor.open();
    await w.settle();
    expect(w.playhead.duration, 7 * s);
    w.editor.apply(const AddText(8 * s));
    await w.settle();
    expect(w.playhead.duration, 11 * s);
    w.editor.undo();
    await w.settle();
    expect(w.playhead.duration, 7 * s);
  });

  test('"Restart preview" re-attaches the playhead to the new preview', () async {
    final engine = FakeEditorEngine(validatePlans: false);
    engine.failNext['openPreview'] = EngineFailure.of(EngineErrorCode.gpuUnavailable);
    final w = Wired.create(engine: engine);
    await w.editor.open();
    await w.settle();
    expect(w.playhead.preview, isNull, reason: 'the preview failed to start');
    expect(w.container.read(transportProvider(w.id)).canPlay, isFalse);
    await w.editor.restartPreview();
    await w.settle();
    expect(identical(w.playhead.preview, w.preview), isTrue);
    expect(w.container.read(transportProvider(w.id)).canPlay, isTrue);
  });

  test('closing the editor detaches the playhead and stops playback', () async {
    final w = Wired.create();
    await w.editor.open();
    await w.settle();
    final t = w.container.read(transportProvider(w.id));
    await t.play();
    await w.settle();
    expect(t.playing.value, isTrue);
    final playhead = w.playhead;
    final editor = w.editor;
    await editor.close();
    await w.settle();
    expect(playhead.preview, isNull);
    expect(playhead.playing.value, isFalse);
    expect(editor.session.isOpen, isFalse);
  });

  test('both providers end with the editor (no keepAlive left behind)', () async {
    final w = Wired.create();
    final container = ProviderContainer(overrides: w.harness.overrides);
    addTearDown(container.dispose);
    await container.read(editorControllerProvider(w.id).notifier).open();
    // A widget would hold these while mounted.
    final subscriptions = [
      container.listen(playheadProvider(w.id), (a, b) {}),
      container.listen(transportProvider(w.id), (a, b) {}),
    ];
    await w.settle();
    expect(container.exists(playheadProvider(w.id)), isTrue);
    await container.read(editorControllerProvider(w.id).notifier).close();
    await w.settle();
    for (final s in subscriptions) {
      s.close();
    }
    await w.settle();
    expect(container.exists(playheadProvider(w.id)), isFalse);
    expect(container.exists(transportProvider(w.id)), isFalse);
  });

  test('providers stay alive while the editor is open even when no widget watches them', () async {
    final w = Wired.create();
    final container = ProviderContainer(overrides: w.harness.overrides);
    addTearDown(container.dispose);
    await container.read(editorControllerProvider(w.id).notifier).open();
    final sub = container.listen(playheadProvider(w.id), (a, b) {});
    final first = sub.read();
    sub.close();
    await w.settle();
    expect(identical(container.read(playheadProvider(w.id)), first), isTrue);
  });
}
