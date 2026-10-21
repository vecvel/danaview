// OWNER: ST-03
//
// Runs a speed test across the provider chain (V2-401, V2-403, V2-404; ST plan D-ST1, D-ST3, D-ST4):
//
// * **Health check.** Each provider's first latency attempt is its zero-byte health check (about
//   1.5 s), so the check adds no visible step.
// * **Per-phase failover.** On HTTP 429, HTTP 403, a connection failure or a stall, only the failing
//   phase restarts on the next provider; phases already measured are kept. A phase's numbers always
//   come from one provider's single attempt (G5): attempts are never merged.
// * **Skip memory.** A provider that failed that way is skipped for 10 minutes
//   ([ProviderHealthStore]). When every provider is skipped or unavailable, skipped ones are still
//   tried as a last resort rather than locking the test for 10 minutes.
// * **Consent.** A provider that needs the user's open-network consent and has none
//   ([OpenNetworkConsentRequired]) triggers [SpeedTestCoordinator.requestOpenNetworkConsent] once per
//   run (the D-ST2 prompt, ST-04). Declined, or nothing left to try: the calm [SpeedTestUnavailable].
// * **Attribution.** The final result is a [CoordinatedSpeedTestResult] carrying which provider
//   measured each phase (internal only, never shown by brand, D-ST5) and the details-row notes
//   ("measured on two servers", "open network").
//
// The update stream has the same shape as [SpeedTestService.run], so the v1.0 screen reads it as is.

import 'dart:async';
import 'dart:io';

import '../speed_test.dart';
import 'mlab_ndt7_provider.dart';
import 'provider_health_store.dart';

export 'mlab_ndt7_provider.dart' show MLabNdt7Provider, OpenNetworkConsent, OpenNetworkConsentRequired;
export 'provider_health_store.dart' show ProviderHealthStore;

/// Asks the user whether the test may run on the open measurement network (the D-ST2 prompt). A
/// remembered answer may be returned without asking. Null means "Not now".
typedef OpenNetworkConsentRequest = Future<OpenNetworkConsent?> Function();

/// A note for the result's details row (D-ST4). Never names a provider.
enum SpeedResultNote {
  /// Download and upload were measured by different providers.
  measuredOnTwoServers,

  /// At least one phase ran on the open measurement network, which measures a single stream.
  openNetwork;

  /// The D-ST4 wording; the screen (ST-04) may word it its own way.
  String get text => switch (this) {
        SpeedResultNote.measuredOnTwoServers => 'Measured on two servers',
        SpeedResultNote.openNetwork => 'Open network',
      };
}

/// Which provider measured each phase, and which attempts failed on the way (diagnostics only).
class SpeedTestAttribution {
  const SpeedTestAttribution({
    required this.latency,
    required this.download,
    required this.upload,
    this.failures = const [],
  });

  /// Provider ids. Internal: never shown in the UI (D-ST5).
  final String latency;
  final String download;
  final String upload;

  /// Every failed attempt of the run, in order.
  final List<SpeedProviderFailure> failures;

  String providerFor(SpeedTestPhase phase) => switch (phase) {
        SpeedTestPhase.latency => latency,
        SpeedTestPhase.download => download,
        SpeedTestPhase.upload || SpeedTestPhase.done => upload,
      };

  @override
  String toString() => 'SpeedTestAttribution(latency: $latency, download: $download, upload: $upload, '
      'failures: ${failures.length})';
}

/// A [SpeedTestResult] with its per-phase attribution and details-row notes.
///
/// [bytesDownloaded] and [bytesUploaded] count every attempt, failed ones included, because they
/// tell the user how much data the test used; the speeds come from the successful attempt only.
class CoordinatedSpeedTestResult extends SpeedTestResult {
  const CoordinatedSpeedTestResult({
    required super.downloadMbps,
    required super.uploadMbps,
    required super.latencyMs,
    required super.jitterMs,
    required super.bytesDownloaded,
    required super.bytesUploaded,
    required super.duration,
    required this.attribution,
    required this.notes,
    super.colo,
    super.city,
  });

  final SpeedTestAttribution attribution;
  final Set<SpeedResultNote> notes;

  bool get measuredOnTwoServers => notes.contains(SpeedResultNote.measuredOnTwoServers);
  bool get openNetwork => notes.contains(SpeedResultNote.openNetwork);
}

/// Why no test server could run a phase.
enum SpeedTestUnavailableReason {
  /// The fallback needed the user's consent and they said "Not now" (or had before).
  consentDeclined,

  /// Every provider was tried and failed with a rate limit, a refusal, a connection failure or a
  /// stall.
  allProvidersFailed,
}

