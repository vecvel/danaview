// OWNER: ST-01
//
// One speed-test backend (V2-401, D-ST1). Each phase is a separate call so the coordinator (ST-03)
// can restart only the failing phase on the next provider (D-ST3), and a phase's numbers always
// come from one provider (G5).

import '../speed_test.dart' show NetworkCancelToken;
import 'phase_result.dart';

abstract interface class SpeedTestProvider {
  /// Stable internal id for attribution and the skip memory (`cloudflare`, `mlab`). Never shown
  /// in the UI (D-ST5).
  String get id;

  /// Idle round trips. With [health], the first request is the zero-byte health check and must
  /// answer within the provider's health timeout (about 1.5 s, D-ST3); otherwise it is an ordinary
  /// warm-up request.
  ///
  /// Every method: cancelling [cancel] closes the phase's sockets at once and the call throws
  /// [SpeedTestCancelled]; any other failure is a [SpeedProviderFailure]. A provider opens no
  /// connection before one of these is called.
  Future<SpeedLatencyResult> latency({
    required NetworkCancelToken cancel,
    bool health = false,
    SpeedProgressCallback? onProgress,
  });

  Future<SpeedTransferResult> download({required NetworkCancelToken cancel, SpeedProgressCallback? onProgress});

  Future<SpeedTransferResult> upload({required NetworkCancelToken cancel, SpeedProgressCallback? onProgress});
}
