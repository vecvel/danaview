// OWNER: HOM-22
//
// Pigeon glue shared by ExportOut/, Share/ and OpenIn/ (ARCH v1.2 V2-25): message ↔ core
// conversions, the Pigeon error of an OutFailure, main-thread replies and the popover anchor of a
// request (logical pixels in the Flutter view; the view's bottom centre when none is given).

import Foundation

#if os(iOS)
import Flutter
import UIKit
#elseif os(macOS)
import Cocoa
import FlutterMacOS
#endif

enum FileOutGlue {
  /// The core file of a Pigeon item.
  static func outFile(_ m: FileItemMsg) -> OutFile {
    OutFile(path: m.path, displayName: m.displayName, uti: m.uti, mimeType: m.mimeType)
  }

  /// The Pigeon error of [failure].
  static func error(_ failure: OutFailure) -> LibraryPigeonError {
    LibraryPigeonError(code: failure.code, message: failure.message, details: nil)
  }

  /// The Pigeon error of any thrown error (OutFailure keeps its code, anything else is ioError).
  static func error(_ any: Error) -> LibraryPigeonError {
    if let f = any as? OutFailure { return error(f) }
    return error(OutFailure.io("file-out failed"))
  }

  /// The anchor of a request as a rect, or nil.
  static func rect(_ anchor: AnchorRectMsg?) -> CGRect? {
    guard let a = anchor, a.width >= 0, a.height >= 0, a.x.isFinite, a.y.isFinite else { return nil }
    return CGRect(x: a.x, y: a.y, width: a.width, height: a.height)
  }

  /// [anchor], or a 1×1 rect at the bottom centre of [bounds].
  static func anchor(_ anchor: CGRect?, in bounds: CGRect) -> CGRect {
    if let a = anchor { return a }
    return CGRect(x: bounds.midX, y: bounds.maxY - 1, width: 1, height: 1)
  }

  /// Calls [completion] on the main thread.
  static func reply<T>(_ completion: @escaping (Result<T, Error>) -> Void, _ result: Result<T, Error>) {
    if Thread.isMainThread {
      completion(result)
    } else {
      DispatchQueue.main.async { completion(result) }
    }
  }
}
