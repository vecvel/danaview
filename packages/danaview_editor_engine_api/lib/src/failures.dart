// OWNER: API-01
//
// Typed engine failures (ARCH §12.5, §19). No raw PlatformException ever leaves the plugin
// (`error_mapper.dart`, ENG-01); unknown codes map to [EngineErrorCode.internal].

/// Error codes shared by the Dart engine, the Pigeon glue and both native engines
/// (`FlutterError.code == EngineErrorCode.name`).
///
/// See ARCH §12.5, §19.
enum EngineErrorCode {
  /// The media file is missing or inaccessible.
  mediaOffline,

  /// The OS denied access (microphone, photos add, file).
  permissionDenied,

  /// The container or codec cannot be edited on this device.
  unsupportedMedia,

  /// A decoder could not be created.
  decoderInitFailed,

  /// Decoding failed mid-stream.
  decodeFailed,

  /// No encoder for the requested codec.
  encoderUnavailable,

  /// The encoder refused the output size (after the landscape retry, ARCH §14.1).
  encoderSizeLimit,

  /// Encoding failed.
  encodingFailed,

  /// Not enough free space.
  diskFull,

  /// Other I/O failure.
  io,

  /// A plan violated ARCH §11.3 (a bug).
  planInvalid,

  /// A patch's `from` did not match the engine revision; PlanSync resends the full plan.
  planOutOfSync,

  /// No usable GPU (Metal / GLES 3).
  gpuUnavailable,

  /// The texture surface was lost (auto-recovered).
  surfaceLost,

  /// Interrupted by the OS (backgrounding, audio session, FGS timeout).
  interrupted,

  /// Cancelled by the user. Not a failure ([EngineCancelled]).
  cancelled,

  /// The engine is busy with a conflicting job.
  busy,

  /// The feature is not available on this device (or the engine is not built yet).
  notSupportedOnDevice,

  /// Anything else (a bug).
  internal;

  /// The code for a `FlutterError.code` string; unknown strings map to [internal].
  static EngineErrorCode fromName(String? name) {
    for (final c in values) {
      if (c.name == name) return c;
    }
    return internal;
  }
}

/// A typed engine failure. Sealed: [EngineError] for failures, [EngineCancelled] for user
/// cancellation (which the UI does not report as a failure).
///
/// See ARCH §12.5, §19.
sealed class EngineFailure implements Exception {
  const EngineFailure({required this.code, this.debugDetail = '', this.itemId, this.mediaFingerprint, this.retryable = false});

  /// Creates the right subtype for [code].
  factory EngineFailure.of(
    EngineErrorCode code, {
    String debugDetail = '',
    String? itemId,
    String? mediaFingerprint,
    bool retryable = false,
  }) =>
      code == EngineErrorCode.cancelled
          ? EngineCancelled(debugDetail: debugDetail, itemId: itemId)
          : EngineError(code, debugDetail: debugDetail, itemId: itemId, mediaFingerprint: mediaFingerprint, retryable: retryable);

  /// Error code.
  final EngineErrorCode code;

  /// Diagnostic text. Never contains media paths or user content.
  final String debugDetail;

  /// Timeline item involved, when known.
  final String? itemId;

  /// `quickHash` of the media involved, when known.
  final String? mediaFingerprint;

  /// Whether retrying the same call may succeed.
  final bool retryable;

  @override
  String toString() => 'EngineFailure(${code.name}${debugDetail.isEmpty ? '' : ': $debugDetail'})';
}

/// Any engine failure other than cancellation.
///
/// See ARCH §12.5, §19.
final class EngineError extends EngineFailure {
  /// Creates an error.
  const EngineError(EngineErrorCode code, {super.debugDetail, super.itemId, super.mediaFingerprint, super.retryable})
      : assert(code != EngineErrorCode.cancelled),
        super(code: code);
}

/// The user cancelled the operation.
///
/// See ARCH §12.5, §19.
final class EngineCancelled extends EngineFailure {
  /// Creates the cancellation.
  const EngineCancelled({super.debugDetail, super.itemId}) : super(code: EngineErrorCode.cancelled);
}
