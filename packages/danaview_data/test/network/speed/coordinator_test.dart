// OWNER: ST-03
//
// SpeedTestCoordinator and ProviderHealthStore (V2-403, V2-404): the health check, injected 429,
// 403, stalls and connection errors at every phase, per-phase failover that never mixes providers,
// the 10-minute skip memory (memory and prefs) with a fake clock, consent asked once and declined
// into the calm failure, attribution and the details-row notes; plus the real providers' failures
// (a loopback 429 and a slow health check) failing over.

import 'dart:async';
import 'dart:io';

import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_data/src/network/speed/speed_test_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// -------------------------------------------------------------------------------------------------
// Fakes
// -------------------------------------------------------------------------------------------------

/// What one call of a phase does.
sealed class _Step {
  const _Step();
}

class _Ok extends _Step {
  const _Ok();
}

class _Fail extends _Step {
  const _Fail(this.kind, {this.status, this.bytesFirst = 0});

  final SpeedFailureKind kind;
  final int? status;

  /// Bytes reported through progress before failing (transfer phases).
  final int bytesFirst;
}

/// Waits for the cancel token, then throws [SpeedTestCancelled].
class _Hang extends _Step {
  const _Hang();
}

/// Throws [OpenNetworkConsentRequired] unless [consent] returns a ticket.
class _FakeProvider implements SpeedTestProvider {
  _FakeProvider(
    this.id, {
    this.latencyMs = 20,
    this.downloadMbps = 100,
    this.uploadMbps = 40,
    this.consent,
    List<_Step>? latencySteps,
    List<_Step>? downloadSteps,
    List<_Step>? uploadSteps,
  }) : _steps = {
          SpeedTestPhase.latency: [...?latencySteps],
          SpeedTestPhase.download: [...?downloadSteps],
          SpeedTestPhase.upload: [...?uploadSteps],
        };

  @override
  final String id;
  final double latencyMs;
  final double downloadMbps;
  final double uploadMbps;
  final OpenNetworkConsent? Function()? consent;
  final Map<SpeedTestPhase, List<_Step>> _steps;

  /// Every call, in order: phase and (for latency) the health flag.
  final List<({SpeedTestPhase phase, bool health})> calls = [];

  int callsOf(SpeedTestPhase phase) => calls.where((c) => c.phase == phase).length;

  Future<void> _run(SpeedTestPhase phase, NetworkCancelToken cancel, SpeedProgressCallback? onProgress) async {
    if (consent != null && consent!() == null) throw OpenNetworkConsentRequired(phase);
    if (cancel.isCancelled) throw const SpeedTestCancelled();
    final steps = _steps[phase]!;
    final step = steps.isEmpty ? const _Ok() : steps.removeAt(0);
    switch (step) {
      case _Ok():
        return;
      case _Fail(:final kind, :final status, :final bytesFirst):
        if (bytesFirst > 0) onProgress?.call(SpeedPhaseProgress(phaseProgress: 0.3, bytes: bytesFirst, currentMbps: 999));
        if (phase == SpeedTestPhase.latency) {
          // Running figures that must not leak into the next provider's result.
          onProgress?.call(const SpeedPhaseProgress(phaseProgress: 0.5, latencyMs: 999, jitterMs: 99, colo: 'BAD', city: 'Wrong'));
        }
        throw SpeedProviderFailure(
          kind: kind,
          phase: phase,
          providerId: id,
          cause: status != null ? SpeedTestException.status(status) : const SocketException('fake'),
          status: status,
        );
      case _Hang():
        await cancel.whenCancelled;
        throw const SpeedTestCancelled();
    }
  }

  @override
  Future<SpeedLatencyResult> latency({required NetworkCancelToken cancel, bool health = false, SpeedProgressCallback? onProgress}) async {
    calls.add((phase: SpeedTestPhase.latency, health: health));
    await _run(SpeedTestPhase.latency, cancel, onProgress);
    onProgress?.call(SpeedPhaseProgress(phaseProgress: 1, latencyMs: latencyMs, jitterMs: 1, city: '$id-city'));
    return SpeedLatencyResult(providerId: id, latencyMs: latencyMs, jitterMs: 1, samples: 3, city: '$id-city');
  }

