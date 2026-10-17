// OWNER: UX-14
//
// PlayheadController (ARCH §17.3, ux.md §7.8): the playhead as a `ValueListenable<TimeUs>` outside
// Riverpod state, so nothing in `EditorState` changes per playback frame.
//
// * Playing: every `PreviewClock` sample `(time, rate, seq)` is stamped with a monotonic clock on
//   receipt. A vsync ticker extrapolates `t = sample.time + elapsed * rate` and quantizes it to the
//   project frame; listeners are notified only when the frame index changes. A sample more than
//   one frame away from the extrapolation snaps the playhead to the sample, a closer one is slewed
//   in at most half a frame per tick and never moves the playhead backward.
// * Stale samples: samples whose `seq` is older than the last command (seek ack, play, pause) are
//   ignored, so a late "playing at 0:10" can't yank the playhead after the user seeked or paused.
//   While a seek is pending or in flight, or while scrubbing, clock samples don't move the
//   playhead: the seek decides.
// * Scrubbing: at most one seek is in flight. New targets replace the pending one (latest wins);
//   `scrub` seeks (fast, may show the nearest decodable frame) go out during the drag and one
//   `exact` seek on release; the playhead adopts `SeekAck.displayedFrameTime`, which makes seeking
//   frame-accurate.
// * Plan first (ENG-02 / API-02): an exact seek waits while the session's `PlanSync` has a plan or
//   patch in flight (compiling, applying, or scheduled) and goes out once it is acked. The engine
//   clamps a seek to the duration of the plan it holds, so a seek sent right after a paste or a
//   duplicate would otherwise land on the old last frame. Scrub seeks don't wait (they are
//   superseded by the exact seek on release).
// * The settled playhead (pause, seek ack, end of a scrub) is written to the project's `ViewState`
//   through `onSettled` (the provider wires `EditorController.updateView`): immediately after a
//   pause or a scrub, debounced during frame stepping. Never per frame.
//
// Consumers: the timeline's playhead layer and the centre-locked viewport follow (`value`), the
// transport bar's `TimecodeText`, keyframe toggles and the fullscreen preview. The viewport links
// with `attachPlayhead(playhead, playing: playhead.playing, onScrub: playhead.scrubTo,
// onScrubEnd: playhead.endScrub)`.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show FrameRate, ProjectId, TimeRange, TimeUs;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show PlanSync, PreviewClock, PreviewSession, SeekAck, SeekKind;

import '../../app/editor_providers.dart';
import 'editor_state.dart';

/// A monotonic clock (µs since an arbitrary start); injected so tests control time.
typedef PlayheadClock = Duration Function();

/// Calls a callback on every frame while started (a vsync `Ticker` in the app, a manual ticker in
/// tests).
abstract interface class PlayheadTicker {
  /// Starts calling [onFrame] every frame.
  void start(VoidCallback onFrame);

  /// Stops calling.
  void stop();

  /// Whether started.
  bool get isActive;

  /// Releases the ticker.
  void dispose();
}

/// The production ticker: a `Ticker` from [provider] (or a plain one).
final class VsyncPlayheadTicker implements PlayheadTicker {
  /// Creates the ticker. A [provider] lets `TickerMode` mute it.
  VsyncPlayheadTicker({TickerProvider? provider}) : _provider = provider ?? const _PlainTickerProvider();

  final TickerProvider _provider;
  Ticker? _ticker;
  VoidCallback? _onFrame;

  @override
  void start(VoidCallback onFrame) {
    _onFrame = onFrame;
    final ticker = _ticker ??= _provider.createTicker((_) => _onFrame?.call());
    if (!ticker.isActive) ticker.start();
  }

  @override
  void stop() {
    final ticker = _ticker;
    if (ticker != null && ticker.isActive) ticker.stop();
  }

  @override
  bool get isActive => _ticker?.isActive ?? false;

  @override
  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    _onFrame = null;
  }
}

final class _PlainTickerProvider implements TickerProvider {
  const _PlainTickerProvider();

  @override
  Ticker createTicker(TickerCallback onTick) => Ticker(onTick);
}

final class _SeekRequest {
  _SeekRequest(this.target, this.kind);

  TimeUs target;
  SeekKind kind;
  final List<Completer<SeekAck?>> waiters = [];
}

