// OWNER: HOM-25
//
// Placeholder (D-33) created by INT-101. HOM-25 replaces this file: the Android glue of
// danaview_pdf (PDF viewer, text and page tools). Until then the plugin registers no channel, so every Dart call fails
// with a missing-plugin error that the Dart wrappers map to notSupportedOnDevice (ARCH v1.2 V2-25).

package com.vecvel.danaview.pdf.glue

import io.flutter.embedding.engine.plugins.FlutterPlugin

/** The danaview_pdf plugin entry point (empty until HOM-25). */
class DanaviewPdfPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {}

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