  @override
  Future<SpeedTransferResult> download({required NetworkCancelToken cancel, SpeedProgressCallback? onProgress}) async {
    calls.add((phase: SpeedTestPhase.download, health: false));
    await _run(SpeedTestPhase.download, cancel, onProgress);
    onProgress?.call(SpeedPhaseProgress(phaseProgress: 0.5, bytes: 500, currentMbps: downloadMbps));
    return SpeedTransferResult(providerId: id, phase: SpeedTestPhase.download, mbps: downloadMbps, bytes: 1000, duration: const Duration(seconds: 1));
  }

  @override
  Future<SpeedTransferResult> upload({required NetworkCancelToken cancel, SpeedProgressCallback? onProgress}) async {
    calls.add((phase: SpeedTestPhase.upload, health: false));
    await _run(SpeedTestPhase.upload, cancel, onProgress);
    return SpeedTransferResult(providerId: id, phase: SpeedTestPhase.upload, mbps: uploadMbps, bytes: 400, duration: const Duration(seconds: 1));
  }
}

class _Clock {
  DateTime value = DateTime.utc(2026, 10, 22, 12);
  DateTime call() => value;
  void advance(Duration d) => value = value.add(d);
}

/// The run's updates and how it ended.
class _Outcome {
  _Outcome(this.updates, this.error);

  final List<SpeedTestUpdate> updates;
  final Object? error;

  CoordinatedSpeedTestResult get result => updates.last.result! as CoordinatedSpeedTestResult;
}

Future<_Outcome> _collect(Stream<SpeedTestUpdate> stream) async {
  final updates = <SpeedTestUpdate>[];
  Object? error;
  try {
    await for (final u in stream) {
      updates.add(u);
    }
  } catch (e) {
    error = e;
  }
  return _Outcome(updates, error);
}

const _failoverCases = <(String, _Fail)>[
  ('HTTP 429', _Fail(SpeedFailureKind.rateLimited, status: 429)),
  ('HTTP 403', _Fail(SpeedFailureKind.forbidden, status: 403)),
  ('a stall', _Fail(SpeedFailureKind.stalled)),
  ('a connection error', _Fail(SpeedFailureKind.unreachable)),
];

final _ticket = OpenNetworkConsent.accepted(DateTime.utc(2026, 10, 1));

