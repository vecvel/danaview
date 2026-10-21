// OWNER: VED-16A
//
// Placeholder (D-33) created by INT-101. VED-16A replaces this file: the Android glue of
// danaview_face_tracking (face mesh, pose and segmentation trackers, video sampling). Until then the plugin registers no channel, so every Dart call fails
// with a missing-plugin error that the Dart wrappers map to notSupportedOnDevice (ARCH v1.2 V2-25).

package com.vecvel.danaview.face.glue

import io.flutter.embedding.engine.plugins.FlutterPlugin

/** The danaview_face_tracking plugin entry point (empty until VED-16A). */
class DanaviewFaceTrackingPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {}

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
