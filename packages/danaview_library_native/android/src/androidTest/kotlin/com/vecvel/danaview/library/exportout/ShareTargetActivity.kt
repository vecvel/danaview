// OWNER: HOM-22A
//
// A receiver app inside the test APK (declared in src/androidTest/AndroidManifest.xml): it takes
// ACTION_SEND / ACTION_SEND_MULTIPLE of anything and ACTION_VIEW of the test-only type
// application/x-danaview-test, records what it received (URIs, flags, the bytes it could read and
// whether it could open the URI for writing) and finishes. The file-out tests choose it in the
// system chooser or have ACTION_VIEW resolve to it.

package com.vecvel.danaview.library.exportout

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import java.util.concurrent.LinkedBlockingQueue

class ShareTargetActivity : Activity() {
    /** What one launch received. */
    data class Received(val action: String?, val type: String?, val flags: Int, val uris: List<Uri>, val bytes: List<ByteArray>, val writable: List<Boolean>, val subject: String?)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val i = intent
        val uris = ArrayList<Uri>()
        @Suppress("DEPRECATION")
        when (i.action) {
            Intent.ACTION_SEND -> (if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java) else i.getParcelableExtra(Intent.EXTRA_STREAM))?.let(uris::add)
            Intent.ACTION_SEND_MULTIPLE -> (if (Build.VERSION.SDK_INT >= 33) i.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) else i.getParcelableArrayListExtra(Intent.EXTRA_STREAM))?.let(uris::addAll)
            Intent.ACTION_VIEW -> i.data?.let(uris::add)
        }
        val bytes = uris.map { u -> runCatching { contentResolver.openInputStream(u)!!.use { it.readBytes() } }.getOrDefault(ByteArray(0)) }
        val writable = uris.map { u -> runCatching { contentResolver.openOutputStream(u, "w")!!.use { it.write(0) }; true }.getOrDefault(false) }
        received.add(Received(i.action, i.type, i.flags, uris, bytes, writable, i.getStringExtra(Intent.EXTRA_SUBJECT)))
        finish()
    }

    companion object {
        val received = LinkedBlockingQueue<Received>()
        const val VIEW_TYPE = "application/x-danaview-test"
    }
}