void main() {
  late _Clock clock;
  late ProviderHealthStore health;

  setUp(() {
    clock = _Clock();
    health = ProviderHealthStore(now: clock.call);
  });

  SpeedTestCoordinator coordinator(List<SpeedTestProvider> providers, {OpenNetworkConsentRequest? ask}) =>
      SpeedTestCoordinator(providers: providers, health: health, requestOpenNetworkConsent: ask);

  group('happy path', () {
    test('every phase on the default provider; its first latency attempt is the health check', () async {
      final cf = _FakeProvider('cloudflare');
      final ml = _FakeProvider('mlab');
      final out = await _collect(coordinator([cf, ml]).run());
      expect(out.error, isNull);
      expect(out.updates.last.phase, SpeedTestPhase.done);
      expect(out.updates.last.progress, 1.0);
      final r = out.result;
      expect(r.attribution.latency, 'cloudflare');
      expect(r.attribution.download, 'cloudflare');
      expect(r.attribution.upload, 'cloudflare');
      expect(r.notes, isEmpty);
      expect(r.attribution.failures, isEmpty);
      expect(r.downloadMbps, 100);
      expect(r.uploadMbps, 40);
      expect(r.bytesDownloaded, 1000);
      expect(r.bytesUploaded, 400);
      expect(cf.calls.first, (phase: SpeedTestPhase.latency, health: true));
      expect(ml.calls, isEmpty, reason: 'the fallback opens nothing when the default works');
    });

    test('progress never goes backwards within the happy path', () async {
      final out = await _collect(coordinator([_FakeProvider('cloudflare')]).run());
      final p = out.updates.map((u) => u.progress).toList();
      for (var i = 1; i < p.length; i++) {
        expect(p[i], greaterThanOrEqualTo(p[i - 1]));
      }
    });
  });

  group('failover at every phase (D-ST3)', () {
    for (final (label, fail) in _failoverCases) {
      for (final phase in [SpeedTestPhase.latency, SpeedTestPhase.download, SpeedTestPhase.upload]) {
        test('$label in ${phase.name} restarts only that phase on the next provider', () async {
          final cf = _FakeProvider(
            'cloudflare',
            latencyMs: 10,
            downloadMbps: 200,
            uploadMbps: 80,
            latencySteps: phase == SpeedTestPhase.latency ? [fail] : null,
            downloadSteps: phase == SpeedTestPhase.download ? [_Fail(fail.kind, status: fail.status, bytesFirst: 300)] : null,
            uploadSteps: phase == SpeedTestPhase.upload ? [_Fail(fail.kind, status: fail.status, bytesFirst: 150)] : null,
          );
          final ml = _FakeProvider('mlab', latencyMs: 30, downloadMbps: 50, uploadMbps: 20, consent: () => _ticket);
          final out = await _collect(coordinator([cf, ml]).run());
          expect(out.error, isNull);
          final r = out.result;

          // Phases before the failure stay where they were measured; the failing one and the rest
          // move to the next provider (the failed one is now skipped).
          final before = SpeedTestPhase.values.indexOf(phase);
          String expected(SpeedTestPhase p) => SpeedTestPhase.values.indexOf(p) < before ? 'cloudflare' : 'mlab';
          expect(r.attribution.latency, expected(SpeedTestPhase.latency));
          expect(r.attribution.download, expected(SpeedTestPhase.download));
          expect(r.attribution.upload, expected(SpeedTestPhase.upload));

          // A phase's numbers are exactly one provider's (G5).
          expect(r.latencyMs, r.attribution.latency == 'cloudflare' ? 10 : 30);
          expect(r.downloadMbps, r.attribution.download == 'cloudflare' ? 200 : 50);
          expect(r.uploadMbps, r.attribution.upload == 'cloudflare' ? 80 : 20);
          expect(r.city, '${r.attribution.latency}-city');
          expect(r.colo, isNull, reason: 'a failed attempt\'s server location never leaks');
          expect(r.jitterMs, 1);

          // Each phase ran once on each provider at most; earlier phases were not re-run.
          expect(cf.callsOf(phase), 1);
          expect(ml.callsOf(phase), 1);
          for (final earlier in SpeedTestPhase.values.take(before)) {
            expect(ml.callsOf(earlier), 0, reason: '${earlier.name} is not restarted');
          }
          if (phase == SpeedTestPhase.latency) {
            expect(ml.calls.first.health, isTrue, reason: 'the next provider also starts with its health check');
          }

          // Notes.
          expect(r.openNetwork, isTrue);
          expect(r.measuredOnTwoServers, phase == SpeedTestPhase.upload);

          // The failed attempt's data counts toward data used; its speed does not.
          if (phase == SpeedTestPhase.download) expect(r.bytesDownloaded, 1300);
          if (phase == SpeedTestPhase.upload) expect(r.bytesUploaded, 550);

          // Skip memory and diagnostics.
          expect(health.isSkipped('cloudflare'), isTrue);
          expect(health.isSkipped('mlab'), isFalse);
          expect(r.attribution.failures.single.kind, fail.kind);
          expect(r.attribution.failures.single.phase, phase);
        });
      }
    }

    test('a failed transfer phase restarts at zero progress and the result reflects data used', () async {
      final cf = _FakeProvider('cloudflare', downloadSteps: [const _Fail(SpeedFailureKind.stalled, bytesFirst: 300)]);
      final ml = _FakeProvider('mlab', consent: () => _ticket);
      final out = await _collect(coordinator([cf, ml]).run());
      final downloads = out.updates.where((u) => u.phase == SpeedTestPhase.download).toList();
      final restart = downloads.indexWhere((u) => u.phaseProgress == 0, 1);
      expect(restart, greaterThan(0));
      expect(downloads[restart].bytesTransferred, 300, reason: 'bytes of the failed attempt are kept');
    });

    test('a server error (not a failover kind) ends the test in v1.0 wording without a skip', () async {
      final cf = _FakeProvider('cloudflare', downloadSteps: [const _Fail(SpeedFailureKind.serverError, status: 500)]);
      final ml = _FakeProvider('mlab', consent: () => _ticket);
      final out = await _collect(coordinator([cf, ml]).run());
      expect(out.error, isA<SpeedTestException>().having((e) => e.message, 'message', contains('HTTP 500')));
      expect(out.error, isNot(isA<SpeedTestUnavailable>()));
      expect(ml.calls, isEmpty);
      expect(health.isSkipped('cloudflare'), isFalse);
    });

    test('every provider failing ends with the calm failure and skips both', () async {
      final cf = _FakeProvider('cloudflare', latencySteps: [const _Fail(SpeedFailureKind.rateLimited, status: 429)]);
      final ml = _FakeProvider('mlab', consent: () => _ticket, latencySteps: [const _Fail(SpeedFailureKind.forbidden, status: 403)]);
      final out = await _collect(coordinator([cf, ml]).run());
      expect(
        out.error,
        isA<SpeedTestUnavailable>()
            .having((e) => e.reason, 'reason', SpeedTestUnavailableReason.allProvidersFailed)
            .having((e) => e.message, 'message', "Couldn't reach a test server. Try again in a minute.")
            .having((e) => e.failures.length, 'failures', 2),
      );
      expect(health.isSkipped('cloudflare'), isTrue);
      expect(health.isSkipped('mlab'), isTrue);
    });

    test('a provider is never tried twice in one run', () async {
      final cf = _FakeProvider('cloudflare', downloadSteps: [const _Fail(SpeedFailureKind.stalled)]);
      final ml = _FakeProvider('mlab', consent: () => _ticket, uploadSteps: [const _Fail(SpeedFailureKind.stalled)]);
      final out = await _collect(coordinator([cf, ml]).run());
      expect(out.error, isA<SpeedTestUnavailable>());
      expect(cf.callsOf(SpeedTestPhase.upload), 0);
    });

    test('the order of the chain is configurable (D-ST1)', () async {
      final a = _FakeProvider('own');
      final b = _FakeProvider('cloudflare');
      final out = await _collect(coordinator([a, b]).run());
      expect(out.result.attribution.download, 'own');
      expect(b.calls, isEmpty);
    });
  });

  group('skip memory (10 minutes)', () {
    test('a failed provider is skipped on the next run, and tried again after 10 minutes', () async {
      final cf = _FakeProvider('cloudflare', latencySteps: [const _Fail(SpeedFailureKind.rateLimited, status: 429)]);
      final ml = _FakeProvider('mlab', consent: () => _ticket);
      final c = coordinator([cf, ml]);
      await _collect(c.run());
      expect(cf.callsOf(SpeedTestPhase.latency), 1);

      clock.advance(const Duration(minutes: 9, seconds: 59));
      final second = await _collect(c.run());
      expect(second.result.attribution.latency, 'mlab');
      expect(cf.callsOf(SpeedTestPhase.latency), 1, reason: 'still skipped');

      clock.advance(const Duration(seconds: 1));
      final third = await _collect(c.run());
      expect(third.result.attribution.latency, 'cloudflare');
      expect(third.result.notes, isEmpty);
    });

    test('a skipped provider is tried as a last resort, and cleared when it answers', () async {
      await health.markFailed('cloudflare');
      final cf = _FakeProvider('cloudflare');
      final out = await _collect(coordinator([cf]).run());
      expect(out.error, isNull);
      expect(out.result.attribution.latency, 'cloudflare');
      expect(health.isSkipped('cloudflare'), isFalse);
    });

    test('a skipped default with the fallback declined still runs on the default', () async {
      await health.markFailed('cloudflare');
      final cf = _FakeProvider('cloudflare');
      final ml = _FakeProvider('mlab', consent: () => null);
      final out = await _collect(coordinator([cf, ml], ask: () async => null).run());
      expect(out.error, isNull);
      expect(out.result.attribution.upload, 'cloudflare');
    });

    test('store: skip expiry with a fake clock', () async {
      await health.markFailed('mlab');
      expect(health.skippedUntil('mlab'), clock.value.add(const Duration(minutes: 10)));
      clock.advance(const Duration(minutes: 10));
      expect(health.isSkipped('mlab'), isFalse);
    });

    test('store: the skip survives a restart through prefs', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await ProviderHealthStore(prefs: prefs, now: clock.call).markFailed('cloudflare');
      expect(prefs.getInt('speed.skip.cloudflare'), clock.value.add(const Duration(minutes: 10)).millisecondsSinceEpoch);

      final restarted = ProviderHealthStore(prefs: prefs, now: clock.call);
      expect(restarted.isSkipped('cloudflare'), isTrue);
      clock.advance(const Duration(minutes: 11));
      expect(restarted.isSkipped('cloudflare'), isFalse);
    });

    test('store: load() opens the app prefs', () async {
      SharedPreferences.setMockInitialValues({
        'speed.skip.cloudflare': clock.value.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
      });
      final store = await ProviderHealthStore.load(now: clock.call);
      expect(store.isSkipped('cloudflare'), isTrue);
      await store.clear('cloudflare');
      expect(store.isSkipped('cloudflare'), isFalse);
      expect((await SharedPreferences.getInstance()).containsKey('speed.skip.cloudflare'), isFalse);
    });

    test('store: a clock moved back cannot extend a skip past 10 minutes', () async {
      SharedPreferences.setMockInitialValues({
        'speed.skip.cloudflare': clock.value.add(const Duration(days: 3)).millisecondsSinceEpoch,
      });
      final store = ProviderHealthStore(prefs: await SharedPreferences.getInstance(), now: clock.call);
      expect(store.skippedUntil('cloudflare'), clock.value.add(const Duration(minutes: 10)));
    });

    test('store: a mistyped prefs value reads as no skip', () async {
      SharedPreferences.setMockInitialValues({'speed.skip.cloudflare': 'soon'});
      final store = ProviderHealthStore(prefs: await SharedPreferences.getInstance(), now: clock.call);
      expect(store.isSkipped('cloudflare'), isFalse);
    });
  });

  group('consent (D-ST2)', () {
    test('without a ticket the default failing asks once; accepted runs the phase on the fallback', () async {
      OpenNetworkConsent? granted;
      final cf = _FakeProvider('cloudflare', downloadSteps: [const _Fail(SpeedFailureKind.rateLimited, status: 429)]);
      final ml = _FakeProvider('mlab', consent: () => granted);
      var asked = 0;
      final c = coordinator([cf, ml], ask: () async {
        asked++;
        return granted = _ticket;
      });
      final out = await _collect(c.run());
      expect(out.error, isNull);
      expect(asked, 1);
      expect(c.openNetworkConsent, same(_ticket));
      expect(out.result.attribution.download, 'mlab');
      expect(out.result.openNetwork, isTrue);
    });

    test('declined → the calm failure result; nothing is skipped for the fallback', () async {
      final cf = _FakeProvider('cloudflare', latencySteps: [const _Fail(SpeedFailureKind.unreachable)]);
      final ml = _FakeProvider('mlab', consent: () => null);
      var asked = 0;
      final out = await _collect(coordinator([cf, ml], ask: () async {
        asked++;
        return null;
      }).run());
      expect(asked, 1);
      expect(
        out.error,
        isA<SpeedTestUnavailable>()
            .having((e) => e.reason, 'reason', SpeedTestUnavailableReason.consentDeclined)
            .having((e) => e.message, 'message', SpeedTestUnavailable.calmMessage),
      );
      expect(health.isSkipped('mlab'), isFalse, reason: 'missing consent is not a provider fault');
      expect(ml.calls.length, 1);
    });

    test('consent is asked at most once per run', () async {
      final cf = _FakeProvider('cloudflare', latencySteps: [const _Fail(SpeedFailureKind.stalled)]);
      final ml = _FakeProvider('mlab', consent: () => null); // ignores the ticket
      var asked = 0;
      final out = await _collect(coordinator([cf, ml], ask: () async {
        asked++;
        return _ticket;
      }).run());
      expect(asked, 1);
      expect(out.error, isA<SpeedTestUnavailable>());
    });

    test('no consent callback → the fallback is unavailable, calm failure', () async {
      final cf = _FakeProvider('cloudflare', uploadSteps: [const _Fail(SpeedFailureKind.forbidden, status: 403)]);
      final ml = _FakeProvider('mlab', consent: () => null);
      final out = await _collect(coordinator([cf, ml]).run());
      expect(out.error, isA<SpeedTestUnavailable>().having((e) => e.reason, 'reason', SpeedTestUnavailableReason.consentDeclined));
    });

    test('the default working never asks', () async {
      var asked = 0;
      await _collect(coordinator([_FakeProvider('cloudflare'), _FakeProvider('mlab', consent: () => null)], ask: () async {
        asked++;
        return null;
      }).run());
      expect(asked, 0);
    });

    test('the standard chain hands an accepted ticket to the real M-Lab provider', () async {
      final c = SpeedTestCoordinator.standard(health: health, consent: _ticket);
      expect(c.providers.map((p) => p.id), ['cloudflare', 'mlab']);
      expect(c.openNetworkConsent, same(_ticket));
      // Revoked in Settings: the M-Lab provider refuses before opening anything.
      c.openNetworkConsent = null;
      expect(
        () => c.providers.last.latency(cancel: NetworkCancelToken()),
        throwsA(isA<OpenNetworkConsentRequired>()),
      );
    });
  });

  group('cancel', () {
    test('cancelling during a phase closes the stream without an error and skips nothing', () async {
      final cf = _FakeProvider('cloudflare', downloadSteps: [const _Hang()]);
      final token = NetworkCancelToken();
      final run = _collect(coordinator([cf]).run(cancel: token));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel();
      final out = await run;
      expect(out.error, isNull);
      expect(out.updates.where((u) => u.phase == SpeedTestPhase.done), isEmpty);
      expect(health.isSkipped('cloudflare'), isFalse);
    });

    test('cancelling while the consent prompt is open ends quietly', () async {
      final cf = _FakeProvider('cloudflare', latencySteps: [const _Fail(SpeedFailureKind.stalled)]);
      final ml = _FakeProvider('mlab', consent: () => null);
      final token = NetworkCancelToken();
      final prompt = Completer<OpenNetworkConsent?>();
      final run = _collect(coordinator([cf, ml], ask: () => prompt.future).run(cancel: token));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel();
      prompt.complete(_ticket);
      final out = await run;
      expect(out.error, isNull);
      expect(ml.calls.length, 1);
    });
  });

  group('real providers', () {
    late HttpServer server;
    var mode = 'ok';

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final response = request.response;
        if (mode == '429') {
          response.statusCode = 429;
        } else if (mode == 'slow') {
          await Future<void>.delayed(const Duration(milliseconds: 600));
        }
        response.contentLength = 0;
        await response.close();
      });
    });

    tearDown(() => server.close(force: true));

    CloudflareSpeedProvider cloudflare({Duration healthTimeout = const Duration(seconds: 1)}) => CloudflareSpeedProvider(
          base: Uri.parse('http://127.0.0.1:${server.port}'),
          healthTimeout: healthTimeout,
          config: const SpeedTestConfig(latencySamples: 2, requestTimeout: Duration(seconds: 2)),
        );

    test('a real HTTP 429 from the default fails over and starts a skip', () async {
      mode = '429';
      final ml = _FakeProvider('mlab', consent: () => _ticket);
      final out = await _collect(coordinator([cloudflare(), ml]).run());
      expect(out.error, isNull);
      expect(out.result.attribution.latency, 'mlab');
      expect(out.result.attribution.failures.single.kind, SpeedFailureKind.rateLimited);
      expect(health.isSkipped('cloudflare'), isTrue);
    });

    test('a health check slower than its timeout fails over as a stall', () async {
      mode = 'slow';
      final ml = _FakeProvider('mlab', consent: () => _ticket);
      final out = await _collect(coordinator([cloudflare(healthTimeout: const Duration(milliseconds: 200)), ml]).run());
      expect(out.error, isNull);
      expect(out.result.attribution.latency, 'mlab');
      expect(out.result.attribution.failures.single.kind, SpeedFailureKind.stalled);
    });

    test('a refused connection fails over as unreachable', () async {
      final port = server.port;
      await server.close(force: true);
      final dead = CloudflareSpeedProvider(
        base: Uri.parse('http://127.0.0.1:$port'),
        // Windows retries a refused loopback connect for about 2 s (Linux, macOS and Android refuse at
        // once): both deadlines sit above that so the refusal, not the deadline, ends the health
        // check on every host (FIX-S1Q-A2).
        config: const SpeedTestConfig(latencySamples: 2, requestTimeout: Duration(seconds: 6)),
        healthTimeout: const Duration(seconds: 6),
      );
      final ml = _FakeProvider('mlab', consent: () => _ticket);
      final out = await _collect(coordinator([dead, ml]).run());
      expect(out.error, isNull);
      expect(out.result.attribution.failures.single.kind, SpeedFailureKind.unreachable);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
  });
}
