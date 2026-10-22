// OWNER: HOM-02A
//
// Photo library access on Android (ARCH v1.2 §8, V2-103), pure and unit-tested per API level:
// - API 34+: READ_MEDIA_IMAGES + READ_MEDIA_VIDEO → authorized; only
//   READ_MEDIA_VISUAL_USER_SELECTED ("Select photos and videos") → limited;
// - API 33: READ_MEDIA_IMAGES or READ_MEDIA_VIDEO → authorized (no partial access there);
// - API ≤ 32: READ_EXTERNAL_STORAGE (declared with maxSdkVersion 32 by the app, D-3) → authorized.
// Android has no "never asked" state, so the plugin remembers that it asked once: not granted and
// never asked → notDetermined, not granted after asking → denied. Nothing maps to restricted.
// No ACCESS_MEDIA_LOCATION (owner, 2026-10-22): EXIF GPS stays unread.

package com.vecvel.danaview.library.photolibrary

import com.vecvel.danaview.library.pigeon.PhotoAuthorizationMsg

object PhotoPermissions {
    // String literals, not Manifest constants: they are newer than minSdk 24 (lint InlinedApi).
    const val READ_MEDIA_IMAGES = "android.permission.READ_MEDIA_IMAGES"
    const val READ_MEDIA_VIDEO = "android.permission.READ_MEDIA_VIDEO"
    const val READ_MEDIA_VISUAL_USER_SELECTED = "android.permission.READ_MEDIA_VISUAL_USER_SELECTED"
    const val READ_EXTERNAL_STORAGE = "android.permission.READ_EXTERNAL_STORAGE"

    /** The permissions the Photos tab asks for on API [sdk] (all in one system dialog). */
    fun toRequest(sdk: Int): Array<String> = when {
        sdk >= 34 -> arrayOf(READ_MEDIA_IMAGES, READ_MEDIA_VIDEO, READ_MEDIA_VISUAL_USER_SELECTED)
        sdk >= 33 -> arrayOf(READ_MEDIA_IMAGES, READ_MEDIA_VIDEO)
        else -> arrayOf(READ_EXTERNAL_STORAGE)
    }

    /**
     * The access on API [sdk] given which permissions are [granted] and whether the plugin
     * [askedBefore]. [deniedOnce] is the Activity's `shouldShowRequestPermissionRationale` for one
     * of them (true only after a refusal), which catches a refusal from before the plugin kept its
     * flag (app data cleared).
     */
    fun status(sdk: Int, granted: (String) -> Boolean, askedBefore: Boolean, deniedOnce: Boolean = false): PhotoAuthorizationMsg {
        val full = when {
            sdk >= 34 -> granted(READ_MEDIA_IMAGES) && granted(READ_MEDIA_VIDEO)
            sdk >= 33 -> granted(READ_MEDIA_IMAGES) || granted(READ_MEDIA_VIDEO)
            else -> granted(READ_EXTERNAL_STORAGE)
        }
        if (full) return PhotoAuthorizationMsg.AUTHORIZED
        if (sdk >= 34 && (granted(READ_MEDIA_VISUAL_USER_SELECTED) || granted(READ_MEDIA_IMAGES) || granted(READ_MEDIA_VIDEO))) {
            return PhotoAuthorizationMsg.LIMITED
        }
        return if (askedBefore || deniedOnce) PhotoAuthorizationMsg.DENIED else PhotoAuthorizationMsg.NOT_DETERMINED
    }

    /** True when [status] lets the app list assets. */
    fun canRead(status: PhotoAuthorizationMsg): Boolean =
        status == PhotoAuthorizationMsg.AUTHORIZED || status == PhotoAuthorizationMsg.LIMITED
}