/// The playhead of one open project (ux.md §7.8).
class PlayheadController extends ChangeNotifier implements ValueListenable<TimeUs> {
  /// Creates a playhead at [initial] (quantized) on [frameRate]. [duration] bounds seeks.
  PlayheadController({
    required FrameRate frameRate,
    TimeUs initial = 0,
    TimeUs duration = 0,
    PlayheadTicker? ticker,
    PlayheadClock? clock,
    this.settleDelay = const Duration(milliseconds: 150),
    this.onSettled,
  })  : _rate = frameRate,
        _duration = duration < 0 ? 0 : duration,
        _ticker = ticker ?? VsyncPlayheadTicker(),
        _clock = clock ?? _stopwatchClock() {
    _value = _rate.quantize(initial < 0 ? 0 : initial);
    _pos = _value.toDouble();
    _persisted = _value;
  }

  static PlayheadClock _stopwatchClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  /// How long frame stepping waits before the new playhead is written to the project.
  final Duration settleDelay;

  /// Called with the settled playhead (never per frame). Wired to `EditorController.updateView`.
  final ValueChanged<TimeUs>? onSettled;

  final PlayheadTicker _ticker;
  final PlayheadClock _clock;

  FrameRate _rate;
  TimeUs _duration;
  late TimeUs _value;
  late TimeUs _persisted;
  bool _disposed = false;

  PreviewSession? _preview;
  PlanSync? _planSync;
  bool _waitingForPlan = false;
  StreamSubscription<PreviewClock>? _clockSub;
  int _generation = 0;

  final ValueNotifier<bool> _playing = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _scrubbing = ValueNotifier<bool>(false);

  // Extrapolation.
  bool _extrapolating = false;
  late double _pos;
  Duration _lastTick = Duration.zero;
  double _playRate = 1;
  double _drift = 0;

  // Sequence rules.
  int _maxSeen = -1;
  int _minAccept = 0;

  // Seeks.
  _SeekRequest? _inFlight;
  _SeekRequest? _pending;
  TimeUs? _scrubTarget;
  Timer? _settleTimer;

  // ---- State -----------------------------------------------------------------------------------

  /// The playhead, on the project's frame grid.
  @override
  TimeUs get value => _value;

  /// The project's frame rate.
  FrameRate get frameRate => _rate;

  /// The project duration seeks are clamped to.
  TimeUs get duration => _duration;

  /// Whether playback is running (confirmed by the engine, or requested and not yet refuted).
  ValueListenable<bool> get playing => _playing;

  /// Whether a scrub gesture is in progress.
  ValueListenable<bool> get scrubbing => _scrubbing;

  /// Whether a scrub gesture is in progress.
  bool get isScrubbing => _scrubbing.value;

  /// The preview the playhead drives, or null (not open, or the preview failed to start).
  PreviewSession? get preview => _preview;

  /// Whether a seek is waiting for the engine (or for the plan it must follow).
  bool get isSeeking => _inFlight != null || _pending != null;

  /// Whether an exact seek is held until the pending plan is acknowledged (tests).
  @visibleForTesting
  bool get isWaitingForPlan => _waitingForPlan;

  /// The sequence number below which clock samples are ignored (tests).
  @visibleForTesting
  int get minAcceptedSeq => _minAccept;

  // ---- Session link ----------------------------------------------------------------------------

  /// Drives [session]: listens to its clock and sends it seeks and play/pause. [initial] is the
  /// acknowledgement of the seek that positioned the preview (adopted as the playhead). Exact seeks
  /// wait for [planSync] (the session's plan sync) to be idle, see the file header.
  ///
  /// Without [initial] the session is new and its first command is the exact seek that positions
  /// it (the open's or "Restart preview"'s, seq 1): clock samples before it (seq 0, e.g. the one
  /// sent when the first plan is applied) show the session's start frame, not the playhead the
  /// project was saved with, so they are ignored (FIX-UX-14-1).
  void attach(PreviewSession session, {SeekAck? initial, PlanSync? planSync}) {
    if (_disposed) return;
    detach();
    _preview = session;
    _planSync = planSync;
    _generation++;
    _maxSeen = -1;
    _minAccept = initial == null ? 1 : 0;
    _clockSub = session.clock.listen(_onClock, onError: (Object _) {});
    if (initial != null) {
      _maxSeen = initial.seq;
      _minAccept = initial.seq;
      _setValue(_rate.quantize(initial.displayedFrameTime));
      _pos = _value.toDouble();
    }
  }

