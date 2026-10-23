// EXTENDED: ST-04 (speed-test fallback: the remembered open-network answer, the provider chain
// behind the v1.0 screen; V2-401, V2-402, ARCH v1.2 §5 "Speed-test prefs")
//
// The v1.0 [speedTestServiceProvider] still hands the screen a [SpeedTestService], so screens and
// tests that override it with a fake keep working. Its default is now a [FallbackSpeedTestService]:
// the ST-03 coordinator (default servers first, the open measurement network only with consent),
// with the user's remembered answer from [speedConsentProvider]. Creating the ticket the open
// network needs happens in `speed_consent_sheet.dart` only (ARCH rule 28); this file stores the
// answer, never a ticket.

import 'dart:async';
import 'dart:io';

import 'package:danaview_data/danaview_data.dart';
// ST-03's coordinator is not exported from the danaview_data barrel yet (see the ST-04 report).
// ignore: implementation_imports
import 'package:danaview_data/src/network/speed/speed_test_coordinator.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

export 'package:danaview_data/src/network/speed/speed_test_coordinator.dart'
    show
        CoordinatedSpeedTestResult,
        OpenNetworkConsent,
        OpenNetworkConsentRequest,
        ProviderHealthStore,
        SpeedResultNote,
        SpeedTestCoordinator,
        SpeedTestUnavailable,
        SpeedTestUnavailableReason;

/// The user's answer to the open-network prompt (D-ST2).
enum SpeedConsentChoice {
  /// Never asked: the prompt shows the first time the default servers are unavailable.
  unasked,

  /// "Run on open network", in the prompt or in Settings › Privacy.
  accepted,

  /// "Not now", or turned off in Settings › Privacy (revoked).
  declined,
}

/// The remembered answer, with the time the user agreed.
@immutable
final class SpeedConsentAnswer {
  const SpeedConsentAnswer._(this.choice, this.acceptedAt);

  /// Agreed at [at].
  const SpeedConsentAnswer.accepted(DateTime at) : this._(SpeedConsentChoice.accepted, at);

  static const SpeedConsentAnswer unasked = SpeedConsentAnswer._(SpeedConsentChoice.unasked, null);
  static const SpeedConsentAnswer declined = SpeedConsentAnswer._(SpeedConsentChoice.declined, null);

  final SpeedConsentChoice choice;

  /// Set when [choice] is [SpeedConsentChoice.accepted].
  final DateTime? acceptedAt;

  bool get isAccepted => choice == SpeedConsentChoice.accepted;

  @override
  bool operator ==(Object other) => other is SpeedConsentAnswer && other.choice == choice && other.acceptedAt == acceptedAt;

  @override
  int get hashCode => Object.hash(choice, acceptedAt);

  @override
  String toString() => 'SpeedConsentAnswer(${choice.name}${acceptedAt == null ? '' : ', $acceptedAt'})';
}

/// Where the answer is remembered.
abstract interface class SpeedConsentStore {
  Future<SpeedConsentAnswer> load();

  Future<void> save(SpeedConsentAnswer answer);
}

/// The answer in SharedPreferences under [prefsKey] (ARCH v1.2 §5): `accepted:<ms since epoch>`
/// or `declined`; no value is "never asked". Anything unreadable reads as never asked, so the
/// user is asked again rather than opted in.
final class PrefsSpeedConsentStore implements SpeedConsentStore {
  PrefsSpeedConsentStore({Future<SharedPreferences> Function()? prefs}) : _prefs = prefs ?? SharedPreferences.getInstance;

  static const String prefsKey = 'speed.mlabConsent';
  static const String _accepted = 'accepted:';
  static const String _declined = 'declined';

  final Future<SharedPreferences> Function() _prefs;

  /// Kept when prefs fail, so the answer still holds for this session.
  SpeedConsentAnswer? _memory;

  @override
  Future<SpeedConsentAnswer> load() async {
    final memory = _memory;
    if (memory != null) return memory;
    try {
      final prefs = await _prefs();
      return _memory = decode(prefs.getString(prefsKey));
    } catch (_) {
      return SpeedConsentAnswer.unasked;
    }
  }

  @override
  Future<void> save(SpeedConsentAnswer answer) async {
    _memory = answer;
    try {
      final prefs = await _prefs();
      final value = encode(answer);
      if (value == null) {
        await prefs.remove(prefsKey);
      } else {
        await prefs.setString(prefsKey, value);
      }
    } catch (_) {
      // The memory copy holds for this session.
    }
  }

  /// The stored form of [answer]; null removes the key.
  static String? encode(SpeedConsentAnswer answer) => switch (answer.choice) {
        SpeedConsentChoice.unasked => null,
        SpeedConsentChoice.declined => _declined,
        SpeedConsentChoice.accepted => '$_accepted${answer.acceptedAt!.millisecondsSinceEpoch}',
      };

  static SpeedConsentAnswer decode(String? value) {
    if (value == _declined) return SpeedConsentAnswer.declined;
    if (value != null && value.startsWith(_accepted)) {
      final ms = int.tryParse(value.substring(_accepted.length));
      if (ms != null) return SpeedConsentAnswer.accepted(DateTime.fromMillisecondsSinceEpoch(ms));
    }
    return SpeedConsentAnswer.unasked;
  }
}

/// An in-memory store, for tests and previews.
final class MemorySpeedConsentStore implements SpeedConsentStore {
  MemorySpeedConsentStore([this.answer = SpeedConsentAnswer.unasked]);