/// The calm failure (D-ST2): "Couldn't reach a test server. Try again in a minute."
class SpeedTestUnavailable extends SpeedTestException {
  const SpeedTestUnavailable(this.reason, {this.failures = const []})
      : super(SpeedTestErrorKind.server, calmMessage);

  static const String calmMessage = "Couldn't reach a test server. Try again in a minute.";

  final SpeedTestUnavailableReason reason;
  final List<SpeedProviderFailure> failures;

  @override
  String toString() => 'SpeedTestUnavailable(${reason.name}, ${failures.length} failures): $message';
}

/// Runs latency, download and upload over [providers] in order, failing over per phase.
class SpeedTestCoordinator {
  SpeedTestCoordinator({
    required List<SpeedTestProvider> providers,
    required this.health,
    this.requestOpenNetworkConsent,
    this.openNetworkProviderIds = const {'mlab'},
  }) : providers = List.unmodifiable(providers) {
    if (providers.isEmpty) throw ArgumentError.value(providers, 'providers', 'needs at least one provider');
  }

  /// The D-ST1 chain: Cloudflare public, then M-Lab NDT7 once the user has agreed. [consent] is a
  /// remembered "Run on open network" answer; a ticket returned by [requestOpenNetworkConsent] is
  /// kept in [openNetworkConsent] and handed to the M-Lab provider for the rest of this
  /// coordinator's life.
  factory SpeedTestCoordinator.standard({
    required ProviderHealthStore health,
    OpenNetworkConsent? consent,
    OpenNetworkConsentRequest? requestOpenNetworkConsent,
    SpeedTestConfig config = const SpeedTestConfig(),
    HttpClient Function()? clientFactory,
  }) {
    late final SpeedTestCoordinator coordinator;
    coordinator = SpeedTestCoordinator(
      providers: [
        CloudflareSpeedProvider(config: config, clientFactory: clientFactory),
        MLabNdt7Provider(consent: () => coordinator.openNetworkConsent, config: config, clientFactory: clientFactory),
      ],
      health: health,
      requestOpenNetworkConsent: requestOpenNetworkConsent,
    )..openNetworkConsent = consent;
    return coordinator;
  }

  /// Most preferred first (D-ST1).
  final List<SpeedTestProvider> providers;
  final ProviderHealthStore health;

  /// Called at most once per run, when a provider needs consent it doesn't have. Null: never asked;
  /// such a provider is unavailable.
  final OpenNetworkConsentRequest? requestOpenNetworkConsent;

  /// Ids of providers whose results are labelled "open network" (D-ST4).
  final Set<String> openNetworkProviderIds;

  /// The ticket the user gave, if any. Set by [SpeedTestCoordinator.standard] callers or from
  /// [requestOpenNetworkConsent]; withdrawn (set to null) when the user revokes it in Settings.
  OpenNetworkConsent? openNetworkConsent;

  /// Failures that move a phase to the next provider and start a skip (D-ST3).
  static const Set<SpeedFailureKind> failoverKinds = {
    SpeedFailureKind.rateLimited,
    SpeedFailureKind.forbidden,
    SpeedFailureKind.unreachable,
    SpeedFailureKind.stalled,
  };

  static const double _latencyWeight = 0.1;
  static const double _transferWeight = 0.45;

  /// Same contract as [SpeedTestService.run]: the stream ends after the [SpeedTestPhase.done] update
  /// (whose result is a [CoordinatedSpeedTestResult]) or with a [SpeedTestException]
  /// ([SpeedTestUnavailable] when no server could run a phase). Cancelling [cancel] or the
  /// subscription stops the test and closes its sockets; the stream then closes without an error.
  Stream<SpeedTestUpdate> run({NetworkCancelToken? cancel}) {
    final token = cancel ?? NetworkCancelToken();
    late final StreamController<SpeedTestUpdate> controller;
    controller = StreamController<SpeedTestUpdate>(
      onListen: () => _CoordinatedRun(this, controller, token).start(),
      onCancel: token.cancel,
    );
    return controller.stream;
  }
}

/// A failure that ends the whole run (not a failover one).
class _Fatal implements Exception {
  const _Fatal(this.error);

  final Object error;
}

class _CoordinatedRun {
  _CoordinatedRun(this.coordinator, this.controller, this.token);

  final SpeedTestCoordinator coordinator;
  final StreamController<SpeedTestUpdate> controller;
  final NetworkCancelToken token;
  final Stopwatch clock = Stopwatch();