  /// Stops driving the preview (the editor closed or the preview was replaced).
  void detach() {
    if (_preview == null && _clockSub == null) return;
    _generation++;
    unawaited(_clockSub?.cancel());
    _clockSub = null;
    _preview = null;
    _planSync = null;
    _waitingForPlan = false;
    _stopExtrapolation();
    _setPlaying(false);
    _failSeeks();
  }

  /// Moves the playhead to [t] without seeking or saving (the session opened at [t]).
  void reset(TimeUs t) {
    if (_disposed) return;
    final q = _clamp(t);
    _pos = q.toDouble();
    _persisted = q;
    _setValue(q);
  }

  /// Updates the frame rate and duration (a project edit). A new frame rate requantizes the
  /// playhead; the playhead itself never moves because the duration changed.
  void setContent({FrameRate? frameRate, TimeUs? duration}) {
    if (_disposed) return;
    if (duration != null) _duration = duration < 0 ? 0 : duration;
    if (frameRate != null && frameRate != _rate) {
      _rate = frameRate;
      final q = _rate.quantize(_value);
      _pos = q.toDouble();
      _setValue(q);
    }
  }

  // ---- Clock samples ---------------------------------------------------------------------------

  void _onClock(PreviewClock sample) {
    if (_disposed) return;
    if (sample.seq > _maxSeen) _maxSeen = sample.seq;
    if (sample.seq < _minAccept) return;
    if (_scrubbing.value || isSeeking) return;
    final playing = sample.playing && sample.rate > 0;
    if (playing) {
      final now = _clock();
      if (_extrapolating) {
        _advance(now);
        final diff = sample.time.toDouble() - _pos;
        if (diff.abs() > _rate.frameUs) {
          _pos = sample.time.toDouble();
          _drift = 0;
        } else {
          _drift = diff;
        }
      } else {
        _pos = sample.time.toDouble();
        _drift = 0;
        _lastTick = now;
        _extrapolating = true;
      }
      _playRate = sample.rate;
      _setPlaying(true);
      _ticker.start(_onTick);
      _publishPos();
    } else {
      _stopExtrapolation();
      final wasPlaying = _playing.value;
      _setPlaying(false);
      final t = _clamp(sample.time);
      _pos = t.toDouble();
      _setValue(t);
      if (wasPlaying) {
        _settle(immediate: true);
      } else if (t != _persisted) {
        _settle();
      }
    }
  }

  void _onTick() {
    if (_disposed || !_extrapolating) return;
    _advance(_clock());
    _publishPos();
  }

  void _advance(Duration now) {
    final dt = (now - _lastTick).inMicroseconds;
    _lastTick = now;
    final half = _rate.frameUs / 2;
    final corr = _drift.clamp(-half, half).toDouble();
    _drift -= corr;
    var step = (dt < 0 ? 0 : dt) * _playRate + corr;
    if (step < 0) step = 0;
    _pos += step;
    if (_duration > 0 && _pos > _duration) _pos = _duration.toDouble();
  }

  void _publishPos() => _setValue(_rate.quantize(_pos.floor()));

  void _stopExtrapolation() {
    _extrapolating = false;
    _drift = 0;
    _ticker.stop();
  }

  // ---- Commands --------------------------------------------------------------------------------

  /// Starts playback (optionally looping [loop]) and shows it right away; a refused command is
  /// rolled back and rethrown.
  Future<void> play({TimeRange? loop}) async {
    final p = _preview;
    if (p == null || _disposed) return;
    final generation = _generation;
    _commandSent();
    _pos = _value.toDouble();
    _drift = 0;
    _playRate = 1;
    _lastTick = _clock();
    _extrapolating = true;
    _setPlaying(true);
    _ticker.start(_onTick);
    try {
      await p.play(loop: loop);
    } catch (_) {
      if (generation == _generation) {
        _stopExtrapolation();
        _setPlaying(false);
      }
      rethrow;
    }
  }

  /// Pauses playback and freezes the playhead on its current frame.
  Future<void> pause() async {
    final p = _preview;
    if (p == null || _disposed) return;
    _commandSent();
    _stopExtrapolation();
    _setPlaying(false);
    _settle(immediate: true);
    await p.pause();
  }

  /// Marks the start of a scrub: playback pauses.
  void beginScrub() {
    if (_disposed || _scrubbing.value) return;
    _scrubbing.value = true;
    _scrubTarget = null;
    if (_playing.value) unawaited(pause().catchError((Object _) {}));
  }