  SpeedConsentAnswer answer;

  @override
  Future<SpeedConsentAnswer> load() async => answer;

  @override
  Future<void> save(SpeedConsentAnswer answer) async => this.answer = answer;
}

/// Where the open-network answer lives; override in tests.
final speedConsentStoreProvider = Provider<SpeedConsentStore>((ref) => PrefsSpeedConsentStore());

/// The remembered open-network answer, shared by the speed-test screen and Settings › Privacy.
final speedConsentProvider =
    AsyncNotifierProvider<SpeedConsentController, SpeedConsentAnswer>(SpeedConsentController.new);

class SpeedConsentController extends AsyncNotifier<SpeedConsentAnswer> {
  @override
  Future<SpeedConsentAnswer> build() => ref.watch(speedConsentStoreProvider).load();

  /// The user agreed at [at] (the prompt, or the Settings toggle turned on).
  Future<void> accept(DateTime at) => _set(SpeedConsentAnswer.accepted(at));

  /// "Not now" in the prompt, or the Settings toggle turned off (revoked).
  Future<void> decline() => _set(SpeedConsentAnswer.declined);

  /// The Settings › Privacy toggle.
  Future<void> setAllowed(bool allowed, {DateTime Function() now = DateTime.now}) =>
      allowed ? accept(now()) : decline();

  Future<void> _set(SpeedConsentAnswer answer) async {
    state = AsyncData(answer);
    await ref.read(speedConsentStoreProvider).save(answer);
  }
}

/// The skip memory of failed servers (ST-03); override in tests.
final speedProviderHealthProvider = FutureProvider<ProviderHealthStore>((ref) => ProviderHealthStore.load());

/// Builds the coordinator for one run. [requestConsent] asks for (or restores) the open-network
/// ticket; null means the open network is never used.
typedef SpeedTestCoordinatorFactory = SpeedTestCoordinator Function(
  ProviderHealthStore health,
  OpenNetworkConsentRequest? requestConsent,
);

/// The v1.0 service shape over the ST-03 coordinator, so the v1.0 screen contract holds.
///
/// [run] never uses the open network (nobody can be asked); the screen calls [runWithConsent] with
/// the prompt from `speed_consent_sheet.dart`.
class FallbackSpeedTestService extends SpeedTestService {
  FallbackSpeedTestService({
    required Future<ProviderHealthStore> Function() health,
    super.config,
    HttpClient Function()? clientFactory,
    SpeedTestCoordinatorFactory? coordinator,
  })  : _health = health,
        _coordinator = coordinator,
        _fallbackClientFactory = clientFactory,
        super(clientFactory: clientFactory);

  final Future<ProviderHealthStore> Function() _health;
  final SpeedTestCoordinatorFactory? _coordinator;
  final HttpClient Function()? _fallbackClientFactory;

  @override
  Stream<SpeedTestUpdate> run({NetworkCancelToken? cancel}) => runWithConsent(cancel: cancel);

  /// Same contract as [SpeedTestService.run]. The final result is a [CoordinatedSpeedTestResult];
  /// when no server could run a phase the stream fails with a [SpeedTestUnavailable].
  Stream<SpeedTestUpdate> runWithConsent({NetworkCancelToken? cancel, OpenNetworkConsentRequest? requestConsent}) {
    final token = cancel ?? NetworkCancelToken();
    StreamSubscription<SpeedTestUpdate>? inner;
    late final StreamController<SpeedTestUpdate> controller;

    Future<void> start() async {
      ProviderHealthStore health;
      try {
        health = await _health();
      } catch (_) {
        // No stored skip memory: still test, remembering skips in memory only.
        health = ProviderHealthStore();
      }
      if (token.isCancelled) {
        await controller.close();
        return;
      }
      _attach(controller, token, health, requestConsent, (s) => inner = s);
    }

    controller = StreamController<SpeedTestUpdate>(
      onListen: start,
      onCancel: () {
        token.cancel();
        return inner?.cancel();
      },
    );
    return controller.stream;
  }

  void _attach(
    StreamController<SpeedTestUpdate> controller,
    NetworkCancelToken token,
    ProviderHealthStore health,
    OpenNetworkConsentRequest? requestConsent,
    void Function(StreamSubscription<SpeedTestUpdate>) keep,
  ) {
    if (controller.isClosed) return;
    final SpeedTestCoordinator coordinator;
    try {
      coordinator = _build(health, requestConsent);
    } catch (error) {
      controller
        ..addError(SpeedTestException.from(error))
        ..close();
      return;
    }
    keep(coordinator.run(cancel: token).listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        ));
  }

  SpeedTestCoordinator _build(ProviderHealthStore health, OpenNetworkConsentRequest? requestConsent) {
    return _coordinator?.call(health, requestConsent) ??
        SpeedTestCoordinator.standard(
          health: health,
          requestOpenNetworkConsent: requestConsent,
          config: config,
          clientFactory: _fallbackClientFactory,
        );
  }
}

/// The internet speed test; override with a fake in tests.
final speedTestServiceProvider = Provider<SpeedTestService>(
  (ref) => FallbackSpeedTestService(health: () => ref.read(speedProviderHealthProvider.future)),
);

/// The stream link checker; override with a fake in tests.
final streamProbeProvider = Provider<StreamProbe>((ref) => StreamProbe());
