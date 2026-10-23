// OWNER: HOM-02
//
// Shared, private plumbing of the Dart wrappers over the Pigeon surface (pigeons/library_api.dart):
// error mapping to LibraryNativeException and the single subscription to the multiplexed
// `LibraryEventsApi.libraryEvents` stream (an EventChannel has one native listener, so every
// wrapper listens through [LibraryEventHub]). Wrappers of later tickets (HOM-04, HOM-20, HOM-21,
// HOM-21A, HOM-22, HOM-26) use [guardNative] and [LibraryEventHub] too.

import 'dart:async';

import 'package:flutter/services.dart';

import '../native_photo_library.dart';
import 'library_api.g.dart';

/// Runs [call] and maps platform errors to [LibraryNativeException]: Pigeon's `channel-error` and
/// a missing plugin become `notSupportedOnDevice`, an unknown code `internal`.
Future<T> guardNative<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on PlatformException catch (e) {
    throw LibraryNativeException(LibraryNativeErrorCode.fromCode(e.code), e.message ?? e.code);
  } on MissingPluginException catch (e) {
    throw LibraryNativeException(LibraryNativeErrorCode.notSupportedOnDevice, e.message ?? 'missing plugin');
  }
}

/// The one Dart subscription to the library event stream of an engine instance, fanned out as a
/// broadcast stream. Subscribes on the first listener and cancels after the last.
final class LibraryEventHub {
  LibraryEventHub._(this._source);

  static final Map<String, LibraryEventHub> _hubs = {};

  /// The hub of [instanceName] (the Pigeon message channel suffix).
  static LibraryEventHub forInstance([String instanceName = '']) =>
      _hubs.putIfAbsent(instanceName, () => LibraryEventHub._(() => libraryEvents(instanceName: instanceName)));

  /// A hub over [source] (tests).
  factory LibraryEventHub.over(Stream<LibraryEventMsg> Function() source) => LibraryEventHub._(source);

  final Stream<LibraryEventMsg> Function() _source;
  StreamSubscription<LibraryEventMsg>? _subscription;
  late final StreamController<LibraryEventMsg> _controller = StreamController<LibraryEventMsg>.broadcast(
    onListen: () {
      _subscription = _source().listen(
        _controller.add,
        // Native stream errors carry no payload worth surfacing; the next event resynchronizes.
        onError: (Object _) {},
      );
    },
    onCancel: () async {
      final s = _subscription;
      _subscription = null;
      await s?.cancel();
    },
  );

  /// Every library event.
  Stream<LibraryEventMsg> get events => _controller.stream;

  /// The events of [kind].
  Stream<LibraryEventMsg> of(LibraryEventKindMsg kind) => events.where((e) => e.kind == kind);
}
