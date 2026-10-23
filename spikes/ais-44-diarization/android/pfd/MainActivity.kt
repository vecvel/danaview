package com.vecvel.ais44size

import android.content.Context
import com.google.android.play.core.splitcompat.SplitCompat
import com.google.android.play.core.splitinstall.SplitInstallHelper
import com.google.android.play.core.splitinstall.SplitInstallManagerFactory
import com.google.android.play.core.splitinstall.SplitInstallRequest
import com.google.android.play.core.splitinstall.model.SplitInstallSessionStatus
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// AIS-44 Play Feature Delivery probe: installs the on-demand "diarization" module
// (sherpa-onnx + ONNX Runtime .so files only) and loads its libraries, so Dart can
// then DynamicLibrary.open them by name.
class MainActivity : FlutterActivity() {
    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(newBase)
        SplitCompat.installActivity(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        getExternalFilesDir(null)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ais44/split")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installed" -> result.success(
                        SplitInstallManagerFactory.create(this).installedModules.toList())
                    "install" -> install(result)
                    "load" -> try {
                        SplitCompat.installActivity(this)
                        SplitInstallHelper.loadLibrary(this, "onnxruntime")
                        SplitInstallHelper.loadLibrary(this, "sherpa-onnx-c-api")
                        result.success("loaded")
                    } catch (t: Throwable) {
                        result.error("load", t.toString(), null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun install(result: MethodChannel.Result) {
        val m = SplitInstallManagerFactory.create(this)
        if (m.installedModules.contains("diarization")) { result.success("already"); return }
        var done = false
        m.registerListener { s ->
            if (done) return@registerListener
            when (s.status()) {
                SplitInstallSessionStatus.INSTALLED -> { done = true; result.success("installed") }
                SplitInstallSessionStatus.FAILED -> {
                    done = true; result.error("install", "code ${s.errorCode()}", null)
                }
                else -> {}
            }
        }
        m.startInstall(SplitInstallRequest.newBuilder().addModule("diarization").build())
            .addOnFailureListener { e ->
                if (!done) { done = true; result.error("install", e.toString(), null) }
            }
    }
}
