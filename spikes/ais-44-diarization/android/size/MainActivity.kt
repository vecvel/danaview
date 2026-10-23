package com.vecvel.ais44size

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

// Creates the app's external files dir (owned by the app) so smoke.sh can push
// the models and clip there for the Dart FFI smoke.
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        getExternalFilesDir(null)
        super.onCreate(savedInstanceState)
    }
}
