package com.vecvel.danaview

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val channelName = "danaview/media_intent"
    private var methodChannel: MethodChannel? = null
    private var pendingMedia: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        methodChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialMedia" -> {
                    val media = pendingMedia
                    pendingMedia = null
                    result.success(media)
                }
                else -> result.notImplemented()
            }
        }
        pendingMedia?.let {
            channel.invokeMethod("onOpenMedia", it)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        syncIncomingDocumentsAlias()
        handleIntent(intent)
    }

    // EXTENDED: INT-104/HOM-21A, Windows lane. The document/photo/text share filters live on
    // IncomingDocumentsAlias (AndroidManifest.xml), a 1.2 feature behind DANAVIEW_FILES_HOME. The
    // manifest already declares it enabled or not from the same flag; this only corrects a state
    // persisted by an earlier build with the other flag value (component settings survive updates).
    // Intents delivered through the alias reach this Activity unchanged (only getComponent() names
    // the alias), so the incoming plugin and handleIntent see them as before.
    private fun syncIncomingDocumentsAlias() {
        try {
            val alias = ComponentName(this, "$packageName.IncomingDocumentsAlias")
            val want = BuildConfig.DANAVIEW_FILES_HOME
            val current = when (packageManager.getComponentEnabledSetting(alias)) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT ->
                    packageManager.getActivityInfo(alias, PackageManager.MATCH_DISABLED_COMPONENTS).enabled
                else -> false
            }
            if (current != want) {
                packageManager.setComponentEnabledSetting(
                    alias,
                    if (want) PackageManager.COMPONENT_ENABLED_STATE_ENABLED else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP,
                )
            }
        } catch (_: Exception) {
            // Never block startup over the share filters.
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        if (action == Intent.ACTION_VIEW || action == Intent.ACTION_SEND) {
            val uri: Uri? = intent.data
                ?: (if (intent.clipData != null && intent.clipData!!.itemCount > 0) intent.clipData!!.getItemAt(0).uri else null)
                ?: intent.getParcelableExtra(Intent.EXTRA_STREAM)

            if (uri != null) {
                Thread {
                    val resolved = resolveUri(uri)
                    if (resolved != null) {
                        runOnUiThread {
                            pendingMedia = resolved
                            methodChannel?.invokeMethod("onOpenMedia", resolved)
                        }
                    }
                }.start()
            }
        }
    }

    private fun resolveUri(uri: Uri): String? {
        val scheme = uri.scheme?.lowercase() ?: return null
        if (scheme == "http" || scheme == "https" || scheme == "rtsp" || scheme == "rtmp") {
            return uri.toString()
        }
        if (scheme == "danaview") {
            val queryUrl = uri.getQueryParameter("url")
            if (!queryUrl.isNullOrEmpty()) return queryUrl
            val ssp = uri.schemeSpecificPart
            if (ssp.startsWith("//")) {
                val target = ssp.substring(2)
                if (target.startsWith("http://") || target.startsWith("https://")) return target
            }
            return uri.toString()
        }
        if (scheme == "file") {
            return uri.path
        }
        if (scheme == "content") {
            return copyContentUriToCache(uri)
        }
        return null
    }

    private fun copyContentUriToCache(uri: Uri): String? {
        return try {
            var fileName = "opened_video"
            try {
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (idx != -1) {
                            val name = cursor.getString(idx)
                            if (!name.isNullOrBlank()) {
                                fileName = name
                            }
                        }
                    }
                }
            } catch (_: Exception) {
                uri.lastPathSegment?.let { seg ->
                    val clean = seg.substringAfterLast('/')
                    if (clean.isNotBlank()) fileName = clean
                }
            }

            if (!fileName.contains(".")) {
                val mime = contentResolver.getType(uri)
                val ext = when {
                    mime?.contains("matroska") == true -> ".mkv"
                    mime?.contains("mp4") == true -> ".mp4"
                    mime?.contains("quicktime") == true -> ".mov"
                    mime?.contains("webm") == true -> ".webm"
                    mime?.contains("audio") == true -> ".mp3"
                    mime?.contains("avi") == true -> ".avi"
                    else -> ".mp4"
                }
                fileName += ext
            }

            val safeName = fileName.replace(Regex("[^a-zA-Z0-9._-]"), "_")
            val cacheFolder = File(cacheDir, "open_with").apply { mkdirs() }
            val destFile = File(cacheFolder, safeName)

            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(destFile).use { output ->
                    input.copyTo(output)
                }
            }
            destFile.absolutePath
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }
}
