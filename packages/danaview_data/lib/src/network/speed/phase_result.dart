// OWNER: ST-01
//
// What one phase of a speed test produces, how it reports progress, and how it fails (V2-401).
// Shared by every [SpeedTestProvider]; the facade (`speed_test.dart`) and the coordinator (ST-03)
// read these and nothing provider-specific.

import '../speed_test.dart' show SpeedTestPhase;

/// Why a provider could not finish a phase. The coordinator (ST-03) fails over on [rateLimited],
/// [forbidden], [unreachable] and [stalled].
enum SpeedFailureKind {
  /// HTTP 429.
  rateLimited,

  /// HTTP 403.
  forbidden,

  /// The connection never opened: DNS, refused, no route, or a failed TLS handshake.
  unreachable,

  /// No answer, or no bytes moving, within the timeout.
  stalled,

  /// Any other HTTP error status.
  serverError,

  /// A connection that was up and then broke mid-phase.
  interrupted,
}

/// A phase failed. [cause] is the underlying error (a [SocketException], a [TimeoutException], or
/// a `SpeedTestException` for an HTTP status), kept so the facade can word it exactly as v1.0 did.
class SpeedProviderFailure implements Exception {
  const SpeedProviderFailure({
    required this.kind,
    required this.phase,
    required this.providerId,
    required this.cause,
    this.status,
  });

  final SpeedFailureKind kind;
  final SpeedTestPhase phase;
  final String providerId;
  final Object cause;

  /// The HTTP status, when the server answered with an error.
  final int? status;

  /// The kind of failure an HTTP [status] stands for.
  static SpeedFailureKind kindForStatus(int status) => switch (status) {
        429 => SpeedFailureKind.rateLimited,
        403 => SpeedFailureKind.forbidden,
        _ => SpeedFailureKind.serverError,
      };

  @override
  String toString() =>
      'SpeedProviderFailure($providerId, ${phase.name}, ${kind.name}${status == null ? '' : ', HTTP $status'}): $cause';
}

/// The phase stopped because its cancel token fired. Never shown to the user.
class SpeedTestCancelled implements Exception {
  const SpeedTestCancelled();

  @override
  String toString() => 'SpeedTestCancelled';
}

/// A progress report from inside a running phase.
class SpeedPhaseProgress {
  const SpeedPhaseProgress({
    required this.phaseProgress,
    this.currentMbps = 0,
    this.bytes = 0,
    this.latencyMs,
    this.jitterMs,
    this.colo,
    this.city,
  });

  /// This phase, 0–1.
  final double phaseProgress;

  /// Throughput over roughly the last second (transfer phases).
  final double currentMbps;

  /// Bytes this phase has moved so far (transfer phases).
  final int bytes;

  /// Running median and jitter (latency phase).
  final double? latencyMs;
  final double? jitterMs;

  /// Where the server says it is, once known.
  final String? colo;
  final String? city;
}

typedef SpeedProgressCallback = void Function(SpeedPhaseProgress progress);

/// The latency phase's result.
class SpeedLatencyResult {
  const SpeedLatencyResult({
    required this.providerId,
    required this.latencyMs,
    required this.jitterMs,
    required this.samples,
    this.colo,
    this.city,
  });

  final String providerId;

  /// Median round trip, with the server's own processing time removed when it reports one.
  final double latencyMs;

  /// Mean difference between consecutive samples.
  final double jitterMs;
  final int samples;
  final String? colo;
  final String? city;
}

/// A download or upload phase's result.
class SpeedTransferResult {
  const SpeedTransferResult({
    required this.providerId,
    required this.phase,
    required this.mbps,
    required this.bytes,
    required this.duration,
  });

  final String providerId;

  /// [SpeedTestPhase.download] or [SpeedTestPhase.upload].
  final SpeedTestPhase phase;
  final double mbps;
  final int bytes;
  final Duration duration;
}