  /// Moves the playhead to [t] immediately and asks the engine for a (fast) scrub seek; at most
  /// one seek is in flight, the latest target wins. Starts the scrub when it hasn't begun.
  void scrubTo(TimeUs t) {
    if (_disposed) return;
    if (!_scrubbing.value) beginScrub();
    final q = _clamp(t);
    if (q == _scrubTarget) return;
    _scrubTarget = q;
    _pos = q.toDouble();
    _setValue(q);
    unawaited(_requestSeek(q, SeekKind.scrub));
  }

  /// Ends the scrub: one exact seek to the last target; the playhead adopts the displayed frame.
  Future<void> endScrub() async {
    if (_disposed || !_scrubbing.value) return;
    final target = _scrubTarget ?? _value;
    _scrubbing.value = false;
    _scrubTarget = null;
    await _requestSeek(target, SeekKind.exact);
    _settle(immediate: true);
  }

  /// Seeks exactly to [t] (frame step, keyboard, marker jump, timecode entry): the playhead moves
  /// at once and adopts `SeekAck.displayedFrameTime` when the frame is on screen. Returns the ack,
  /// or null without a preview or when superseded by a detach.
  Future<SeekAck?> seekExact(TimeUs t) {
    if (_disposed) return Future.value(null);
    final q = _clamp(t);
    _pos = q.toDouble();
    if (_extrapolating) {
      _lastTick = _clock();
      _drift = 0;
    }
    _setValue(q);
    final ack = _requestSeek(q, SeekKind.exact);
    if (_preview == null) _settle();
    return ack;
  }

  // ---- Seeks (≤ 1 in flight, latest wins) ------------------------------------------------------

  Future<SeekAck?> _requestSeek(TimeUs t, SeekKind kind) {
    final completer = Completer<SeekAck?>();
    if (_preview == null) {
      completer.complete(null);
      return completer.future;
    }
    final pending = _pending;
    if (pending == null) {
      _pending = _SeekRequest(t, kind)..waiters.add(completer);
    } else {
      pending.target = t;
      if (kind == SeekKind.exact) pending.kind = SeekKind.exact;
      pending.waiters.add(completer);
    }
    _pump();
    return completer.future;
  }

  void _pump() {
    final session = _preview;
    final request = _pending;
    if (session == null || request == null || _inFlight != null || _waitingForPlan) return;
    final sync = _planSync;
    if (request.kind == SeekKind.exact && sync != null && sync.busy) {
      // The engine still holds the previous plan (and its duration): seek once it is acked.
      _waitingForPlan = true;
      final generation = _generation;
      sync.flush().then<void>((_) {
        if (_disposed || generation != _generation) return;
        _waitingForPlan = false;
        _pump();
      });
      return;
    }
    _pending = null;
    _inFlight = request;
    final generation = _generation;
    Future<SeekAck> ack;
    try {
      ack = session.seek(request.target, kind: request.kind);
    } catch (e, s) {
      ack = Future<SeekAck>.error(e, s);
    }
    ack.then<void>((a) => _onAck(request, a, generation), onError: (Object e, StackTrace s) => _onSeekError(request, generation));
  }

  void _onAck(_SeekRequest request, SeekAck ack, int generation) {
    if (_disposed || generation != _generation) {
      _complete(request, null);
      return;
    }
    _inFlight = null;
    if (ack.seq > _maxSeen) _maxSeen = ack.seq;
    if (ack.seq > _minAccept) _minAccept = ack.seq;
    if (_pending == null && !_scrubbing.value) {
      final shown = _clamp(ack.displayedFrameTime);
      _pos = shown.toDouble();
      if (_extrapolating) {
        _lastTick = _clock();
        _drift = 0;
      }
      _setValue(shown);
      _settle();
    }
    _complete(request, ack);
    _pump();
  }

  void _onSeekError(_SeekRequest request, int generation) {
    if (_disposed || generation != _generation) {
      _complete(request, null);
      return;
    }
    _inFlight = null;
    _complete(request, null);
    _pump();
  }

  void _complete(_SeekRequest request, SeekAck? ack) {
    for (final w in request.waiters) {
      if (!w.isCompleted) w.complete(ack);
    }
  }

  void _failSeeks() {
    final flying = _inFlight;
    final pending = _pending;
    _inFlight = null;
    _pending = null;
    if (flying != null) _complete(flying, null);
    if (pending != null) _complete(pending, null);
  }

  // ---- Helpers ---------------------------------------------------------------------------------

