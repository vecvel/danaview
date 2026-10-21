// OWNER: ST-04
//
// Fake speed-test providers behind the real ST-03 coordinator, so the screen's prompt, consent and
// notes run end to end with no network.

import 'package:danaview_data/danaview_data.dart';
// The ticket and its precondition are not exported from the barrel (ST-03 file).
// ignore: implementation_imports
import 'package:danaview_data/src/network/speed/mlab_ndt7_provider.dart' show OpenNetworkConsent, OpenNetworkConsentRequired;
import 'package:danaview_features/danaview_features.dart';

/// A provider that answers at once, or fails the phases in [failing] with HTTP 429.
class FakeSpeedProvider implements SpeedTestProvider {
  FakeSpeedProvider(this.id, {this.failing = const {}, this.consent});

  @override
  final String id;
  final Set<SpeedTestPhase> failing;

  /// For an open-network provider: the ticket it was handed, or null (then it refuses).
  final Object? Function()? consent;

  /// Every phase this provider actually ran (or tried), in order.
  final List<SpeedTestPhase> calls = [];

  void _check(SpeedTestPhase phase, NetworkCancelToken cancel) {
    if (consent != null && consent!() == null) throw OpenNetworkConsentRequired(phase);
    if (cancel.isCancelled) throw const SpeedTestCancelled();
    calls.add(phase);
    if (failing.contains(phase)) {
      throw SpeedProviderFailure(
        kind: SpeedFailureKind.rateLimited,
        phase: phase,
        providerId: id,
        cause: SpeedTestException.status(429),
        status: 429,
      );
    }
  }

  @override
  Future<SpeedLatencyResult> latency({
    required NetworkCancelToken cancel,
    bool health = false,
    SpeedProgressCallback? onProgress,
  }) async {
    _check(SpeedTestPhase.latency, cancel);
    onProgress?.call(const SpeedPhaseProgress(phaseProgress: 0.5, latencyMs: 21, jitterMs: 2, colo: 'FRA', city: 'Frankfurt'));
    return SpeedLatencyResult(providerId: id, latencyMs: 20, jitterMs: 2, samples: 10, colo: 'FRA', city: 'Frankfurt');
  }

  @override
  Future<SpeedTransferResult> download({required NetworkCancelToken cancel, SpeedProgressCallback? onProgress}) =>
      _transfer(SpeedTestPhase.download, 180, cancel, onProgress);

  @override
  Future<SpeedTransferResult> upload({required NetworkCancelToken cancel, SpeedProgressCallback? onProgress}) =>
      _transfer(SpeedTestPhase.upload, 35, cancel, onProgress);

  Future<SpeedTransferResult> _transfer(
    SpeedTestPhase phase,
    double mbps,
    NetworkCancelToken cancel,
    SpeedProgressCallback? onProgress,
  ) async {
    _check(phase, cancel);
    onProgress?.call(SpeedPhaseProgress(phaseProgress: 0.5, currentMbps: mbps, bytes: 5000000));
    return SpeedTransferResult(
      providerId: id,
      phase: phase,
      mbps: mbps,
      bytes: 10000000,
      duration: const Duration(seconds: 8),
    );
  }
}

/// The default servers and the open network, wired into a [FallbackSpeedTestService].
class SpeedScenario {
  SpeedScenario._(this.primary);

  /// The default servers rate-limit from the start.
  factory SpeedScenario.defaultBusy() =>
      SpeedScenario._(FakeSpeedProvider('default', failing: SpeedTestPhase.values.toSet()));

  /// The default servers answer every phase.
  factory SpeedScenario.defaultHealthy() => SpeedScenario._(FakeSpeedProvider('default'));

  /// The default servers measure latency and download, then rate-limit the upload.
  factory SpeedScenario.uploadBusy({bool defaultBusyLatency = false}) => SpeedScenario._(FakeSpeedProvider(
        'default',
        failing: {SpeedTestPhase.upload, if (defaultBusyLatency) SpeedTestPhase.latency},
      ));

  final FakeSpeedProvider primary;
  late final FakeSpeedProvider open = FakeSpeedProvider('open', consent: () => _coordinator?.openNetworkConsent);
  SpeedTestCoordinator? _coordinator;

  /// The ticket the last run's coordinator was handed.
  OpenNetworkConsent? get lastTicket => _coordinator?.openNetworkConsent;

  FallbackSpeedTestService service() => FallbackSpeedTestService(
        health: () async => ProviderHealthStore(),
        coordinator: (health, request) => _coordinator = SpeedTestCoordinator(
          providers: [primary, open],
          health: health,
          requestOpenNetworkConsent: request,
          openNetworkProviderIds: const {'open'},
        ),
      );
}
