// OWNER: ENG-01 (then ENG-06)
//
// Demultiplexes the single `EngineEventsApi.engineEvents` stream (ARCH §12.6) by sessionId / jobId
// and enforces the native rate limits again on the Dart side (defence in depth): preview clock
// <= 10 Hz, job and export progress <= 4 Hz, recorder levels <= 20 Hz.
//
// Rules:
// - Sample kinds (clock, progress, exportProgress, recorderLevel) are rate limited per route.
//   A sample that changes state passes at once (clock: seq, playing or rate; export: phase,
//   backgrounded, pausedInBackground or warnings; progress: reaching 1). Other samples within the
//   interval are coalesced: only the latest is kept and delivered when the interval ends, so the
//   last sample is never lost.
// - Every other kind passes at once, after any pending sample of the same route (order is kept).
// - Events for a route nobody listens to yet (the open/startJob reply and the first events race)
//   are buffered, coalesced, and replayed to the first listener. Unclaimed buffers expire after
//   [EngineEventRouter.unclaimedTtl] or when more than [EngineEventRouter.maxUnclaimedRoutes]
//   exist.
// - A job route ends with its first terminal event (`jobDone`, or `failure` carrying a jobId):
//   the stream closes and later events for that id are dropped. Session routes end with
//   [EngineEventRouter.release] (dispose); late events are dropped.

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'error_mapper.dart';
import 'pigeon/engine_api.g.dart';

/// Minimum intervals between delivered samples of one route (ARCH §12.6).
///
/// See ARCH §12.6, §12.2, §12.4.
@immutable
final class EventRateLimits {
  /// Creates limits. The defaults are the ARCH §12.6 native limits.
  const EventRateLimits({
    this.clock = const Duration(milliseconds: 100),
    this.progress = const Duration(milliseconds: 250),
    this.recorderLevel = const Duration(milliseconds: 50),
  });

  /// Preview clock samples (<= 10 Hz).
  final Duration clock;

  /// Job and export progress (<= 4 Hz).
  final Duration progress;

  /// Recorder input levels (<= 20 Hz).
  final Duration recorderLevel;
}

/// Routes engine events to preview sessions, jobs, recordings and leases, plus the engine-wide
/// signal and drop streams.
///
/// See ARCH §12.6, §12.1, BUILD_PLAN ENG-01.
final class EngineEventRouter {
  /// Creates a router over [source] (the generated `engineEvents()` stream in production).
  /// [now] is a monotonic clock (tests pass fake time); it defaults to a [Stopwatch].
  EngineEventRouter(
    Stream<EngineEventMsg> Function() source, {
    this.limits = const EventRateLimits(),
    Duration Function()? now,
    this.unclaimedTtl = const Duration(seconds: 60),
    this.maxUnclaimedRoutes = 64,
  })  : _source = source,
        _now = now ?? (Stopwatch()..start()).elapsedFunction;

  /// Rate limits.
  final EventRateLimits limits;

  /// How long events for a route nobody listens to are kept.
  final Duration unclaimedTtl;

  /// Most unclaimed routes kept at once (oldest evicted first).
  final int maxUnclaimedRoutes;

  /// Most events buffered for one unclaimed route (oldest dropped first, after coalescing).
  static const int maxBufferedPerRoute = 64;

  /// How many ended job ids and released session ids are remembered to drop late events.
  static const int endedIdMemory = 256;

  final Stream<EngineEventMsg> Function() _source;
  final Duration Function() _now;
  StreamSubscription<EngineEventMsg>? _subscription;
  bool _disposed = false;

  final Map<String, _Route> _sessions = {};
  final Map<String, _Route> _jobs = {};
  final _EndedIds _endedSessions = _EndedIds(endedIdMemory);
  final _EndedIds _endedJobs = _EndedIds(endedIdMemory);

