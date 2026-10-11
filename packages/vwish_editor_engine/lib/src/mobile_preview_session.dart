// OWNER: ENG-02
//
// MobilePreviewSession: the Dart side of one native preview session over `PreviewHostApi`
// (ARCH §12.2, §12.6, §12.7, §13). MobileEditorEngine.openPreview calls `PreviewHostApi.open` and
// constructs this class with the reply.
//
// Rules implemented here:
// - Plans and patches cross the channel as UTF-8 JSON bytes (`PlanTransport`, API-02; encoded in
//   an isolate above `PlanTransport.isolateThreshold` objects). Plan sends are serialized, so a
//   large plan encoded in an isolate is never overtaken by a later small patch. Acks are mapped
//   with `PlanTransport.ackOf`; a malformed ack is an `internal` failure. A native
//   `planOutOfSync` error (and an ack whose revision is not the one sent) surfaces as
//   `EngineFailure(planOutOfSync)`, which PlanSync answers with one full `setPlan`.
// - Transients are fire-and-forget and coalesced per item to one per project frame on the Dart
//   side (leading send, then the latest value at the end of the frame); `clearTransient` drops a
//   pending one. Transient failures are ignored (the next commit re-syncs the plan).
// - Seeks: exact seeks are sent at once. At most one scrub seek is in flight; scrubs requested
//   meanwhile collapse into one pending scrub (latest time wins). A scrub that never reaches
//   native completes with the ack of the seek that superseded it (the next scrub or an exact
//   seek), or with the in-flight scrub's ack when play/pause dropped it.
// - Clock (seq rules of ARCH §12.2): every play, pause and seek reply carries the command seq.
//   Samples older than the newest known command seq, and samples whose seq goes backwards, are
//   dropped, so a late 10 Hz "playing" sample never follows a pause.
// - Events: firstFrame/frameSize update [frameSize]; firstFrame, stalled, recovered,
//   degraded(q), surfaceLost and failed(f) are forwarded; a session `failure` event becomes
//   `PreviewFailedEvent`. Clock and events that arrive before anyone listens are replayed to the
//   first listener (the latest clock sample; up to [MobilePreviewSession.maxBufferedEvents]
//   events).
// - dispose is idempotent: it releases the event route first (late events are dropped),
//   completes every in-flight call with `EngineCancelled` (late native replies are ignored),
//   then asks native to release the session and its texture. Calls after dispose fail with
//   `EngineCancelled`; transients after dispose are ignored.

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' show Color, Offset, Size;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier, visibleForTesting;
import 'package:vwish_editor_core/model.dart' show ItemId, TimeRange, TimeUs;
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

import 'error_mapper.dart';
import 'pigeon/conversions.dart';
import 'pigeon/engine_api.g.dart';
import 'pigeon/engine_channels.dart';

/// A live preview over `PreviewHostApi` (ARCH §12.2, ENG-02).
///
/// See ARCH §12.2, §12.6, §12.7, §13, BUILD_PLAN ENG-02.
final class MobilePreviewSession implements PreviewSession {
  /// Wraps native session [sessionId], bound to [textureId] and opened with [config].
  ///
  /// [transientInterval] overrides the Dart-side transient coalescing interval (one project
  /// frame of `config.fps` by default; tests).
  MobilePreviewSession({
    required EngineChannels channels,
    required PreviewConfig config,
    required String sessionId,
    required int textureId,
    @visibleForTesting Duration? transientInterval,
  })  : _channels = channels,
        _config = config,
        _sessionId = sessionId,
        _textureId = textureId,
        _transientInterval = transientInterval ?? Duration(microseconds: (1000000 / (config.fps < 1 ? 30 : config.fps)).round()) {
    _clock = StreamController<PreviewClock>.broadcast(onListen: _replayClock);
    _events = StreamController<PreviewEvent>.broadcast(onListen: _replayEvents);
    _route = channels.router.session(sessionId).listen(_onEngineEvent);
  }

  /// Most events kept for a first [events] listener.
  static const int maxBufferedEvents = 16;

  final EngineChannels _channels;
  final PreviewConfig _config;
  final String _sessionId;
  final int _textureId;
  final Duration _transientInterval;

  late final StreamController<PreviewClock> _clock;
  late final StreamController<PreviewEvent> _events;
  late final StreamSubscription<EngineEventMsg> _route;
  final ValueNotifier<Size?> _frameSize = ValueNotifier<Size?>(null);

