// OWNER: HOM-02
//
// The one native end of `LibraryEventsApi.libraryEvents` (ARCH v1.2 V2-111): every native class
// emits through it; events are delivered on the main thread and dropped while Dart isn't
// listening (Dart re-reads state when it subscribes).

import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

final class LibraryEventHub: LibraryEventsStreamHandler {
  private var sink: PigeonEventSink<LibraryEventMsg>?

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<LibraryEventMsg>) {
    self.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  /// True while Dart listens (main thread).
  var isListening: Bool { sink != nil }

  /// Sends [event] to Dart from any thread.
  func emit(_ event: LibraryEventMsg) {
    if Thread.isMainThread {
      sink?.success(event)
    } else {
      DispatchQueue.main.async { [weak self] in self?.sink?.success(event) }
    }
  }
}
