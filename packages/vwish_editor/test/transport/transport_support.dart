// OWNER: UX-14
//
// Helpers for the playhead and transport tests: a manual ticker and clock (extrapolation tests
// run on fake time), and a scripted preview session whose seeks complete when the test says so
// and whose clock the test drives sample by sample.

import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:vwish_editor/src/editor/state/playhead_controller.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

/// A ticker that fires when a test calls [tick].
class ManualTicker implements PlayheadTicker {
  VoidCallback? _onFrame;
  bool _active = false;

  /// Frames delivered.
  int ticks = 0;

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

  /// Delivers one frame when active.
  void tick() {
    if (!_active) return;
    ticks++;
    _onFrame?.call();
  }
}

/// A clock tests advance.
class ManualClock {
  Duration _now = Duration.zero;

  /// The clock function.
  Duration call() => _now;

  /// Moves time forward.
  void advance(Duration d) => _now += d;
}

/// One call received by [ScriptedPreview].
class SeekCall {
  SeekCall(this.target, this.kind, this.completer);

  /// Requested time.
  final TimeUs target;

  /// Seek kind.
  final SeekKind kind;

  /// Completes the seek.
  final Completer<SeekAck> completer;
}

/// A preview whose seeks wait for [complete] and whose clock the test drives.
class ScriptedPreview implements PreviewSession {
  /// Creates the preview at 30 fps.
  ScriptedPreview({this.rate = FrameRate.fps30});

  /// Frame grid.
  final FrameRate rate;

  final StreamController<PreviewClock> _clock = StreamController<PreviewClock>.broadcast(sync: true);
  final StreamController<PreviewEvent> _events = StreamController<PreviewEvent>.broadcast(sync: true);

  /// Seeks received, in order.
  final List<SeekCall> seeks = [];

  /// Seeks that have not completed.
  final List<SeekCall> open = [];

  /// Largest number of seeks that were in flight together.
  int maxConcurrent = 0;

  /// Commands in order (`play`, `pause`, `seek`).
  final List<String> commands = [];

  /// Loop ranges passed to `play`.
  final List<TimeRange?> loops = [];

  /// Command sequence number.
  int seq = 0;

  /// Time of the displayed frame.
  TimeUs time = 0;

  /// Whether playing.
  bool playing = false;

  /// When set, `play` and `pause` throw it.
  Object? failCommands;

  /// Frames the displayed frame is off the requested one (exact seeks are exact by default).
  int displayOffsetFrames = 0;

  /// Whether seeks complete by themselves.
  bool autoComplete = false;

  @override
  int get textureId => 1;

  @override
  ValueListenable<Size?> get frameSize => ValueNotifier<Size?>(null);

  /// Emits a clock sample.
  void emit({required TimeUs at, required bool playing, int? seq, double rateOfPlay = 1}) {
    _clock.add(PreviewClock(time: at, playing: playing, rate: playing ? rateOfPlay : 0, seq: seq ?? this.seq));
  }

  /// Completes the oldest open seek like an engine: bumps `seq`, shows the frame, emits a sample
  /// and acknowledges.
  SeekAck complete([SeekCall? call]) {
    final c = call ?? open.first;
    open.remove(c);
    var k = rate.frameIndexOf(c.target) + displayOffsetFrames;
    if (k < 0) k = 0;
    time = rate.timeOfFrame(k);
    seq++;
    final ack = SeekAck(requested: c.target, displayedFrameTime: time, displayedFrame: k, seq: seq);
    _clock.add(PreviewClock(time: time, playing: playing, rate: playing ? 1 : 0, seq: seq));
    c.completer.complete(ack);
    return ack;
  }

  @override
  Future<SeekAck> seek(TimeUs t, {SeekKind kind = SeekKind.exact}) {
    commands.add('seek');
    final call = SeekCall(t, kind, Completer<SeekAck>());
    seeks.add(call);
    open.add(call);
    if (open.length > maxConcurrent) maxConcurrent = open.length;
    if (autoComplete) scheduleMicrotask(() => open.contains(call) ? complete(call) : null);
    return call.completer.future;
  }

  @override
  Future<void> play({TimeRange? loop}) async {
    commands.add('play');
    loops.add(loop);
    final failure = failCommands;
    if (failure != null) throw failure;
    playing = true;
    seq++;
    _clock.add(PreviewClock(time: time, playing: true, rate: 1, seq: seq));
  }

  @override
  Future<void> pause() async {
    commands.add('pause');
    final failure = failCommands;
    if (failure != null) throw failure;
    playing = false;
    seq++;
    _clock.add(PreviewClock(time: time, playing: false, rate: 0, seq: seq));
  }

  @override
  Stream<PreviewClock> get clock => _clock.stream;

  @override
  Stream<PreviewEvent> get events => _events.stream;

  @override
  Future<void> dispose() async {
    await _clock.close();
    await _events.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