  PreviewClock? _unclaimedClock;
  final Queue<PreviewEvent> _unclaimedEvents = Queue<PreviewEvent>();

  // Seq rules.
  int _minSeq = -1;
  int _lastClockSeq = -1;

  // Plan sends, serialized.
  Future<void> _planChain = Future<void>.value();

  // Calls waiting for a native reply (completed with EngineCancelled by dispose).
  final Set<Completer<Object?>> _inFlight = {};

  // Scrub coalescing.
  _ScrubRequest? _scrubFlying;
  _ScrubRequest? _scrubPending;

  // Transient coalescing per item.
  final Map<String, _TransientSlot> _transients = {};

  bool _disposed = false;
  Future<void>? _disposing;

  /// Config the session was opened with.
  PreviewConfig get config => _config;

  /// Native session id.
  String get sessionId => _sessionId;

  /// Whether [dispose] was called.
  bool get isDisposed => _disposed;

  /// Highest command seq known from play/pause/seek replies (-1 before the first command).
  @visibleForTesting
  int get lastCommandSeq => _minSeq;

  @override
  int get textureId => _textureId;

  @override
  ValueListenable<Size?> get frameSize => _frameSize;

  // ---- Plans -----------------------------------------------------------------------------------

  @override
  Future<PlanAck> setPlan(RenderPlan plan) => _serialized(() async {
        final bytes = await PlanTransport.encodePlan(plan);
        final ack = _ackOf(await _call(() => _channels.preview.setPlan(_sessionId, bytes)));
        if (ack.rev != plan.rev) {
          throw EngineFailure.of(EngineErrorCode.planOutOfSync, debugDetail: 'setPlan acked rev ${ack.rev}, sent ${plan.rev}');
        }
        return ack;
      });

  @override
  Future<PlanAck> applyPatch(RenderPlanPatch patch) => _serialized(() async {
        final bytes = await PlanTransport.encodePatch(patch);
        final ack = _ackOf(await _call(() => _channels.preview.applyPatch(_sessionId, bytes)));
        if (ack.rev != patch.to) {
          throw EngineFailure.of(EngineErrorCode.planOutOfSync, debugDetail: 'applyPatch acked rev ${ack.rev}, expected ${patch.to}');
        }
        return ack;
      });

