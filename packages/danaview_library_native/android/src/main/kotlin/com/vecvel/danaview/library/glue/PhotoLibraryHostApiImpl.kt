// OWNER: HOM-02A
//
// PhotoLibraryHostApi on Android: runs the Flutter-free MediaStorePhotoLibrary (photolibrary/) on
// one serial background executor (copies on their own two threads so a long copy never blocks
// paging), replies on the main thread, forwards the library's events to the event stream, asks
// for the runtime permissions through the Activity and re-reads the access on every resume (the
// user may have changed it in the system settings).

package com.vecvel.danaview.library.glue

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import com.vecvel.danaview.library.photolibrary.MediaStorePhotoLibrary
import com.vecvel.danaview.library.photolibrary.PhotoLibraryEvents
import com.vecvel.danaview.library.photolibrary.PhotoPermissions
import com.vecvel.danaview.library.pigeon.CopyProgressMsg
import com.vecvel.danaview.library.pigeon.LibraryEventKindMsg
import com.vecvel.danaview.library.pigeon.LibraryEventMsg
import com.vecvel.danaview.library.pigeon.PhotoAlbumMsg
import com.vecvel.danaview.library.pigeon.PhotoAssetDetailMsg
import com.vecvel.danaview.library.pigeon.PhotoAssetMsg
import com.vecvel.danaview.library.pigeon.PhotoAuthorizationMsg
import com.vecvel.danaview.library.pigeon.PhotoCopyRequestMsg
import com.vecvel.danaview.library.pigeon.PhotoCopyResultMsg
import com.vecvel.danaview.library.pigeon.PhotoFetchRequestMsg
import com.vecvel.danaview.library.pigeon.PhotoLibraryChangeMsg
import com.vecvel.danaview.library.pigeon.PhotoLibraryHostApi
import com.vecvel.danaview.library.pigeon.PhotoPageMsg
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

