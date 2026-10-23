// OWNER: HOM-24
//
// The one native end of `PdfEventsApi.pdfEvents`: views and tool jobs emit through it; events are
// delivered on the main thread and dropped while Dart isn't listening (Dart re-reads view state
// when it subscribes).

import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

final class PdfEventHub: PdfEventsStreamHandler {
  private var sink: PigeonEventSink<PdfEventMsg>?

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<PdfEventMsg>) {
    self.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  /// True while Dart listens (main thread).
  var isListening: Bool { sink != nil }

  /// Sends [event] to Dart from any thread.
  func emit(_ event: PdfEventMsg) {
    if Thread.isMainThread {
      sink?.success(event)
    } else {
      DispatchQueue.main.async { [weak self] in self?.sink?.success(event) }
    }
  }
}