  /// Providers that failed over during this run; never tried again in it.
  final Set<String> _failedThisRun = {};

  /// Providers that can't run without consent the user didn't give.
  final Set<String> _needsConsent = {};
  final List<SpeedProviderFailure> _failures = [];
  bool _consentAsked = false;
  bool _consentDeclined = false;

  SpeedTestPhase _phase = SpeedTestPhase.latency;
  double? latencyMs;
  double? jitterMs;
  double? downloadMbps;
  double? uploadMbps;

  /// Bytes of finished attempts plus the running one, per transfer phase.
  int _downloadedBefore = 0;
  int _uploadedBefore = 0;
  int _downloadedNow = 0;
  int _uploadedNow = 0;
  String? colo;
  String? city;

  int get downloaded => _downloadedBefore + _downloadedNow;
  int get uploaded => _uploadedBefore + _uploadedNow;

  Future<void> start() async {
    clock.start();
    try {
      _emit(SpeedTestPhase.latency, phaseProgress: 0);
      final latency = await _phaseOnChain(
        SpeedTestPhase.latency,
        beforeRetry: _resetLatency,
        (provider, {required health}) async {
          final result = await provider.latency(cancel: token, health: health, onProgress: _onLatency);
          return (result, result.providerId);
        },
      );
      latencyMs = latency.$1.latencyMs;
      jitterMs = latency.$1.jitterMs;
      // Where the server is comes from the provider that measured latency only.
      colo = latency.$1.colo ?? colo;
      city = latency.$1.city ?? city;

      final download = await _transfer(SpeedTestPhase.download);
      final upload = await _transfer(SpeedTestPhase.upload);

      final attribution = SpeedTestAttribution(
        latency: latency.$2,
        download: download.providerId,
        upload: upload.providerId,
        failures: List.unmodifiable(_failures),
      );
      final open = coordinator.openNetworkProviderIds;
      final notes = <SpeedResultNote>{
        if (download.providerId != upload.providerId) SpeedResultNote.measuredOnTwoServers,
        if (open.contains(attribution.latency) || open.contains(attribution.download) || open.contains(attribution.upload))
          SpeedResultNote.openNetwork,
      };
      final result = CoordinatedSpeedTestResult(
        downloadMbps: download.mbps,
        uploadMbps: upload.mbps,
        latencyMs: latencyMs!,
        jitterMs: jitterMs!,
        bytesDownloaded: downloaded,
        bytesUploaded: uploaded,
        duration: clock.elapsed,
        colo: colo,
        city: city,
        attribution: attribution,
        notes: Set.unmodifiable(notes),
      );
      _emit(SpeedTestPhase.done, phaseProgress: 1, result: result);
    } catch (error) {
      if (!token.isCancelled && error is! SpeedTestCancelled) {
        controller.addError(_userFacing(error));
      }
    } finally {
      await controller.close();
    }
  }

  /// [SpeedTestUnavailable] as is; a provider failure in the v1.0 wording for its cause.
  SpeedTestException _userFacing(Object error) {
    var cause = error is _Fatal ? error.error : error;
    if (cause is SpeedProviderFailure) cause = cause.cause;
    return SpeedTestException.from(cause, phase: _phase);
  }

  /// Runs [phase] on the first provider that can, restarting it on the next one after a failover
  /// failure. Returns the result and the id of the provider that measured it.
  Future<(T, String)> _phaseOnChain<T>(
    SpeedTestPhase phase,
    Future<(T, String)> Function(SpeedTestProvider provider, {required bool health}) attempt, {
    void Function()? beforeRetry,
  }) async {
    _phase = phase;
    var attempts = 0;
    while (true) {
      _checkCancelled();
      final provider = _nextProvider();
      if (provider == null) throw _unavailable();
      if (attempts > 0) beforeRetry?.call();
      attempts++;
      try {
        // A provider's first latency attempt is its health check (D-ST3).
        final result = await attempt(provider, health: phase == SpeedTestPhase.latency);
        _checkCancelled();
        await coordinator.health.clear(provider.id);
        return result;
      } on SpeedTestCancelled {
        rethrow;
      } on OpenNetworkConsentRequired {
        _checkCancelled();
        if (!await _askConsent()) _needsConsent.add(provider.id);
        // With a ticket, the same provider is tried again; without one, it is now excluded.
      } on SpeedProviderFailure catch (failure) {
        _checkCancelled();
        _failures.add(failure);
        if (!SpeedTestCoordinator.failoverKinds.contains(failure.kind)) throw _Fatal(failure);
        _failedThisRun.add(provider.id);
        await coordinator.health.markFailed(provider.id);
      }
    }
  }