class PhotoLibraryHostApiImpl(private val context: LibraryPluginContext) : PhotoLibraryHostApi, PhotoLibraryEvents {
    val service = MediaStorePhotoLibrary(context.appContext, this)
    private val queue: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, "danaview-library-photos") }
    private val copies: ExecutorService = Executors.newFixedThreadPool(2) { r -> Thread(r, "danaview-library-copy") }
    private var lifecycle: Pair<Application, Application.ActivityLifecycleCallbacks>? = null

    init {
        context.addActivityListener(::onActivityChanged)
    }

    /** Runs [work] on [executor] and answers [callback] on the main thread. */
    private fun <T> run(executor: ExecutorService, what: String, callback: (Result<T>) -> Unit, work: () -> T) {
        try {
            executor.execute {
                val result = try {
                    Result.success(work())
                } catch (t: Throwable) {
                    Result.failure(LibraryErrors.wrap(t, what))
                }
                context.main.post { callback(result) }
            }
        } catch (e: RejectedExecutionException) {
            callback(Result.failure(LibraryErrors.error(LibraryErrorCode.internal, "$what: plugin detached")))
        }
    }

    // ---------------------------------------------------------------------------------------------
    // PhotoLibraryHostApi

    override fun authorizationStatus(): PhotoAuthorizationMsg = service.authorizationStatus(deniedOnce())

    override fun requestAuthorization(callback: (Result<PhotoAuthorizationMsg>) -> Unit) {
        val current = authorizationStatus()
        // Prompts the first time only (V2-103); later calls return the state, as on Apple.
        if (current != PhotoAuthorizationMsg.NOT_DETERMINED) return callback(Result.success(current))
        request(callback) { status -> status }
    }

    override fun presentLimitedLibraryPicker(callback: (Result<List<String>>) -> Unit) {
        if (Build.VERSION.SDK_INT < 34) return callback(Result.failure(LibraryErrors.notSupported("partial access needs Android 14+")))
        if (authorizationStatus() != PhotoAuthorizationMsg.LIMITED) {
            return callback(Result.failure(LibraryErrors.error(LibraryErrorCode.invalidArgument, "access is not limited")))
        }
        // Android 14+ shows the selection again when the permissions are requested again.
        request({ result ->
            result.fold(
                onSuccess = { status ->
                    if (!PhotoPermissions.canRead(status)) callback(Result.success(emptyList()))
                    else run(queue, "selection", callback) { service.visibleIds() }
                },
                onFailure = { callback(Result.failure(it)) },
            )
        }) { status -> status }
    }

    /** Requests the photo permissions and answers with the access afterwards. */
    private fun <T> request(callback: (Result<T>) -> Unit, map: (PhotoAuthorizationMsg) -> T) {
        val permissions = PhotoPermissions.toRequest(Build.VERSION.SDK_INT)
        if (context.activity == null) {
            return callback(Result.failure(LibraryErrors.error(LibraryErrorCode.internal, "no activity to ask from")))
        }
        val started = context.requestPermissions(LibraryPluginContext.REQUEST_PHOTO_PERMISSIONS, permissions) { answers ->
            if (answers.isNotEmpty()) service.markAsked()
            val status = authorizationStatus()
            run(queue, "authorization", callback) {
                service.noteAuthorization(status)
                map(status)
            }
        }
        if (!started) callback(Result.failure(LibraryErrors.error(LibraryErrorCode.busy, "a permission request is running")))
    }

    override fun openAppSettings(): Boolean {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.appContext.packageName, null))
        return try {
            val activity = context.activity
            if (activity != null) {
                activity.startActivity(intent)
            } else {
                context.appContext.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            true
        } catch (e: RuntimeException) {
            false
        }
    }

    override fun startObserving() {
        try {
            queue.execute { service.startObserving() }
        } catch (e: RejectedExecutionException) {
            // detached
        }
    }

    override fun stopObserving() {
        try {
            queue.execute { service.stopObserving() }
        } catch (e: RejectedExecutionException) {
            // detached
        }
    }

    override fun fetchPage(request: PhotoFetchRequestMsg, callback: (Result<PhotoPageMsg>) -> Unit) =
        run(queue, "page", callback) { service.fetchPage(request) }

    override fun fetchAssets(localIdentifiers: List<String>, callback: (Result<List<PhotoAssetMsg>>) -> Unit) =
        run(queue, "assets", callback) { service.fetchAssets(localIdentifiers) }

    override fun fetchAlbums(callback: (Result<List<PhotoAlbumMsg>>) -> Unit) =
        run(queue, "albums", callback) { service.fetchAlbums() }

    override fun assetDetail(localIdentifier: String, callback: (Result<PhotoAssetDetailMsg>) -> Unit) =
        run(queue, "detail", callback) { service.assetDetail(localIdentifier) }

    override fun copyAsset(request: PhotoCopyRequestMsg, callback: (Result<PhotoCopyResultMsg>) -> Unit) =
        run(copies, "copy", callback) { service.copyAsset(request) }

    override fun cancelCopy(requestId: String) = service.cancelCopy(requestId)

    // ---------------------------------------------------------------------------------------------
    // PhotoLibraryEvents (any thread)

    override fun libraryChanged(change: PhotoLibraryChangeMsg) =
        context.events.emit(LibraryEventMsg(LibraryEventKindMsg.PHOTO_LIBRARY_CHANGED, photoChange = change))

    override fun authorizationChanged(status: PhotoAuthorizationMsg) =
        context.events.emit(LibraryEventMsg(LibraryEventKindMsg.PHOTO_AUTHORIZATION_CHANGED, authorization = status))

    override fun copyProgress(requestId: String, bytesDone: Long, bytesTotal: Long?) =
        context.events.emit(LibraryEventMsg(LibraryEventKindMsg.COPY_PROGRESS, copyProgress = CopyProgressMsg(requestId, bytesDone, bytesTotal)))

    // ---------------------------------------------------------------------------------------------
    // Activity

    /** True after the user refused once (the Activity's rationale flag). Main thread. */
    private fun deniedOnce(): Boolean {
        val activity = context.activity ?: return false
        return PhotoPermissions.toRequest(Build.VERSION.SDK_INT).any { activity.shouldShowRequestPermissionRationale(it) }
    }

    /** Re-reads the access whenever the app's Activity resumes (back from the system settings). */
    private fun onActivityChanged(activity: Activity?) {
        lifecycle?.let { (app, cb) -> app.unregisterActivityLifecycleCallbacks(cb) }
        lifecycle = null
        if (activity == null) return
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(a: Activity) {
                if (a !== context.activity) return
                val status = authorizationStatus()
                try {
                    queue.execute { service.noteAuthorization(status) }
                } catch (e: RejectedExecutionException) {
                    // detached
                }
            }

            override fun onActivityCreated(a: Activity, savedInstanceState: Bundle?) {}

            override fun onActivityStarted(a: Activity) {}

            override fun onActivityPaused(a: Activity) {}

            override fun onActivityStopped(a: Activity) {}

            override fun onActivitySaveInstanceState(a: Activity, outState: Bundle) {}

            override fun onActivityDestroyed(a: Activity) {}
        }
        activity.application.registerActivityLifecycleCallbacks(callbacks)
        lifecycle = activity.application to callbacks
    }

    /** Stops observing and the executors (engine detached). */
    fun dispose() {
        onActivityChanged(null)
        service.stopObserving()
        queue.shutdown()
        copies.shutdownNow()
    }
}
