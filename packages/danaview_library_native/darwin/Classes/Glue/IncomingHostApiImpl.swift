// OWNER: HOM-02
//
// IncomingHostApi on Apple: Android intents only (HOM-21A). On iOS and macOS incoming files arrive
// through the v1.1 incoming media bridge and the Share Extension inbox (HOM-21), so this class
// answers `notSupportedOnDevice` permanently.

import Foundation

final class IncomingHostApiImpl: IncomingHostApi {
  init(context: LibraryPluginContext) {}

  func takePending() throws -> [IncomingBatchMsg] { throw LibraryErrors.notSupported("Android only") }

  func acknowledge(batchId: String) throws { throw LibraryErrors.notSupported("Android only") }
}
