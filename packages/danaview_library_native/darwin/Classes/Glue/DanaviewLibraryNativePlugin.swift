// OWNER: HOM-02
//
// Placeholder (D-33) created by INT-101. HOM-02 replaces this file: the Apple glue of
// danaview_library_native (photo library, pickers, save out, share, open in, Quick Look, thumbnails, inbox). Until then the plugin registers no channel, so every Dart call fails
// with a missing-plugin error that the Dart wrappers map to notSupportedOnDevice (ARCH v1.2 V2-25).

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// The danaview_library_native plugin entry point (empty until HOM-02).
public final class DanaviewLibraryNativePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {}
}
