// OWNER: HOM-02
//
// What every native class of danaview_library_native receives from the Glue (ARCH v1.2 V2-25):
// the binary messenger, the multiplexed event stream and the platform presentation anchor
// (topmost view controller on iOS, key window on macOS). Classes owned by later tickets
// (Pickers/, Thumbnails/, ExportOut/, Share/, OpenIn/, QuickLook/, Inbox/) keep the
// `init(context:)` initializer the Glue calls.

import Foundation

#if os(iOS)
import Flutter
import UIKit
#elseif os(macOS)
import Cocoa
import FlutterMacOS
#endif

/// Shared plugin services for the native API classes.
final class LibraryPluginContext {
  /// The engine's binary messenger.
  let messenger: FlutterBinaryMessenger

  /// The multiplexed `LibraryEventsApi.libraryEvents` stream.
  let events: LibraryEventHub

  init(messenger: FlutterBinaryMessenger, events: LibraryEventHub) {
    self.messenger = messenger
    self.events = events
  }

  #if os(iOS)
  /// The view controller to present system UI from (topmost presented controller of the key
  /// window), or nil before a window exists. Main thread only.
  func presentingViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap { $0.windows }
    var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
    return top
  }
  #elseif os(macOS)
  /// The window to attach sheets and panels to, or nil. Main thread only.
  func presentingWindow() -> NSWindow? {
    NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first
  }
  #endif
}