  /// The first provider not failed in this run and not waiting for consent, preferring ones that
  /// aren't skipped; a skipped one only when nothing else is left (last resort).
  SpeedTestProvider? _nextProvider() {
    final candidates = [
      for (final p in coordinator.providers)
        if (!_failedThisRun.contains(p.id) && !_needsConsent.contains(p.id)) p,
    ];
    for (final p in candidates) {
      if (!coordinator.health.isSkipped(p.id)) return p;
    }
    return candidates.isEmpty ? null : candidates.first;
  }

  /// True when a consent ticket is now in hand.
  Future<bool> _askConsent() async {
    if (_consentAsked) return false;
    _consentAsked = true;
    final request = coordinator.requestOpenNetworkConsent;
    if (request == null) {
      _consentDeclined = true;
      return false;
    }
    final ticket = await request();
    _checkCancelled();
    if (ticket == null) {
      _consentDeclined = true;
      return false;
    }
    coordinator.openNetworkConsent = ticket;
    return true;
  }

  SpeedTestUnavailable _unavailable() => SpeedTestUnavailable(
        _consentDeclined ? SpeedTestUnavailableReason.consentDeclined : SpeedTestUnavailableReason.allProvidersFailed,
        failures: List.unmodifiable(_failures),
      );

  Future<SpeedTransferResult> _transfer(SpeedTestPhase phase) async {
    final upload = phase == SpeedTestPhase.upload;
    void count(int bytes) {
      if (upload) {
        _uploadedNow = bytes;
      } else {
        _downloadedNow = bytes;
      }
    }

    void keepAttemptBytes() {
      // A failed attempt's data was still used; its speed is not.
      if (upload) {
        _uploadedBefore += _uploadedNow;
        _uploadedNow = 0;
      } else {
        _downloadedBefore += _downloadedNow;
        _downloadedNow = 0;
      }
      _emit(phase, phaseProgress: 0);
    }

    final (result, _) = await _phaseOnChain<SpeedTransferResult>(
      phase,
      beforeRetry: keepAttemptBytes,
      (provider, {required health}) async {
        void onProgress(SpeedPhaseProgress progress) {
          count(progress.bytes);
          _emit(phase, phaseProgress: progress.phaseProgress, current: progress.currentMbps);
        }

        final result = upload
            ? await provider.upload(cancel: token, onProgress: onProgress)
            : await provider.download(cancel: token, onProgress: onProgress);
        return (result, result.providerId);
      },
    );
    count(result.bytes);
    if (upload) {
      uploadMbps = result.mbps;
    } else {
      downloadMbps = result.mbps;
    }
    _emit(phase, phaseProgress: 1, current: result.mbps);
    return result;
  }

  /// A failed latency attempt's running figures and server location belong to another provider.
  void _resetLatency() {
    latencyMs = null;
    jitterMs = null;
    colo = null;
    city = null;
    _emit(SpeedTestPhase.latency, phaseProgress: 0);
  }

  void _onLatency(SpeedPhaseProgress progress) {
    latencyMs = progress.latencyMs ?? latencyMs;
    jitterMs = progress.jitterMs ?? jitterMs;
    colo = progress.colo ?? colo;
    city = progress.city ?? city;
    _emit(SpeedTestPhase.latency, phaseProgress: progress.phaseProgress);
  }

  void _checkCancelled() {
    if (token.isCancelled) throw const SpeedTestCancelled();
  }

  void _emit(SpeedTestPhase phase, {required double phaseProgress, double current = 0, SpeedTestResult? result}) {
    if (controller.isClosed || token.isCancelled) return;
    final p = phaseProgress.clamp(0.0, 1.0);
    final progress = switch (phase) {
      SpeedTestPhase.latency => SpeedTestCoordinator._latencyWeight * p,
      SpeedTestPhase.download => SpeedTestCoordinator._latencyWeight + SpeedTestCoordinator._transferWeight * p,
      SpeedTestPhase.upload =>
        SpeedTestCoordinator._latencyWeight + SpeedTestCoordinator._transferWeight * (1 + p),
      SpeedTestPhase.done => 1.0,
    };
    controller.add(SpeedTestUpdate(
      phase: phase,
      progress: progress,
      phaseProgress: p,
      elapsed: clock.elapsed,
      currentMbps: current,
      latencyMs: latencyMs,
      jitterMs: jitterMs,
      downloadMbps: downloadMbps,
      uploadMbps: uploadMbps,
      bytesTransferred: downloaded + uploaded,
      colo: colo,
      city: city,
      result: result,
    ));
  }
}
