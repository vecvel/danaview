// OWNER: QA-00
//
// Editor driver of the E2E suite: creates projects through the New project sheet (the Files picker
// answered by `E2ePicker`), attaches to the open `EditorScreen`, runs editor actions through the
// same `EditorActionRegistry` the tool tiles, context menus and shortcuts use, sends hardware-keyboard
// and pointer events, seeks with exact engine acks and reads frame barcodes from
// `PreviewSession.debugCaptureFrame` (ENG-05 reader).

// ignore_for_file: implementation_imports

import 'dart:async';

import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/action_binding.dart' show EditorActionSource;
import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/state/playhead_controller.dart';
import 'package:danaview_editor/src/editor/state/transport_controller.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_viewport.dart' show TimelineViewportController;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_engine/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'e2e_app.dart';

/// One decoded preview frame.
final class E2eFrame {
  /// Creates a frame.
  const E2eFrame(this.rgba, this.width, this.height);

  /// RGBA bytes.
  final Uint8List rgba;

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// The ENG-05 barcode of the frame.
  FrameBarcodeReading get barcode => FrameBarcode.read(rgba, width: width, height: height);

  /// Mean luma (0..255) of the whole frame (black-frame checks).
  double get meanLuma {
    var sum = 0;
    var n = 0;
    for (var i = 0; i + 3 < rgba.length; i += 4 * 16) {
      sum += (rgba[i] * 299 + rgba[i + 1] * 587 + rgba[i + 2] * 114) ~/ 1000;
      n++;
    }
    return n == 0 ? 0 : sum / n;
  }

  /// RGBA of the pixel at ([x], [y]).
  (int, int, int, int) pixel(int x, int y) {
    final o = (y * width + x) * 4;
    return (rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3]);
  }
}

/// Driver of one open project.
final class E2eEditor {
  E2eEditor._(this.tester, this.id);

  /// The tester.
  final WidgetTester tester;

  /// The open project.
  final ProjectId id;

  // ---------------------------------------------------------------------------------------------
  // Opening
  // ---------------------------------------------------------------------------------------------

  /// Creates a project through Projects › New project › Files with [media] (absolute sandbox paths)
  /// named [name], and returns the driver of the editor that opens. Starts from Home or Projects.
  static Future<E2eEditor> createProject(WidgetTester tester, {required String name, required List<String> media}) async {
    if (find.byType(ProjectsScreen).evaluate().isEmpty) await E2eApp.openProjectsFromHome(tester);
    await E2eApp.tapKey(tester, 'projects-new');
    await E2eApp.waitKey(tester, 'new-project-sheet');
    E2eApp.world.engine.picker.queue(media);
    await E2eApp.tapKey(tester, 'new-project-files');
    for (final path in media) {
      await E2eApp.waitKey(tester, 'new-project-pick-${Uri.file(path)}');
    }
    await E2eApp.enterText(tester, 'new-project-name', name);
    await E2eApp.tapKey(tester, 'new-project-create');
    await E2eApp.pumpUntil(
      tester,
      () {
        if (E2eApp.hasKey('import-finish')) unawaited(E2eApp.tapKey(tester, 'import-finish'));
        return find.byType(EditorScreen).evaluate().isNotEmpty;
      },
      what: 'the editor of the new project "$name"',
      timeout: const Duration(minutes: 2),
    );
    return attach(tester);
  }

  /// Attaches to the `EditorScreen` on screen and waits until it is ready with a live preview.
  static Future<E2eEditor> attach(WidgetTester tester, {bool waitPreview = true}) async {
    await E2eApp.pumpUntil(tester, () => find.byType(EditorScreen).evaluate().isNotEmpty, what: 'EditorScreen');
    final screen = tester.widget<EditorScreen>(find.byType(EditorScreen).last);
    final e = E2eEditor._(tester, screen.projectId);
    await e.waitReady(waitPreview: waitPreview);
    return e;
  }