  void _commandSent() {
    // Samples that predate this command must not decide the play state.
    _minAccept = _maxSeen + 1 > _minAccept ? _maxSeen + 1 : _minAccept;
  }

  TimeUs _clamp(TimeUs t) {
    var q = _rate.quantize(t < 0 ? 0 : t);
    if (q > _duration) q = _rate.quantize(_duration);
    return q;
  }

  void _setValue(TimeUs v) {
    if (v == _value || _disposed) return;
    _value = v;
    notifyListeners();
  }

  void _setPlaying(bool v) {
    if (_disposed) return;
    _playing.value = v;
  }

  void _settle({bool immediate = false}) {
    if (_disposed || onSettled == null) return;
    _settleTimer?.cancel();
    _settleTimer = null;
    if (immediate) {
      _writeSettled();
      return;
    }
    _settleTimer = Timer(settleDelay, _writeSettled);
  }

  void _writeSettled() {
    _settleTimer?.cancel();
    _settleTimer = null;
    if (_disposed || _value == _persisted) return;
    _persisted = _value;
    onSettled?.call(_value);
  }

  /// Writes a pending settle now (the editor is closing).
  void flushSettled() {
    if (_settleTimer != null) _writeSettled();
  }

  @override
  void dispose() {
    if (_disposed) return;
    flushSettled();
    _disposed = true;
    _generation++;
    _settleTimer?.cancel();
    unawaited(_clockSub?.cancel());
    _clockSub = null;
    _preview = null;
    _ticker.stop();
    _ticker.dispose();
    _failSeeks();
    _playing.dispose();
    _scrubbing.dispose();
    super.dispose();
  }

  @override
  String toString() => 'PlayheadController($_value, ${_playing.value ? 'playing' : 'paused'})';
}

/// Builds the value of `playheadProvider` for [id]: a playhead that follows the session's preview
/// (attached when the editor opens, replaced by "Restart preview", detached on close) and writes
/// the settled position to the project's view state. Kept alive until the editor has closed.
/// [ticker] and [clock] are for tests (a test overrides `playheadProvider` and passes manual ones).
PlayheadController createPlayheadController(Ref<Object?> ref, ProjectId id, {PlayheadTicker? ticker, PlayheadClock? clock}) {
  final session = ref.watch(editorSessionProvider(id));
  final editor = ref.watch(editorControllerProvider(id).notifier);
  final project = session.committedProject;
  final controller = PlayheadController(
    frameRate: project?.settings.frameRate ?? FrameRate.fps30,
    initial: project?.view.playhead ?? 0,
    duration: project?.duration ?? 0,
    ticker: ticker,
    clock: clock,
    onSettled: (t) => editor.updateView((v) => v.copyWith(playhead: t)),
  );
  // A settle still debounced when the editor saves on close (or the app is hidden) is written
  // first, so the reopened project starts on the frame it closed on (FIX-UX-14-1).
  final removeFlusher = editor.addViewFlusher(controller.flushSettled);
  var wasOpen = false;

  void sync() {
    final edit = session.editOrNull;
    if (edit == null) {
      wasOpen = false;
      if (controller.preview != null) controller.detach();
      return;
    }
    final committed = edit.committedProject;
    controller.setContent(frameRate: committed.settings.frameRate, duration: committed.duration);
    final opening = !wasOpen;
    if (opening) {
      wasOpen = true;
      controller.reset(committed.view.playhead);
    }
    final preview = session.preview;
    if (!identical(preview, controller.preview)) {
      if (preview == null) {
        controller.detach();
      } else {
        // The open's seek ack positions only the preview the editor opened with; a preview made by
        // "Restart preview" is positioned by its own first seek (seq 1, see `attach`).
        controller.attach(preview, initial: opening ? session.initialSeek : null, planSync: session.planSync);
      }
    }
  }

  session.attached.addListener(sync);
  ref.listen<(EditorPhase, PreviewPhase, TimeUs?)>(
    editorControllerProvider(id).select((s) => (s.phase, s.preview.phase, s.project?.duration)),
    (previous, next) => sync(),
  );
  sync();

  final link = ref.keepAlive();
  ref.listen<EditorPhase>(editorControllerProvider(id).select((s) => s.phase), (previous, next) {
    if (next == EditorPhase.closed || next == EditorPhase.failed) link.close();
  });

  ref.onDispose(() {
    removeFlusher();
    session.attached.removeListener(sync);
    controller.dispose();
  });
  return controller;
}
