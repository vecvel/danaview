// OWNER: HOM-02A
//
// Placeholder (D-33) created by INT-101. HOM-02A replaces this file: the Android glue of
// danaview_library_native (photo library, pickers, save out, share, open in, Quick Look, thumbnails, inbox). Until then the plugin registers no channel, so every Dart call fails
// with a missing-plugin error that the Dart wrappers map to notSupportedOnDevice (ARCH v1.2 V2-25).

package com.vecvel.danaview.library.glue

import io.flutter.embedding.engine.plugins.FlutterPlugin

/** The danaview_library_native plugin entry point (empty until HOM-02A). */
class DanaviewLibraryNativePlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {}

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
