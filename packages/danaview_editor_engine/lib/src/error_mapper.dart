// OWNER: ENG-01
//
// Maps channel errors to typed engine failures (ARCH §12.5, §12.6, §19). No raw
// PlatformException ever leaves the plugin: native errors arrive as
// `FlutterError(code: EngineErrorCode.name, message, details: {itemId?, mediaFingerprint?, retryable})`;
// unknown codes map to `internal`; messages are scrubbed of paths (defence in depth: native code
// must not send paths in the first place).

import 'package:flutter/services.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'pigeon/engine_api.g.dart' show FailureMsg;

/// `PlatformException.code` that generated Pigeon code throws when no native handler answers the
/// channel (the host API is not registered: the plugin is missing or still a placeholder).
///
/// See ARCH §12.6.
const String pigeonChannelErrorCode = 'channel-error';

/// `PlatformException.code` that generated Pigeon code throws when native returned null for a
/// non-null result (a glue bug).
///
/// See ARCH §12.6.
const String pigeonNullErrorCode = 'null-error';

final RegExp _pathLike = RegExp(r'''(file|content)://\S+|(?<![\w.])/(?:[^\s/'"]+/)+[^\s'"]*''');

/// Removes anything that looks like a file path or URI from [text].
///
/// See ARCH §12.5, §19.
String scrubPaths(String text) => text.replaceAll(_pathLike, '<path>');

/// The [EngineErrorCode] for a channel error code: a known `EngineErrorCode.name`, `channel-error`
/// (no native handler) → `notSupportedOnDevice`, anything else → `internal`.
///
/// See ARCH §12.5, §12.6.
EngineErrorCode engineErrorCodeFor(String? code) =>
    code == pigeonChannelErrorCode ? EngineErrorCode.notSupportedOnDevice : EngineErrorCode.fromName(code);

/// Converts any error thrown by a channel call into an [EngineFailure].
///
/// See ARCH §12.5, §19.
EngineFailure mapEngineError(Object error) {
  if (error is EngineFailure) return error;
  if (error is PlatformException) {
    final details = error.details;
    final map = details is Map ? details : const <Object?, Object?>{};
    final itemId = map['itemId'];
    final fingerprint = map['mediaFingerprint'];
    final code = engineErrorCodeFor(error.code);
    return EngineFailure.of(
      code,
      debugDetail: _detail(code, error.code, error.message),
      itemId: itemId is String ? itemId : null,
      mediaFingerprint: fingerprint is String ? fingerprint : null,
      retryable: map['retryable'] == true,
    );
  }
  if (error is MissingPluginException) {
    return EngineFailure.of(EngineErrorCode.notSupportedOnDevice, debugDetail: 'engine plugin not registered on this platform');
  }
  return EngineFailure.of(EngineErrorCode.internal, debugDetail: error.runtimeType.toString());
}

/// Converts a failure carried by an event into an [EngineFailure].
///
/// See ARCH §12.5, §12.6.
EngineFailure failureFromMsg(FailureMsg msg) {
  final code = engineErrorCodeFor(msg.code);
  return EngineFailure.of(
    code,
    debugDetail: _detail(code, msg.code, msg.message),
    itemId: msg.itemId,
    mediaFingerprint: msg.mediaFingerprint,
    retryable: msg.retryable,
  );
}

/// Debug text of a mapped failure: the scrubbed message, prefixed with the raw code when an
/// unknown code was mapped to `internal` (so diagnostics keep it).
String _detail(EngineErrorCode code, String? rawCode, String? message) {
  final text = message ?? '';
  final keepCode = code == EngineErrorCode.internal && rawCode != null && rawCode != EngineErrorCode.internal.name;
  return scrubPaths(keepCode ? (text.isEmpty ? rawCode : '$rawCode: $text') : text);
}

/// Runs [call] and rethrows any error as an [EngineFailure] (keeping the stack trace).
///
/// See ARCH §12.5, §19.
Future<T> guardEngineCall<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on Object catch (e, st) {
    Error.throwWithStackTrace(mapEngineError(e), st);
  }
}
