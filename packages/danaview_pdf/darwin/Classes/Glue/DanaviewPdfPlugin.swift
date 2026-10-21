// OWNER: HOM-24
//
// Placeholder (D-33) created by INT-101. HOM-24 replaces this file: the Apple glue of
// danaview_pdf (PDF viewer, text and page tools). Until then the plugin registers no channel, so every Dart call fails
// with a missing-plugin error that the Dart wrappers map to notSupportedOnDevice (ARCH v1.2 V2-25).

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// The danaview_pdf plugin entry point (empty until HOM-24).
public final class DanaviewPdfPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {}
}