  final StreamController<SignalMsg> _signals = StreamController<SignalMsg>.broadcast();
  final StreamController<DropMsg> _drops = StreamController<DropMsg>.broadcast();
  final StreamController<EngineFailure> _failures = StreamController<EngineFailure>.broadcast();

  /// Whether the source stream is subscribed.
  bool get isStarted => _subscription != null;

  /// Subscribes to the source (idempotent). MobileEditorEngine calls it once the native engine
  /// answered `initialize`, so a missing plugin never sees a `listen` call.
  void start() {
    if (_disposed || _subscription != null) return;
    _subscription = _source().listen(
      _onEvent,
      onError: (Object error, StackTrace stack) => _failures.add(mapEngineError(error)),
      onDone: () => _subscription = null,
    );
  }

  /// Events of preview session [sessionId]: `clock`, `preview` and session `failure` events.
  /// Buffered events are replayed to the first listener.
  Stream<EngineEventMsg> session(String sessionId) {
    _endedSessions.remove(sessionId);
    return _route(_sessions, sessionId, isJob: false).controller.stream;
  }

  /// Events of job [jobId] (media job, export, recording or background lease): `progress`,
  /// `exportProgress`, `recorderLevel`, `interruption`, `leaseExpiring`, and the terminal
  /// `jobDone` / `failure`, after which the stream closes.
  Stream<EngineEventMsg> job(String jobId) {
    if (_endedJobs.contains(jobId)) return const Stream<EngineEventMsg>.empty();
    return _route(_jobs, jobId, isJob: true).controller.stream;
  }

  /// Stops routing events for [id] (a disposed session, a cancelled recording or a released
  /// lease): closes its stream, drops its buffer, and drops late events.
  void release(String id) {
    final session = _sessions.remove(id);
    if (session != null) {
      _endedSessions.add(id);
      session.close();
    }
    final job = _jobs.remove(id);
    if (job != null) {
      _endedJobs.add(id);
      job.close();
    }
  }

  /// Engine-wide memory and thermal signals.
  Stream<SignalMsg> get signals => _signals.stream;

  /// External drops (D-18).
  Stream<DropMsg> get drops => _drops.stream;

  /// Errors raised on the event channel itself and failures that name no session or job.
  Stream<EngineFailure> get failures => _failures.stream;

  /// Number of routes with buffered events nobody listens to (diagnostics and tests).
  @visibleForTesting
  int get unclaimedRouteCount =>
      _sessions.values.where((r) => !r.controller.hasListener).length + _jobs.values.where((r) => !r.controller.hasListener).length;

  /// Cancels the source subscription and closes every stream.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final sub = _subscription;
    _subscription = null;
    for (final r in [..._sessions.values, ..._jobs.values]) {
      r.close();
    }
    _sessions.clear();
    _jobs.clear();
    await sub?.cancel();
    await Future.wait([_signals.close(), _drops.close(), _failures.close()]);
  }

  _Route _route(Map<String, _Route> routes, String id, {required bool isJob}) {
    final existing = routes[id];
    if (existing != null && !existing.closed) return existing;
    final route = _Route(this, id, isJob: isJob, routes: routes, createdAt: _now());
    routes[id] = route;
    return route;
  }

  void _onEvent(EngineEventMsg event) {
    _sweepUnclaimed();
    switch (event.kind) {
      case EngineEventKindMsg.clock:
      case EngineEventKindMsg.preview:
        _toSession(event);
      case EngineEventKindMsg.failure:
        if (event.jobId != null) {
          _toJob(event);
        } else if (event.sessionId != null) {
          _toSession(event);
        } else if (event.failure case final f?) {
          _failures.add(failureFromMsg(f));
        }
      case EngineEventKindMsg.progress:
      case EngineEventKindMsg.jobDone:
      case EngineEventKindMsg.exportProgress:
      case EngineEventKindMsg.recorderLevel:
      case EngineEventKindMsg.interruption:
      case EngineEventKindMsg.leaseExpiring:
        _toJob(event);
      case EngineEventKindMsg.signal:
        if (event.signal case final s?) _signals.add(s);
      case EngineEventKindMsg.drop:
        if (event.drop case final d?) _drops.add(d);
    }
  }

  void _toSession(EngineEventMsg event) {
    final id = event.sessionId;
    if (id == null || _endedSessions.contains(id) || !_hasPayload(event)) return;
    _route(_sessions, id, isJob: false).accept(event);
  }

  void _toJob(EngineEventMsg event) {
    final id = event.jobId;
    if (id == null || _endedJobs.contains(id) || !_hasPayload(event)) return;
    _route(_jobs, id, isJob: true).accept(event);
  }

  void _ended(_Route route) {
    if (route.routes[route.id] == route) route.routes.remove(route.id);
    (route.isJob ? _endedJobs : _endedSessions).add(route.id);
  }

  /// Drops unclaimed routes that are too old, then the oldest ones above the cap.
  void _sweepUnclaimed() {
    final now = _now();
    final unclaimed = <_Route>[
      for (final r in _sessions.values)
        if (!r.controller.hasListener && !r.everListened) r,
      for (final r in _jobs.values)
        if (!r.controller.hasListener && !r.everListened) r,
    ];
    if (unclaimed.isEmpty) return;
    unclaimed.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    var excess = unclaimed.length - maxUnclaimedRoutes;
    for (final r in unclaimed) {
      if (excess > 0 || now - r.createdAt > unclaimedTtl) {
        excess--;
        r.routes.remove(r.id);
        r.close();
      }
    }
  }
}

