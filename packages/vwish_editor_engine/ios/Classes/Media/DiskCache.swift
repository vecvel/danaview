// OWNER: IOS-03
//
// D-33 placeholder created by ENG-07: LRU disk caches and the launch wipe of work/ (ARCH §15).
// Only IOS-03 edits this file once it lands.
// The glue calls it through `CacheMaintaining` (Glue/ServiceProtocols.swift) and builds it with
// `init(context:)` (Glue/EngineServices.swift): keep both. Until then every call fails with
// `notSupportedOnDevice`, which Dart maps to the editor's unsupported state.

import Foundation

final class DiskCache: CacheMaintaining {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    /// Nothing is cached yet.
    func engineDidInitialize(paths: Paths) {}

    /// Nothing is cached yet.
    func trim(_ level: CacheTrimLevelMsg) {}
}
