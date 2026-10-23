// OWNER: HOM-02
//
// The Apple glue of danaview_library_native (ARCH v1.2 V2-25, §8): registers every host API of the
// frozen Pigeon surface (pigeons/library_api.dart) and the library event stream, routing each API
// to one class in its own directory:
//
//   PhotoLibraryHostApi → PhotoLibraryHostApiImpl (Glue/, over PhotoLibrary/; HOM-02)
//   PickerHostApi       → Pickers/PickerHostApiImpl          (HOM-20)
//   ThumbnailHostApi    → Thumbnails/ThumbnailHostApiImpl    (HOM-04; documents HOM-26)
//   ExportOutHostApi    → ExportOut/ExportOutHostApiImpl     (HOM-22)
//   ShareHostApi        → Share/ShareHostApiImpl             (HOM-22)
//   OpenInHostApi       → OpenIn/OpenInHostApiImpl           (HOM-22)
//   QuickLookHostApi    → QuickLook/QuickLookHostApiImpl     (HOM-26)
//   InboxHostApi        → Inbox/InboxHostApiImpl             (HOM-21)
//   IncomingHostApi     → Glue/IncomingHostApiImpl           (Android only: notSupportedOnDevice)
//   BackupFlagHostApi   → Glue/BackupFlagHostApiImpl         (HOM-02)
//
// Classes of later tickets start as placeholders answering `notSupportedOnDevice`.

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// The danaview_library_native plugin entry point.
public final class DanaviewLibraryNativePlugin: NSObject, FlutterPlugin {
  private let context: LibraryPluginContext
  private let photoLibrary: PhotoLibraryHostApiImpl
  private let pickers: PickerHostApiImpl
  private let thumbnails: ThumbnailHostApiImpl
  private let exportOut: ExportOutHostApiImpl
  private let share: ShareHostApiImpl
  private let openIn: OpenInHostApiImpl
  private let quickLook: QuickLookHostApiImpl
  private let inbox: InboxHostApiImpl
  private let incoming: IncomingHostApiImpl
  private let backupFlags: BackupFlagHostApiImpl

  init(messenger: FlutterBinaryMessenger) {
    context = LibraryPluginContext(messenger: messenger, events: LibraryEventHub())
    photoLibrary = PhotoLibraryHostApiImpl(context: context)
    pickers = PickerHostApiImpl(context: context)
    thumbnails = ThumbnailHostApiImpl(context: context)
    exportOut = ExportOutHostApiImpl(context: context)
    share = ShareHostApiImpl(context: context)
    openIn = OpenInHostApiImpl(context: context)
    quickLook = QuickLookHostApiImpl(context: context)
    inbox = InboxHostApiImpl(context: context)
    incoming = IncomingHostApiImpl(context: context)
    backupFlags = BackupFlagHostApiImpl(context: context)
    super.init()
  }

  /// Sets up every channel on [messenger] (nil APIs tear them down).
  func setUpChannels(_ messenger: FlutterBinaryMessenger, attach: Bool) {
    PhotoLibraryHostApiSetup.setUp(binaryMessenger: messenger, api: attach ? photoLibrary : nil)
    PickerHostApiSetup.setUp(binaryMessenger: messenger, api: attach ? pickers : nil)
    ThumbnailHostApiSetup.setUp(binaryMessenger: messenger, api: attach ? thumbnails : nil)
    ExportOutHostApiSetup.setUp(binaryMessenger: messenger, api: attach ? exportOut : nil)
    ShareHostApiSetup.setUp(binaryMessenger: messenger, api: attach ? share : nil)
    OpenInHostApiSetup.setUp(binaryMessenger: messenger, api: attach ? openIn : nil)
    QuickLookHostApiSetup.setUp(binaryMessenger: messenger, api: attach ? quickLook : nil)
    InboxHostApiSetup.setUp(binaryMessenger: messenger, api: attach ? inbox : nil)
    IncomingHostApiSetup.setUp(binaryMessenger: messenger, api: attach ? incoming : nil)
    BackupFlagHostApiSetup.setUp(binaryMessenger: messenger, api: attach ? backupFlags : nil)
    if attach { LibraryEventsStreamHandler.register(with: messenger, streamHandler: context.events) }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let plugin = DanaviewLibraryNativePlugin(messenger: messenger)
    plugin.setUpChannels(messenger, attach: true)
    registrar.publish(plugin)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    photoLibrary.service.stopObserving()
    setUpChannels(context.messenger, attach: false)
  }
}