bool _hasPayload(EngineEventMsg e) => switch (e.kind) {
      EngineEventKindMsg.clock => e.clock != null,
      EngineEventKindMsg.preview => e.previewEvent != null,
      EngineEventKindMsg.progress => e.progress != null,
      EngineEventKindMsg.jobDone => e.jobDone != null,
      EngineEventKindMsg.failure => e.failure != null,
      EngineEventKindMsg.exportProgress => e.exportProgress != null,
      EngineEventKindMsg.recorderLevel => e.recorderLevel != null,
      EngineEventKindMsg.interruption => e.interruption != null,
      EngineEventKindMsg.leaseExpiring => true,
      EngineEventKindMsg.signal => e.signal != null,
      EngineEventKindMsg.drop => e.drop != null,
    };

/// The rate-limited sample kinds.
bool _isSample(EngineEventKindMsg kind) =>
    kind == EngineEventKindMsg.clock ||
    kind == EngineEventKindMsg.progress ||
    kind == EngineEventKindMsg.exportProgress ||
    kind == EngineEventKindMsg.recorderLevel;

/// Whether [next] carries a state change relative to [previous] (then it is never delayed).
bool _isStateChange(EngineEventMsg? previous, EngineEventMsg next) {
  if (previous == null) return true;
  switch (next.kind) {
    case EngineEventKindMsg.clock:
      final a = previous.clock!, b = next.clock!;
      return a.seq != b.seq || a.playing != b.playing || a.rate != b.rate;
    case EngineEventKindMsg.exportProgress:
      final a = previous.exportProgress!, b = next.exportProgress!;
      return a.phase != b.phase ||
          a.backgrounded != b.backgrounded ||
          a.pausedInBackground != b.pausedInBackground ||
          a.warnings.length != b.warnings.length ||
          b.fraction >= 1;
    case EngineEventKindMsg.progress:
      return next.progress! >= 1;
    default:
      return false;
  }
}

bool _isTerminal(EngineEventMsg e) => e.kind == EngineEventKindMsg.jobDone || (e.kind == EngineEventKindMsg.failure && e.jobId != null);

/// Per-kind throttle state of one route.
final class _Throttle {
  EngineEventMsg? lastSent;
  Duration? lastSentAt;
  EngineEventMsg? pending;
  Timer? timer;
}

final class _Route {
  _Route(this.router, this.id, {required this.isJob, required this.routes, required this.createdAt}) {
    controller = StreamController<EngineEventMsg>.broadcast(onListen: _onListen);
  }

