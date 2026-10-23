// OWNER: HOM-21A
//
// The Android incoming VIEW / SEND intents wrapper (ARCH v1.2 §5.6, INT-104, BUILD_PLAN HOM-21A)
// over the frozen Pigeon surface (IncomingHostApi and the `incoming` library event).
//
// Android hands "Open with Danaview" (ACTION_VIEW of a document, text or image) and "Share to
// Danaview" (ACTION_SEND, ACTION_SEND_MULTIPLE) to the plugin, which turns each intent into one
// [IncomingBatch] of platform URIs. Videos opened from another app are not batches: they keep the
// 1.1 path through `incoming_media_bridge` and play at once (P-7). A share of several items is a
// batch even when it holds videos (it imports them, as the iOS Share Extension does).
//
// Use (HOM-21's import side): listen to [NativeIncoming.batches] first, then call
// [NativeIncoming.takePending] at launch and on every resume; each batch arrives on [batches] once
// per [NativeIncoming] (a batch id already delivered is dropped). Import each item at once with
// `NativePickers.copyToFile(sourceUri: item.uri, ...)` (the read grant lives with the app's
// Activity), then [NativeIncoming.acknowledge] the batch to release what it held (a kept grant,
// the file of a text share). Apple answers `notSupportedOnDevice` (it uses the Share Extension
// inbox, native_inbox.dart). Nothing here logs a name, a path or a URI (rule 30).

import 'dart:async';

import 'package:flutter/services.dart';

import 'pigeon/library_api.g.dart';
import 'pigeon/library_channels.dart';

/// The Android intent an [IncomingBatch] came from.
enum IncomingAction {
  /// `ACTION_VIEW`: "Open with Danaview" (one item).
  view,

  /// `ACTION_SEND`: a share of one item, or of text (one `text/plain` file).
  send,

  /// `ACTION_SEND_MULTIPLE`: a share of several items.
  sendMultiple,
}

/// One item of an incoming intent.
final class IncomingItem {
  /// An item.
  const IncomingItem({required this.uri, this.displayName, this.mimeType, this.sizeBytes});

  /// `content://` or `file://` URI, read with `NativePickers.copyToFile`.
  final String uri;

  /// The name to import as (the provider's, else from the URI; clashes in a batch are numbered).
  final String? displayName;

  /// MIME type, when known.
  final String? mimeType;

  /// Size, when the provider reported it.
  final int? sizeBytes;

  // Never prints names or URIs (rule 30).
  @override
  String toString() => 'IncomingItem(${mimeType ?? 'unknown type'})';
}

/// One incoming intent.
final class IncomingBatch {
  /// A batch.
  const IncomingBatch({required this.batchId, required this.action, required this.items});

  /// Pass to [NativeIncoming.acknowledge] once handled.
  final String batchId;

  /// Which intent.
  final IncomingAction action;

  /// The items, in the sender's order.
  final List<IncomingItem> items;

  @override
  String toString() => 'IncomingBatch(${action.name}, ${items.length} item(s))';
}

/// [IncomingBatch] of a Pigeon message (tests and the wrapper).
IncomingBatch incomingBatchFromMessage(IncomingBatchMsg m) => IncomingBatch(
      batchId: m.batchId,
      action: IncomingAction.values[m.action.index],
      items: List.unmodifiable([
        for (final i in m.items) IncomingItem(uri: i.uri, displayName: i.displayName, mimeType: i.mimeType, sizeBytes: i.sizeBytes),
      ]),
    );

/// Android incoming intents over the plugin's Pigeon surface. Every call throws
/// `LibraryNativeException` (`notSupportedOnDevice` on Apple and desktop).
final class NativeIncoming {
  /// The incoming intents of the default engine; tests pass a mock [binaryMessenger] and [events].
  NativeIncoming({BinaryMessenger? binaryMessenger, String messageChannelSuffix = '', LibraryEventHub? events})
      : _api = IncomingHostApi(binaryMessenger: binaryMessenger, messageChannelSuffix: messageChannelSuffix),
        _events = events ?? LibraryEventHub.forInstance(messageChannelSuffix);

  /// How many delivered batch ids are remembered to drop a second delivery.
  static const _rememberedIds = 256;

  final IncomingHostApi _api;
  final LibraryEventHub _events;
  final _delivered = <String>{};
  StreamSubscription<LibraryEventMsg>? _subscription;
  late final StreamController<IncomingBatch> _controller = StreamController<IncomingBatch>.broadcast(
    onListen: () => _subscription = _events.of(LibraryEventKindMsg.incoming).listen((e) {
      final m = e.incoming;
      if (m != null) _deliver(incomingBatchFromMessage(m));
    }),
    onCancel: () async {
      final s = _subscription;
      _subscription = null;
      await s?.cancel();
    },
  );

  /// Each incoming batch once: those announced while the app runs (warm start) and those
  /// [takePending] returns (cold start, or announced while nothing listened).
  Stream<IncomingBatch> get batches => _controller.stream;

  /// Batches received before Dart listened, each returned by the platform once. They are also
  /// added to [batches] (unless already delivered there), so a listener needs only [batches].
  Future<List<IncomingBatch>> takePending() => guardNative(() async {
        final out = <IncomingBatch>[];
        for (final m in await _api.takePending()) {
          final b = incomingBatchFromMessage(m);
          if (_deliver(b)) out.add(b);
        }
        return out;
      });

  /// Releases what the handled batch [batchId] held (a kept read grant, a text share's file).
  /// Unknown ids are ignored.
  Future<void> acknowledge(String batchId) => guardNative(() => _api.acknowledge(batchId));

  /// Adds [b] to [batches] unless its id was delivered before; false for a repeat.
  bool _deliver(IncomingBatch b) {
    if (!_delivered.add(b.batchId)) return false;
    if (_delivered.length > _rememberedIds) _delivered.remove(_delivered.first);
    if (_controller.hasListener) _controller.add(b);
    return true;
  }
}
