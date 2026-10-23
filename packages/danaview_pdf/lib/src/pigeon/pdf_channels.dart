// OWNER: HOM-24
//
// Shared, private plumbing of the Dart wrappers over the Pigeon surface (pigeons/pdf_api.dart):
// error mapping to PdfException and the single subscription to the multiplexed
// `PdfEventsApi.pdfEvents` stream (an EventChannel has one native listener, so every wrapper
// listens through [PdfEventHub]). The tools wrapper of HOM-28 uses [guardPdf] and [PdfEventHub] too.

import 'dart:async';

import 'package:flutter/services.dart';

import '../pdf_document.dart';
import 'pdf_api.g.dart';

/// Runs [call] and maps platform errors to [PdfException]: Pigeon's `channel-error` and a missing
/// plugin become `notSupportedOnDevice`, an unknown code `internal`.
Future<T> guardPdf<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on PlatformException catch (e) {
    throw PdfException(PdfErrorCode.fromCode(e.code), e.message ?? e.code);
  } on MissingPluginException catch (e) {
    throw PdfException(PdfErrorCode.notSupportedOnDevice, e.message ?? 'missing plugin');
  }
}

/// The one Dart subscription to the PDF event stream of an engine instance, fanned out as a
/// broadcast stream. Subscribes on the first listener and cancels after the last.
final class PdfEventHub {
  PdfEventHub._(this._source);

  static final Map<String, PdfEventHub> _hubs = {};

  /// The hub of [instanceName] (the Pigeon message channel suffix).
  static PdfEventHub forInstance([String instanceName = '']) =>
      _hubs.putIfAbsent(instanceName, () => PdfEventHub._(() => pdfEvents(instanceName: instanceName)));

  /// A hub over [source] (tests).
  factory PdfEventHub.over(Stream<PdfEventMsg> Function() source) => PdfEventHub._(source);

  final Stream<PdfEventMsg> Function() _source;
  StreamSubscription<PdfEventMsg>? _subscription;
  late final StreamController<PdfEventMsg> _controller = StreamController<PdfEventMsg>.broadcast(
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

  /// Every PDF event.
  Stream<PdfEventMsg> get events => _controller.stream;
}