  final EngineEventRouter router;
  final String id;
  final bool isJob;
  final Map<String, _Route> routes;
  final Duration createdAt;
  late final StreamController<EngineEventMsg> controller;
  final Queue<EngineEventMsg> _buffer = Queue<EngineEventMsg>();
  final Map<EngineEventKindMsg, _Throttle> _throttles = {};
  bool everListened = false;
  bool closed = false;
  bool _terminated = false;

  void accept(EngineEventMsg event) {
    if (closed || _terminated) return;
    if (!controller.hasListener) {
      _bufferEvent(event);
      return;
    }
    _deliver(event);
  }

  void _bufferEvent(EngineEventMsg event) {
    if (_isSample(event.kind) && _buffer.isNotEmpty) {
      final last = _buffer.last;
      if (last.kind == event.kind && !_isStateChange(last, event)) _buffer.removeLast();
    }
    _buffer.add(event);
    while (_buffer.length > EngineEventRouter.maxBufferedPerRoute) {
      _buffer.removeFirst();
    }
    if (_isTerminal(event)) _terminated = true;
  }

  void _onListen() {
    everListened = true;
    final replay = _buffer.toList();
    _buffer.clear();
    _terminated = false;
    for (final e in replay) {
      _deliver(e);
      if (closed) return;
    }
  }

  void _deliver(EngineEventMsg event) {
    if (_isSample(event.kind)) {
      _sample(event);
      return;
    }
    _flushPending();
    controller.add(event);
    if (isJob && _isTerminal(event)) {
      _terminated = true;
      router._ended(this);
      close();
    }
  }

  Duration _interval(EngineEventKindMsg kind) => switch (kind) {
        EngineEventKindMsg.clock => router.limits.clock,
        EngineEventKindMsg.recorderLevel => router.limits.recorderLevel,
        _ => router.limits.progress,
      };

  void _sample(EngineEventMsg event) {
    final t = _throttles.putIfAbsent(event.kind, _Throttle.new);
    final now = router._now();
    final reference = t.pending ?? t.lastSent;
    final due = t.lastSentAt == null || now - t.lastSentAt! >= _interval(event.kind);
    if (_isStateChange(reference, event) || due) {
      // The pending sample (if any) is older than [event] and superseded by it.
      t.timer?.cancel();
      t.timer = null;
      t.pending = null;
      _send(t, event, now);
      return;
    }
    t.pending = event;
    t.timer ??= Timer(t.lastSentAt! + _interval(event.kind) - now, () => _firePending(t));
  }

  void _firePending(_Throttle t) {
    t.timer = null;
    final p = t.pending;
    t.pending = null;
    if (p != null && !closed) _send(t, p, router._now());
  }

  void _send(_Throttle t, EngineEventMsg event, Duration now) {
    t.lastSent = event;
    t.lastSentAt = now;
    controller.add(event);
  }

  void _flushPending() {
    for (final t in _throttles.values) {
      final p = t.pending;
      t.timer?.cancel();
      t.timer = null;
      t.pending = null;
      if (p != null) _send(t, p, router._now());
    }
  }

  void close() {
    if (closed) return;
    closed = true;
    for (final t in _throttles.values) {
      t.timer?.cancel();
    }
    _throttles.clear();
    _buffer.clear();
    unawaited(controller.close());
  }
}

/// A bounded set of ids remembered in insertion order.
final class _EndedIds {
  _EndedIds(this.capacity);

  final int capacity;
  final LinkedHashSet<String> _ids = LinkedHashSet<String>();

  bool contains(String id) => _ids.contains(id);

  void add(String id) {
    _ids.remove(id);
    _ids.add(id);
    while (_ids.length > capacity) {
      _ids.remove(_ids.first);
    }
  }

  void remove(String id) => _ids.remove(id);
}

extension on Stopwatch {
  Duration Function() get elapsedFunction => () => elapsed;
}
