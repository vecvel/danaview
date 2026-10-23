// OWNER: VED-16
//
// Placeholder (D-33) created by INT-101. VED-16 replaces this file: the Apple glue of
// danaview_face_tracking (face mesh, pose and segmentation trackers, video sampling). Until then the plugin registers no channel, so every Dart call fails
// with a missing-plugin error that the Dart wrappers map to notSupportedOnDevice (ARCH v1.2 V2-25).

import Flutter

/// The danaview_face_tracking plugin entry point (empty until VED-16).
public final class DanaviewFaceTrackingPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {}
}
