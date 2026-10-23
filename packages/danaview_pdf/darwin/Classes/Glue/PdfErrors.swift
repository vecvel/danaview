// OWNER: HOM-24
//
// Pigeon errors of the PDF surface (pigeons/pdf_api.dart, "Errors"): the code is a `PdfErrorCode`
// name, the message debug text without names, paths or document text (rule 30), no details.
// Native exceptions map to typed failures here (ARCH v1.2 §11: no PDF action can crash the app).

import Foundation

enum PdfErrors {
  /// The error a host method answers with [code].
  static func error(_ code: PdfErrorCode, _ message: String) -> PdfPigeonError {
    PdfPigeonError(code: code.rawValue, message: message, details: nil)
  }

  /// `notSupportedOnDevice`: the capability does not exist on this platform, or the ticket that
  /// implements it ([owner]) has not landed yet.
  static func notSupported(_ owner: String) -> PdfPigeonError {
    error(.notSupportedOnDevice, "not supported on this device (\(owner))")
  }

  /// The Pigeon error of any thrown error: a PdfFailure keeps its code, anything else is `internal`.
  static func from(_ error: Error) -> PdfPigeonError {
    if let pigeon = error as? PdfPigeonError { return pigeon }
    if let failure = error as? PdfFailure { return self.error(failure.code, failure.message) }
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
      return self.error(.noSpace, "out of space")
    }
    return self.error(.internal, "unexpected error")
  }
}