  /// Opens the project card [id] on the Projects screen.
  static Future<E2eEditor> openFromProjects(WidgetTester tester, ProjectId id) async {
    if (find.byType(ProjectsScreen).evaluate().isEmpty) await E2eApp.openProjectsFromHome(tester);
    await E2eApp.tapKey(tester, 'project-card-$id');
    return attach(tester);
  }

  /// Waits until the controller is ready and the preview shows frames.
  Future<void> waitReady({bool waitPreview = true}) => E2eApp.pumpUntil(
        tester,
        () {
          final s = state;
          if (s.phase == EditorPhase.failed) throw TestFailure('The editor failed to open: ${s.failure}');
          return s.isReady && (!waitPreview || (s.preview.phase == PreviewPhase.ready && session.preview != null));
        },
        what: 'the editor to be ready',
        timeout: const Duration(seconds: 60),
      );

  /// Closes the editor through the top bar's close button and waits until it is gone.
  Future<void> close() async {
    await E2eApp.tap(tester, find.bySemanticsLabel('Close editor'), what: 'Close editor');
    await E2eApp.pumpUntil(tester, () => find.byType(EditorScreen).evaluate().isEmpty, what: 'the editor to close', timeout: const Duration(seconds: 30));
  }

  // ---------------------------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------------------------

  /// The app container.
  ProviderContainer get container => E2eApp.container(tester);

  /// The editor controller.
  EditorController get controller => container.read(editorControllerProvider(id).notifier);

  /// The editor state.
  EditorState get state => container.read(editorControllerProvider(id));

  /// The open session (preview, plan sync).
  EditorSession get session => container.read(editorSessionProvider(id));

  /// The project as edited now.
  EditProject get project => state.project ?? (throw StateError('no project'));

  /// The project frame rate.
  FrameRate get rate => project.settings.frameRate;

  /// The playhead.
  PlayheadController get playhead => container.read(playheadProvider(id));

  /// Transport.
  TransportController get transport => container.read(transportProvider(id));

  /// Timeline viewport (zoom).
  TimelineViewportController get viewport => container.read(viewportProvider(id));

  /// The live preview.
  PreviewSession get preview => session.preview ?? (throw StateError('no preview session'));

  /// Tracks of [kind].
  List<Track> tracksOf(TrackKind kind) => [for (final t in project.tracks) if (t.kind == kind) t];

  /// The main video track.
  Track get mainTrack => project.timeline.mainTrack ?? (throw StateError('no main track'));

  /// Every item of type [T] on the timeline.
  List<T> items<T extends TimelineItem>() => [
        for (final t in project.tracks)
          for (final i in t.items)
            if (i is T) i,
      ];

  /// The track holding [item].
  Track trackOf(ItemId item) => project.tracks.firstWhere((t) => t.items.any((i) => i.id == item));

  /// The item [item] as it is now.
  TimelineItem item(ItemId item) => project.tracks.expand((t) => t.items).firstWhere((i) => i.id == item);

  /// The media asset of [clip].
  MediaAsset assetOf(MediaClip clip) => project.pool[clip.media] ?? (throw StateError('no asset ${clip.media}'));

  /// Pumps until [ready] holds on the project.
  Future<void> waitProject(bool Function(EditProject p) ready, {required String what, Duration timeout = const Duration(seconds: 30)}) =>
      E2eApp.pumpUntil(tester, () => ready(project), what: what, timeout: timeout);

  // ---------------------------------------------------------------------------------------------
  // Editing
  // ---------------------------------------------------------------------------------------------

  /// The action context of the open editor (as a tool tile would build it).
  EditorActionContext context([EditorActionSource source = EditorActionSource.toolTile]) => WidgetActionContext.container(
        projectId: id,
        context: tester.element(find.byType(EditorScreen).last),
        container: container,
        source: source,
      );

