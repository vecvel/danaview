// OWNER: ENG-01
//
// A mocked native side for Dart tests of the engine plugin (ARCH §21.1 "Engine Dart"): answers the
// generated Pigeon host API channels on the test binary messenger with the real Pigeon codec, and
// drives the EngineEventsApi event channel. Methods without a handler get no answer, exactly like
// a host API the native plugin has not registered (`channel-error` → `notSupportedOnDevice`).
// ENG-02/03/04 tests may import it with a relative path.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_engine/src/pigeon/engine_api.g.dart';

/// Answers one host method call: return the reply value, or throw a [PlatformException] (sent as a
/// Pigeon error reply, like a native `FlutterError`).
typedef HostHandler = FutureOr<Object?> Function(List<Object?> args);

/// A fake native engine on [TestDefaultBinaryMessengerBinding]'s messenger.
final class MockEngineHost {
  /// Creates the mock for host APIs created with [suffix] as `messageChannelSuffix`.
  MockEngineHost({this.suffix = ''});

  /// The `messageChannelSuffix` of the host APIs under test.
  final String suffix;

  /// Every call received, as `Api.method`, in order.
  final List<String> calls = [];

  /// Arguments of every call received, by `Api.method`.
  final Map<String, List<List<Object?>>> args = {};

  final Set<String> _channels = {};
  StreamController<Object?>? _events;
  EventChannel? _eventChannel;

  /// How often Dart subscribed to the event channel.
  int listenCount = 0;

  /// Codec shared by every generated host API.
  static const MessageCodec<Object?> codec = EngineHostApi.pigeonChannelCodec;

  TestDefaultBinaryMessenger get _messenger => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  String _channel(String api, String method) => 'dev.flutter.pigeon.danaview_editor_engine.$api.$method${suffix.isEmpty ? '' : '.$suffix'}';

  /// Answers `api.method` with [handler].
  void on(String api, String method, HostHandler handler) {
    final name = _channel(api, method);
    _channels.add(name);
    _messenger.setMockMessageHandler(name, (ByteData? data) async {
      final decoded = (codec.decodeMessage(data) as List<Object?>?) ?? const <Object?>[];
      calls.add('$api.$method');
      (args['$api.$method'] ??= []).add(decoded);
      try {
        final result = await handler(decoded);
        return codec.encodeMessage(<Object?>[result]);
      } on PlatformException catch (e) {
        return codec.encodeMessage(<Object?>[e.code, e.message, e.details]);
      }
    });
  }

  /// Answers `api.method` with a native error `FlutterError(code, message, details)`.
  void fail(String api, String method, String code, {String? message, Object? details}) =>
      on(api, method, (_) => throw PlatformException(code: code, message: message, details: details));

  /// Answers `EngineHostApi.initialize` successfully (the native engine exists).
  void acceptInitialize() => on('EngineHostApi', 'initialize', (_) => null);

  /// Number of calls to `api.method`.
  int count(String api, String method) => calls.where((c) => c == '$api.$method').length;

  /// Installs the EngineEventsApi stream handler; returns the sink tests push events into.
  StreamController<Object?> installEvents() {
    final controller = StreamController<Object?>.broadcast();
    _events = controller;
    final channel = EventChannel(
      'dev.flutter.pigeon.danaview_editor_engine.EngineEventsApi.engineEvents${suffix.isEmpty ? '' : '.$suffix'}',
      pigeonMethodCodec,
    );
    _eventChannel = channel;
    StreamSubscription<Object?>? sub;
    _messenger.setMockStreamHandler(
      channel,
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink sink) {
          listenCount++;
          sub = controller.stream.listen((e) {
            if (e is PlatformException) {
              sink.error(code: e.code, message: e.message, details: e.details);
            } else {
              sink.success(e);
            }
          });
        },
        onCancel: (Object? arguments) => sub?.cancel(),
      ),
    );
    return controller;
  }

  /// Removes every handler installed by this mock.
  void dispose() {
    for (final name in _channels) {
      _messenger.setMockMessageHandler(name, null);
    }
    _channels.clear();
    final events = _eventChannel;
    if (events != null) _messenger.setMockStreamHandler(events, null);
    unawaited(_events?.close());
  }
}
