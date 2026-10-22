// OWNER: HOM-02A
//
// JVM tests of the access mapping per API level (photolibrary/PhotoPermissions.kt).

package com.vecvel.danaview.library.photolibrary

import com.vecvel.danaview.library.photolibrary.PhotoPermissions.READ_EXTERNAL_STORAGE
import com.vecvel.danaview.library.photolibrary.PhotoPermissions.READ_MEDIA_IMAGES
import com.vecvel.danaview.library.photolibrary.PhotoPermissions.READ_MEDIA_VIDEO
import com.vecvel.danaview.library.photolibrary.PhotoPermissions.READ_MEDIA_VISUAL_USER_SELECTED
import com.vecvel.danaview.library.pigeon.PhotoAuthorizationMsg
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoPermissionsTest {
    private fun status(sdk: Int, vararg granted: String, asked: Boolean = false, deniedOnce: Boolean = false) =
        PhotoPermissions.status(sdk, { it in granted }, asked, deniedOnce)

    @Test
    fun requestsThePermissionsOfEachApiLevel() {
        assertArrayEquals(arrayOf(READ_MEDIA_IMAGES, READ_MEDIA_VIDEO, READ_MEDIA_VISUAL_USER_SELECTED), PhotoPermissions.toRequest(34))
        assertArrayEquals(arrayOf(READ_MEDIA_IMAGES, READ_MEDIA_VIDEO, READ_MEDIA_VISUAL_USER_SELECTED), PhotoPermissions.toRequest(36))
        assertArrayEquals(arrayOf(READ_MEDIA_IMAGES, READ_MEDIA_VIDEO), PhotoPermissions.toRequest(33))
        for (sdk in 24..32) assertArrayEquals(arrayOf(READ_EXTERNAL_STORAGE), PhotoPermissions.toRequest(sdk))
    }

    @Test
    fun api34FullAndPartialAccess() {
        assertEquals(PhotoAuthorizationMsg.AUTHORIZED, status(35, READ_MEDIA_IMAGES, READ_MEDIA_VIDEO, READ_MEDIA_VISUAL_USER_SELECTED))
        assertEquals(PhotoAuthorizationMsg.AUTHORIZED, status(34, READ_MEDIA_IMAGES, READ_MEDIA_VIDEO))
        // "Select photos and videos": only the user-selected permission is granted.
        assertEquals(PhotoAuthorizationMsg.LIMITED, status(34, READ_MEDIA_VISUAL_USER_SELECTED))
        assertEquals(PhotoAuthorizationMsg.LIMITED, status(35, READ_MEDIA_VISUAL_USER_SELECTED, asked = true))
        // Images only (a partial grant from another app's request pattern) still lists something.
        assertEquals(PhotoAuthorizationMsg.LIMITED, status(34, READ_MEDIA_IMAGES))
    }

    @Test
    fun api33HasNoPartialAccess() {
        assertEquals(PhotoAuthorizationMsg.AUTHORIZED, status(33, READ_MEDIA_IMAGES, READ_MEDIA_VIDEO))
        assertEquals(PhotoAuthorizationMsg.AUTHORIZED, status(33, READ_MEDIA_IMAGES))
        assertEquals(PhotoAuthorizationMsg.NOT_DETERMINED, status(33, READ_MEDIA_VISUAL_USER_SELECTED))
    }

    @Test
    fun legacyStorageUpToApi32() {
        for (sdk in listOf(24, 28, 29, 30, 32)) {
            assertEquals(PhotoAuthorizationMsg.AUTHORIZED, status(sdk, READ_EXTERNAL_STORAGE))
            assertEquals(PhotoAuthorizationMsg.NOT_DETERMINED, status(sdk, READ_MEDIA_IMAGES, READ_MEDIA_VIDEO))
        }
    }

    @Test
    fun neverAskedIsNotDeterminedAndRefusedIsDenied() {
        for (sdk in listOf(24, 29, 33, 34, 35)) {
            assertEquals(PhotoAuthorizationMsg.NOT_DETERMINED, status(sdk))
            assertEquals(PhotoAuthorizationMsg.DENIED, status(sdk, asked = true))
            assertEquals(PhotoAuthorizationMsg.DENIED, status(sdk, deniedOnce = true))
        }
    }

    @Test
    fun nothingIsRestrictedOnAndroid() {
        for (sdk in 24..36) {
            for (asked in listOf(false, true)) {
                assertFalse(status(sdk, asked = asked) == PhotoAuthorizationMsg.RESTRICTED)
            }
        }
    }

    @Test
    fun canReadOnlyWithFullOrPartialAccess() {
        assertTrue(PhotoPermissions.canRead(PhotoAuthorizationMsg.AUTHORIZED))
        assertTrue(PhotoPermissions.canRead(PhotoAuthorizationMsg.LIMITED))
        assertFalse(PhotoPermissions.canRead(PhotoAuthorizationMsg.DENIED))
        assertFalse(PhotoPermissions.canRead(PhotoAuthorizationMsg.NOT_DETERMINED))
        assertFalse(PhotoPermissions.canRead(PhotoAuthorizationMsg.RESTRICTED))
    }
}
