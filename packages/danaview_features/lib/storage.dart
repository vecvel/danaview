/// Storage extension point for packages outside `danaview_features` (ARCH §17.10, ux.md §4.8): the
/// video editor and the speech model list what they keep on the device as [StorageContributor]s,
/// and the Storage screen renders them without `danaview_features` depending on those packages.
/// Entry point: `package:danaview_features/storage.dart`.
///
/// The app root overrides [storageContributorsProvider] with the contributors that exist on this
/// platform (none on desktop, D-17).
library danaview_features_storage;

export 'src/tools/media_tool_format.dart' show formatDataSize;
export 'src/tools/storage_usage.dart'
    show
        StorageClearAction,
        StorageClearOutcome,
        StorageContributor,
        StorageContributorUsage,
        StorageOpenAction,
        storageContributorsProvider;
