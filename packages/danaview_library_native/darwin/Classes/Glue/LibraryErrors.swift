// OWNER: HOM-02
//
// Pigeon errors of the library surface (pigeons/library_api.dart, "Errors"): the code is a
// `LibraryErrorCode` name, the message debug text without names or paths (rule 30), no details.

import Foundation

enum LibraryErrors {
  /// The error a host method answers with [code].
  static func error(_ code: LibraryErrorCode, _ message: String) -> LibraryPigeonError {
    LibraryPigeonError(code: code.rawValue, message: message, details: nil)
  }

  /// `notSupportedOnDevice`: the capability does not exist on this platform, or the ticket that
  /// implements it ([owner]) has not landed yet.
  static func notSupported(_ owner: String) -> LibraryPigeonError {
    error(.notSupportedOnDevice, "not supported on this device (\(owner))")
  }

  /// The Pigeon error of a PhotoLibrary failure.
  static func from(_ failure: PhotoLibraryFailure) -> LibraryPigeonError {
    error(failure.code, failure.message)
  }
}
