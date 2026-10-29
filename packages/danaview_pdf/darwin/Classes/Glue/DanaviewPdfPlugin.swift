// OWNER: HOM-24
//
// The Apple glue of danaview_pdf (ARCH v1.2 V2-25, §8): registers every host API of the frozen
// Pigeon surface (pigeons/pdf_api.dart), the PDF event stream and the PDFKit platform view,
// routing each API to one class:
//
//   PdfDocumentHostApi → Glue/PdfDocumentHostApiImpl  (over Viewer/PdfCore; HOM-24)
//   PdfViewHostApi     → Viewer/PdfViewHostApiImpl    (HOM-24; texture views are Android's)
//   PdfTextHostApi     → Text/PdfTextHostApiImpl      (HOM-24)
//   PdfOrganiseHostApi → Glue/PdfToolsHostApiImpl     (HOM-28 amendment; Tools/PdfPageTools)
//   PdfToolsHostApi    → Glue/PdfToolsHostApiImpl     (jobs; tools in Tools/ HOM-28,
//                                                      Annotate/ HOM-29, Sign/ HOM-30,
//                                                      Compress/ HOM-31)
//   view type `com.vecvel.danaview.pdf/view` → Viewer/PdfViewFactory
//
// Tool classes of later tickets start as placeholders answering `notSupportedOnDevice`.

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// The danaview_pdf plugin entry point.
public final class DanaviewPdfPlugin: NSObject, FlutterPlugin {
  let messenger: FlutterBinaryMessenger
  let events = PdfEventHub()
  let store = PdfDocumentStore()
  let registry = PdfViewRegistry()
  let documents: PdfDocumentHostApiImpl
  let views: PdfViewHostApiImpl
  let text = PdfTextHostApiImpl()
  let tools: PdfToolsHostApiImpl

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    documents = PdfDocumentHostApiImpl(store: store)
    views = PdfViewHostApiImpl(store: store, registry: registry)
    tools = PdfToolsHostApiImpl(events: events)
    super.init()
  }

  /// Sets up every channel on [messenger] (detach tears them down).
  func setUpChannels(_ messenger: FlutterBinaryMessenger, attach: Bool) {
    PdfDocumentHostApiSetup.setUp(binaryMessenger: messenger, api: attach ? documents : nil)
    PdfViewHostApiSetup.setUp(binaryMessenger: messenger, api: attach ? views : nil)
    PdfTextHostApiSetup.setUp(binaryMessenger: messenger, api: attach ? text : nil)
    PdfToolsHostApiSetup.setUp(binaryMessenger: messenger, api: attach ? tools : nil)
    // HOM-28 amendment: the one-pass page organiser, on the tools host (shared jobs and cancel).
    PdfOrganiseHostApiSetup.setUp(binaryMessenger: messenger, api: attach ? tools : nil)
    if attach { PdfEventsStreamHandler.register(with: messenger, streamHandler: events) }
  }

  /// The platform view factory of this plugin instance.
  func makeViewFactory() -> PdfViewFactory {
    PdfViewFactory(store: store, registry: registry, events: events)
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let plugin = DanaviewPdfPlugin(messenger: messenger)
    plugin.setUpChannels(messenger, attach: true)
    registrar.register(plugin.makeViewFactory(), withId: PdfViewFactory.viewType)
    registrar.publish(plugin)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    setUpChannels(messenger, attach: false)
  }
}