  /// Runs [action] through the registry and expects it to run.
  Future<void> invoke(EditorActionId action, {EditorActionSource source = EditorActionSource.toolTile}) async {
    final registry = container.read(editorActionRegistryProvider);
    final ctx = context(source);
    final result = registry.invoke(action, ctx);
    expect(result, EditorActionResult.ran,
        reason: '${action.name}: ${result.name}${result == EditorActionResult.disabled ? ' (${registry.spec(action).disabledReason(ctx)})' : ''}');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Applies [command] (the command the panel for it issues) and expects it to change the project.
  EditResult apply(EditCommand command) {
    final r = controller.apply(command);
    expect(r, isNot(isA<EditRejected>()), reason: '${command.label}: $r');
    return r;
  }

  /// Selects [item] (as a tap on its tile does).
  Future<void> select(ItemId item, {SelectMode mode = SelectMode.replace}) async {
    controller.select(item, mode: mode);
    await tester.pump();
  }

  /// Taps the tool tile keyed `tile.<key>` (`split`, `tool.media`, …).
  Future<void> tapTile(String key) => E2eApp.tapKey(tester, 'tile.$key');

  // ---------------------------------------------------------------------------------------------
  // Time and frames
  // ---------------------------------------------------------------------------------------------

  /// Exact seek to frame [k] of the project; returns the engine's ack.
  Future<SeekAck?> seekFrame(int k) => seekTo(rate.timeOfFrame(k));

  /// Exact seek to [t]; returns the engine's ack.
  Future<SeekAck?> seekTo(TimeUs t) async {
    final ack = await E2eApp.pumpWhile(tester, playhead.seekExact(t), what: 'seek to $t');
    await E2eApp.pumpUntil(tester, () => !playhead.isSeeking, what: 'the seek to settle');
    return ack;
  }

  /// The project frame under the playhead.
  int get playheadFrame => rate.frameIndexOf(playhead.value);

  /// Captures the displayed frame.
  Future<E2eFrame> capture() async {
    final size = preview.frameSize.value;
    if (size == null) throw StateError('the preview has no frame size yet');
    final rgba = await E2eApp.pumpWhile(tester, preview.debugCaptureFrame(), what: 'debugCaptureFrame');
    return E2eFrame(rgba, size.width.round(), size.height.round());
  }

  /// The barcode of the displayed frame.
  Future<FrameBarcodeReading> barcode() async => (await capture()).barcode;

  /// Waits until playback stopped or started.
  Future<void> waitPlaying(bool playing) =>
      E2eApp.pumpUntil(tester, () => playhead.playing.value == playing, what: playing ? 'playback to start' : 'playback to stop');

  // ---------------------------------------------------------------------------------------------
  // Keyboard and pointer (scenario 12)
  // ---------------------------------------------------------------------------------------------

  /// Presses [key] with ⌘ (Command on Apple platforms, Ctrl elsewhere) and/or Shift.
  Future<void> key(LogicalKeyboardKey key, {bool command = false, bool shift = false}) async {
    final apple = defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS;
    final mod = apple ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
    if (command) await tester.sendKeyDownEvent(mod);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (command) await tester.sendKeyUpEvent(mod);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// The timeline view's area.
  Finder get timeline => find.byKey(const ValueKey('timeline-ruler-decoration')).evaluate().isEmpty
      ? find.byType(EditorScreen).last
      : find.ancestor(of: find.byKey(const ValueKey('timeline-ruler-decoration')), matching: find.byType(Stack)).first;

  /// A mouse wheel event at [at] with [dy] (and Shift/⌘ held when asked).
  Future<void> wheel(Offset at, double dy, {bool shift = false, bool command = false}) async {
    final apple = defaultTargetPlatform == TargetPlatform.iOS;
    final mod = apple ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
    if (command) await tester.sendKeyDownEvent(mod);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(at));
    await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (command) await tester.sendKeyUpEvent(mod);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// A secondary-button (right) click at [at].
  Future<void> rightClick(Offset at) async {
    final g = await tester.startGesture(at, kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// A mouse drag with the primary button from [from] to [to] (marquee, moves).
  Future<void> mouseDrag(Offset from, Offset to) async {
    final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await tester.pump(const Duration(milliseconds: 50));
    const steps = 12;
    for (var i = 1; i <= steps; i++) {
      await g.moveTo(Offset.lerp(from, to, i / steps)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
}
