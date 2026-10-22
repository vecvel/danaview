// OWNER: HOM-02A
//
// The Android glue of danaview_library_native (ARCH v1.2 V2-25, §8): registers every host API of
// the frozen Pigeon surface (pigeons/library_api.dart) and the library event stream, routing each
// API to one class in its own package:
//
//   PhotoLibraryHostApi → glue/PhotoLibraryHostApiImpl over photolibrary/ (HOM-02A)
//   PickerHostApi       → pickers/PickerHostApiImpl         (HOM-20A)
//   ThumbnailHostApi    → thumbnails/ThumbnailHostApiImpl   (HOM-04A)
//   ExportOutHostApi    → exportout/ExportOutHostApiImpl    (HOM-22A)
//   ShareHostApi        → share/ShareHostApiImpl            (HOM-22A)
//   OpenInHostApi       → openin/OpenInHostApiImpl          (HOM-22A)
//   IncomingHostApi     → incoming/IncomingHostApiImpl      (HOM-21A)
//   QuickLookHostApi, InboxHostApi, BackupFlagHostApi → glue/AppleOnlyHostApis (Apple only:
//                         notSupportedOnDevice permanently; Android's backup rules are XML, D-3)
//
// Classes of later tickets start as placeholders answering `notSupportedOnDevice`. The plugin is
// ActivityAware: permission requests and (later) pickers and save-as dialogs need the Activity.

package com.vecvel.danaview.library.glue

import com.vecvel.danaview.library.exportout.ExportOutHostApiImpl
import com.vecvel.danaview.library.incoming.IncomingHostApiImpl
import com.vecvel.danaview.library.openin.OpenInHostApiImpl
import com.vecvel.danaview.library.pickers.PickerHostApiImpl
import com.vecvel.danaview.library.pigeon.BackupFlagHostApi
import com.vecvel.danaview.library.pigeon.ExportOutHostApi
import com.vecvel.danaview.library.pigeon.InboxHostApi
import com.vecvel.danaview.library.pigeon.IncomingHostApi
import com.vecvel.danaview.library.pigeon.LibraryEventsStreamHandler
import com.vecvel.danaview.library.pigeon.OpenInHostApi
import com.vecvel.danaview.library.pigeon.PhotoLibraryHostApi
import com.vecvel.danaview.library.pigeon.PickerHostApi
import com.vecvel.danaview.library.pigeon.QuickLookHostApi
import com.vecvel.danaview.library.pigeon.ShareHostApi
import com.vecvel.danaview.library.pigeon.ThumbnailHostApi
import com.vecvel.danaview.library.share.ShareHostApiImpl
import com.vecvel.danaview.library.thumbnails.ThumbnailHostApiImpl
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger

/** The danaview_library_native plugin entry point. */
class DanaviewLibraryNativePlugin : FlutterPlugin, ActivityAware {
    private var context: LibraryPluginContext? = null
    private var photoLibrary: PhotoLibraryHostApiImpl? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx = LibraryPluginContext(binding.applicationContext, binding.binaryMessenger, LibraryEventHub())
        val photos = PhotoLibraryHostApiImpl(ctx)
        context = ctx
        photoLibrary = photos
        setUpChannels(ctx.messenger, ctx, photos)
        LibraryEventsStreamHandler.register(ctx.messenger, ctx.events)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        photoLibrary?.dispose()
        setUpChannels(binding.binaryMessenger, null, null)
        context = null
        photoLibrary = null
    }

    /** Sets up every host API on [messenger]; null [ctx] tears them down. */
    private fun setUpChannels(messenger: BinaryMessenger, ctx: LibraryPluginContext?, photos: PhotoLibraryHostApiImpl?) {
        PhotoLibraryHostApi.setUp(messenger, photos)
        PickerHostApi.setUp(messenger, ctx?.let { PickerHostApiImpl(it) })
        ThumbnailHostApi.setUp(messenger, ctx?.let { ThumbnailHostApiImpl(it) })
        ExportOutHostApi.setUp(messenger, ctx?.let { ExportOutHostApiImpl(it) })
        ShareHostApi.setUp(messenger, ctx?.let { ShareHostApiImpl(it) })
        OpenInHostApi.setUp(messenger, ctx?.let { OpenInHostApiImpl(it) })
        IncomingHostApi.setUp(messenger, ctx?.let { IncomingHostApiImpl(it) })
        QuickLookHostApi.setUp(messenger, ctx?.let { QuickLookHostApiImpl() })
        InboxHostApi.setUp(messenger, ctx?.let { InboxHostApiImpl() })
        BackupFlagHostApi.setUp(messenger, ctx?.let { BackupFlagHostApiImpl() })
    }

    // ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        context?.attach(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        context?.detach()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        context?.attach(binding)
    }

    override fun onDetachedFromActivity() {
        context?.detach()
    }
}