  Future<PlanAck> _serialized(Future<PlanAck> Function() body) {
    if (_disposed) return Future<PlanAck>.error(_cancelled());
    final result = _planChain.then((_) {
      if (_disposed) throw _cancelled();
      return body();
    });
    _planChain = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  PlanAck _ackOf(PlanAckMsg m) {
    try {
      return PlanTransport.ackOf(rev: m.rev, structural: m.structural, applyMs: m.applyMs);
    } on FormatException catch (e) {
      throw EngineFailure.of(EngineErrorCode.internal, debugDetail: e.message);
    }
  }

  // ---- Transients ------------------------------------------------------------------------------

  @override
  void setTransient(ItemId item, PlanTransient transient) {
    if (_disposed) return;
    final slot = _transients.putIfAbsent(item, _TransientSlot.new);
    if (slot.timer == null) {
      _sendTransient(item, transient);
      slot.timer = Timer(_transientInterval, () => _onTransientFrame(item));
    } else {
      slot.pending = transient;
    }
  }

  void _onTransientFrame(String item) {
    final slot = _transients[item];
    if (slot == null) return;
    slot.timer = null;
    final pending = slot.pending;
    slot.pending = null;
    if (pending == null || _disposed) {
      _transients.remove(item);
      return;
    }
    _sendTransient(item, pending);
    slot.timer = Timer(_transientInterval, () => _onTransientFrame(item));
  }

  void _sendTransient(String item, PlanTransient transient) {
    final Uint8List bytes;
    try {
      bytes = PlanTransport.encodeTransient(transient);
    } on Object {
      return;
    }
    _fireAndForget(() => _channels.preview.setTransient(_sessionId, item, bytes));
  }

  @override
  void clearTransient(ItemId item) {
    if (_disposed) return;
    _transients.remove(item)?.timer?.cancel();
    _fireAndForget(() => _channels.preview.clearTransient(_sessionId, item));
  }

  void _fireAndForget(Future<void> Function() call) {
    unawaited(_channels.invoke(call).then<void>((_) {}, onError: (Object _) {}));
  }

  // ---- Transport commands ----------------------------------------------------------------------

  @override
  Future<void> play({TimeRange? loop}) async {
    _dropPendingScrub();
    _noteCommandSeq(await _call(() => _channels.preview.play(_sessionId, loop == null ? null : loopToMsg(loop))));
  }

  @override
  Future<void> pause() async {
    _dropPendingScrub();
    _noteCommandSeq(await _call(() => _channels.preview.pause(_sessionId)));
  }

  @override
  Future<SeekAck> seek(TimeUs t, {SeekKind kind = SeekKind.exact}) {
    if (_disposed) return Future<SeekAck>.error(_cancelled());
    if (kind == SeekKind.scrub) return _scrub(t);
    final ack = _sendSeek(t, exact: true);
    final superseded = _scrubPending;
    if (superseded != null) {
      _scrubPending = null;
      superseded.follow(ack);
    }
    return ack;
  }

  Future<SeekAck> _sendSeek(TimeUs t, {required bool exact}) async {
    final ack = seekAckFromMsg(await _call(() => _channels.preview.seek(_sessionId, t, exact)));
    _noteCommandSeq(ack.seq);
    return ack;
  }

  Future<SeekAck> _scrub(TimeUs t) {
    final waiter = Completer<SeekAck>();
    if (_scrubFlying == null) {
      _startScrub(_ScrubRequest(t)..waiters.add(waiter));
    } else {
      final pending = _scrubPending ??= _ScrubRequest(t);
      pending
        ..time = t
        ..waiters.add(waiter);
    }
    return waiter.future;
  }

  void _startScrub(_ScrubRequest request) {
    _scrubFlying = request;
    final ack = request.sent = _sendSeek(request.time, exact: false);
    request.follow(ack);
    ack.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      if (!identical(_scrubFlying, request)) return;
      _scrubFlying = null;
      final next = _scrubPending;
      _scrubPending = null;
      if (next != null && !_disposed) _startScrub(next);
    });
  }

  /// play/pause supersede a scrub that has not been sent: its waiters get the in-flight scrub's
  /// ack instead.
  void _dropPendingScrub() {
    final pending = _scrubPending;
    final flying = _scrubFlying;
    final sent = flying?.sent;
    if (pending == null || sent == null) return;
    _scrubPending = null;
    pending.follow(sent);
  }

  void _noteCommandSeq(int seq) {
    if (seq > _minSeq) _minSeq = seq;
  }

  // ---- Other calls -----------------------------------------------------------------------------

  @override
  Future<void> setQuality(PreviewQuality quality) => _call(() => _channels.preview.setQuality(_sessionId, previewQualityToMsg(quality)));

  @override
  Future<void> setUseProxies(bool on) => _call(() => _channels.preview.setUseProxies(_sessionId, on));

  @override
  Future<void> setEditingMode(PreviewEditingMode mode) => _call(() => _channels.preview.setEditingMode(_sessionId, editingModeToMsg(mode)));

  @override
  Future<void> showSourceFrame(EngineMedia media, TimeUs sourceTime) =>
      _call(() => _channels.preview.showSourceFrame(_sessionId, mediaToMsg(media), sourceTime));

  @override
  Future<Color?> sampleColor(ItemId item, Offset normalizedSourcePoint) async {
    final msg = await _call(() => _channels.preview.sampleColor(_sessionId, item, normalizedSourcePoint.dx, normalizedSourcePoint.dy));
    return msg == null ? null : colorFromMsg(msg);
  }

  @override
  Future<List<Uint8List>> renderLookStills(ItemId item, List<LookSpec> looks, {required int heightPx}) =>
      _call(() => _channels.preview.renderLookStills(_sessionId, item, [for (final l in looks) lookSpecToMsg(l)], heightPx));

  @override
  Future<void> refresh() => _call(() => _channels.preview.refresh(_sessionId));

  @override
  Future<Uint8List> debugCaptureFrame() => _call(() => _channels.preview.debugCaptureFrame(_sessionId));

  /// Runs a native call: typed failures, tracked so [dispose] can cancel it.
  Future<T> _call<T>(Future<T> Function() call) {
    if (_disposed) return Future<T>.error(_cancelled());
    final completer = Completer<T>();
    _inFlight.add(completer);
    _channels.invoke(call).then<void>(
      (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!completer.isCompleted) completer.completeError(mapEngineError(error), stack);
      },
    ).whenComplete(() => _inFlight.remove(completer));
    return completer.future;
  }

  EngineCancelled _cancelled() => const EngineCancelled(debugDetail: 'preview session disposed');

  // ---- Clock and events ------------------------------------------------------------------------

  @override
  Stream<PreviewClock> get clock => _clock.stream;

  @override
  Stream<PreviewEvent> get events => _events.stream;

  void _onEngineEvent(EngineEventMsg msg) {
    if (_disposed) return;
    switch (msg.kind) {
      case EngineEventKindMsg.clock:
        if (msg.clock case final c?) _onClock(clockFromMsg(c));
      case EngineEventKindMsg.preview:
        if (msg.previewEvent case final e?) _onPreviewEvent(e);
      case EngineEventKindMsg.failure:
        if (msg.failure case final f?) _emitEvent(PreviewFailedEvent(failureFromMsg(f)));
      default:
        break;
    }
  }

  void _onClock(PreviewClock sample) {
    if (sample.seq < _minSeq || sample.seq < _lastClockSeq) return;
    _lastClockSeq = sample.seq;
    if (_clock.hasListener) {
      _clock.add(sample);
    } else {
      _unclaimedClock = sample;
    }
  }

  void _onPreviewEvent(PreviewEventMsg msg) {
    if (msg.kind == PreviewEventKindMsg.firstFrame || msg.kind == PreviewEventKindMsg.frameSize) {
      final size = frameSizeFromMsg(msg);
      if (size != null) _frameSize.value = size;
    }
    final event = previewEventFromMsg(msg);
    if (event != null) _emitEvent(event);
  }

  void _emitEvent(PreviewEvent event) {
    if (_events.hasListener) {
      _events.add(event);
      return;
    }
    _unclaimedEvents.add(event);
    while (_unclaimedEvents.length > maxBufferedEvents) {
      _unclaimedEvents.removeFirst();
    }
  }

  void _replayClock() {
    final sample = _unclaimedClock;
    _unclaimedClock = null;
    // Re-check against commands sent since it was buffered.
    if (sample != null && !_disposed && sample.seq >= _minSeq) _clock.add(sample);
  }

  void _replayEvents() {
    final replay = _unclaimedEvents.toList();
    _unclaimedEvents.clear();
    if (_disposed) return;
    replay.forEach(_events.add);
  }

  // ---- Dispose ---------------------------------------------------------------------------------

  @override
  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _channels.router.release(_sessionId);
    await _route.cancel();
    for (final slot in _transients.values) {
      slot.timer?.cancel();
    }
    _transients.clear();
    final cancelled = _cancelled();
    final waiting = _inFlight.toList();
    _inFlight.clear();
    for (final c in waiting) {
      if (!c.isCompleted) c.completeError(cancelled);
    }
    final pending = _scrubPending;
    _scrubPending = null;
    _scrubFlying = null;
    pending?.fail(cancelled);
    _unclaimedClock = null;
    _unclaimedEvents.clear();
    unawaited(_clock.close());
    unawaited(_events.close());
    try {
      await _channels.invoke(() => _channels.preview.dispose(_sessionId));
    } on EngineFailure {
      // Native already released it (or the engine is gone); nothing left to release.
    }
  }
}

/// One coalesced scrub seek and everybody waiting for it.
final class _ScrubRequest {
  _ScrubRequest(this.time);

  TimeUs time;
  final List<Completer<SeekAck>> waiters = [];

  /// The native seek once sent.
  Future<SeekAck>? sent;

  /// Completes every waiter with the result of [ack].
  void follow(Future<SeekAck> ack) {
    ack.then<void>((a) {
      for (final w in waiters) {
        if (!w.isCompleted) w.complete(a);
      }
    }, onError: (Object e, StackTrace s) {
      for (final w in waiters) {
        if (!w.isCompleted) w.completeError(e, s);
      }
    });
  }

  void fail(Object error) {
    for (final w in waiters) {
      if (!w.isCompleted) w.completeError(error);
    }
  }
}

/// Coalescing state of one item's transients.
final class _TransientSlot {
  Timer? timer;
  PlanTransient? pending;
}
