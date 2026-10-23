// OWNER: HOM-20A
//
// Test support of the picker tests (adapted from the editor engine's AND-14 PlatformTestSupport):
// an activity relay (a headless android.app.Fragment in androidx.test's EmptyActivity, since the
// library test APK has no activity of its own) that starts the real pickers for a result, UiAutomator
// helpers for the system Photo Picker and DocumentsUI, and RecordingProvider: a content provider of
// the test APK that serves files from its own directory and records every open mode, so a test can
// prove a source is only ever opened read-only (rule 27).

package com.vecvel.danaview.library.pickers

import android.app.Activity
import android.app.Fragment
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Intent
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import java.io.File
import java.io.FileNotFoundException
import java.util.Collections
import java.util.regex.Pattern

/** A [ResultLauncher] through a fragment in EmptyActivity. */
class FragmentLauncher private constructor(val activity: Activity, private val fragment: RelayFragment) : ResultLauncher {
    override fun start(intent: Intent, done: (Int, Intent?) -> Unit): Boolean {
        if (fragment.pending != null) return false
        fragment.pending = done
        @Suppress("DEPRECATION")
        fragment.startActivityForResult(intent, 0x5a5d)
        return true
    }

    fun finish() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync { activity.finish() }
    }

    @Suppress("DEPRECATION")
    class RelayFragment : Fragment() {
        var pending: ((Int, Intent?) -> Unit)? = null

        @Deprecated("android.app.Fragment API")
        override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
            val cb = pending ?: return
            pending = null
            cb(resultCode, data)
        }
    }

    companion object {
        private const val EMPTY_ACTIVITY = "androidx.test.core.app.InstrumentationActivityInvoker\$EmptyActivity"

        @Suppress("DEPRECATION")
        fun launch(): FragmentLauncher {
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            val intent = Intent(Intent.ACTION_MAIN)
                .setClassName(instrumentation.targetContext.packageName, EMPTY_ACTIVITY)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val activity = instrumentation.startActivitySync(intent)
            val fragment = RelayFragment()
            instrumentation.runOnMainSync {
                activity.fragmentManager.beginTransaction().add(fragment, "danaview-library-relay").commitNow()
            }
            return FragmentLauncher(activity, fragment)
        }
    }
}

/** UiAutomator helpers for the system pickers. */
object SystemUi {
    val device: UiDevice get() = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())

    fun waitAny(timeoutMs: Long, vararg selectors: () -> UiObject2?): UiObject2? {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            for (s in selectors) s()?.let { return it }
            Thread.sleep(250)
        }
        return null
    }

    fun byText(regex: String): () -> UiObject2? = { device.findObject(By.text(Pattern.compile(regex))) }

    fun byDesc(regex: String): () -> UiObject2? = { device.findObject(By.desc(Pattern.compile(regex))) }

    fun byRes(regex: String): () -> UiObject2? = { device.findObject(By.res(Pattern.compile(regex))) }

    fun dump(): String {
        val out = java.io.ByteArrayOutputStream()
        device.dumpWindowHierarchy(out)
        return out.toString("UTF-8").split('<').mapNotNull { node ->
            val t = Regex("text=\"([^\"]+)\"").find(node)?.groupValues?.get(1)
            val r = Regex("resource-id=\"([^\"]+)\"").find(node)?.groupValues?.get(1)
            val d = Regex("content-desc=\"([^\"]+)\"").find(node)?.groupValues?.get(1)
            listOfNotNull(t?.let { "t=$it" }, r?.let { "r=$it" }, d?.let { "d=$it" }).takeIf { it.isNotEmpty() }?.joinToString(" ")
        }.joinToString("\n")
    }

    /** Selects the [count] first (newest) items of the Photo Picker grid and confirms. */
    fun selectInPhotoPicker(count: Int) {
        waitAny(15_000, byRes(".*:id/icon_thumbnail")) ?: error("no picker grid:\n" + dump())
        val all = device.findObjects(By.res(Pattern.compile(".*:id/icon_thumbnail")))
        check(all.size >= count) { "picker shows ${all.size} item(s):\n" + dump() }
        for (i in 0 until count) {
            all[i].click()
            Thread.sleep(400)
        }
        if (count > 1 || waitAny(1_500, byRes(".*:id/button_add")) != null) {
            val add = waitAny(5_000, byRes(".*:id/button_add"), byText("(?i)^add.*")) ?: error("no Add button:\n" + dump())
            add.click()
        }
    }

    /** Opens the Downloads root in DocumentsUI unless [name] is already listed. */
    fun openDownloadsIfNeeded(name: String) {
        if (waitAny(6_000, byText(Pattern.quote(name))) != null) return
        // The picker may still be laying out (a freshly booted device): retry stale nodes.
        repeat(3) { attempt ->
            try {
                val roots = waitAny(5_000, byDesc("(?i)show roots")) ?: error("no roots button:\n" + dump())
                roots.click()
                val downloads = waitAny(5_000, byText("(?i)^downloads?$")) ?: error("no Downloads root:\n" + dump())
                downloads.click()
                return
            } catch (e: androidx.test.uiautomator.StaleObjectException) {
                if (attempt == 2) throw e
                Thread.sleep(1_000)
            }
        }
    }

    /** Multi-selects [names] in DocumentsUI's Downloads (long press, tap, Select). */
    fun selectSeveralInDocumentsUi(names: List<String>) {
        openDownloadsIfNeeded(names[0])
        val first = listed(names[0], 10_000) ?: error("${names[0]} not listed:\n" + dump())
        first.longClick()
        Thread.sleep(600)
        for (name in names.drop(1)) {
            (listed(name, 5_000) ?: error("$name not listed:\n" + dump())).click()
            Thread.sleep(400)
        }
        val select = waitAny(5_000, byRes(".*:id/action_menu_select"), byText("(?i)^select$")) ?: error("no Select action:\n" + dump())
        select.click()
    }

    /**
     * [name] in the current DocumentsUI list, scrolling to it when other Download contents
     * (folders sort first; other apps' files or an earlier run's leftovers) push it below the fold.
     */
    fun listed(name: String, timeoutMs: Long, vararg more: () -> UiObject2?): UiObject2? {
        val selectors = arrayOf(byText(Pattern.quote(name)), *more)
        val found = waitAny(timeoutMs, *selectors) ?: return scrollTo(name, *more)
        return settle(found, selectors)
    }

    /**
     * Scrolls the list to the top, then down until [name] (or one of [more]) shows, and settles it
     * clear of the list's edges; null if it never shows. Slow swipes (not flings) and "nothing
     * changed" as the end, since UiObject2.scroll misreports the end of DocumentsUI's grid.
     */
    fun scrollTo(name: String, vararg more: () -> UiObject2?): UiObject2? {
        val selectors = arrayOf(byText(Pattern.quote(name)), *more)
        val find = { selectors.firstNotNullOfOrNull { s -> runCatching { s() }.getOrNull() } }
        val b = listBounds() ?: return find()
        val x = b.centerX()
        val upper = b.top + b.height() * 3 / 10
        val lower = b.top + b.height() * 8 / 10
        var last = snapshot()
        for (i in 0 until 30) {
            device.swipe(x, upper, x, lower, 40)
            Thread.sleep(500)
            val now = snapshot()
            if (now == last) break
            last = now
        }
        for (i in 0 until 40) {
            find()?.let { return settle(it, selectors) }
            device.swipe(x, lower, x, upper, 40)
            Thread.sleep(500)
            val now = snapshot()
            if (now == last) return find()?.let { settle(it, selectors) }
            last = now
        }
        return null
    }

    /** DocumentsUI's file list (dir_list), else the largest scrollable (its search chips scroll too). */
    private fun listBounds(): android.graphics.Rect? = runCatching {
        (device.findObject(By.res(Pattern.compile(".*:id/dir_list")))
            ?: device.findObjects(By.scrollable(true)).maxByOrNull { it.visibleBounds.width() * it.visibleBounds.height() })?.visibleBounds
    }.getOrNull()

    /** The texts shown in the list: unchanged after a swipe means its end. */
    private fun snapshot(): List<String> {
        val b = listBounds() ?: return emptyList()
        return device.findObjects(By.text(Pattern.compile("(?s).+"))).mapNotNull { o ->
            runCatching { if (b.contains(o.visibleBounds.centerX(), o.visibleBounds.centerY())) o.text + "@" + o.visibleBounds.top else null }.getOrNull()
        }
    }

    /**
     * Brings [found] clear of the list's edges before it is tapped: an item half under the app bar
     * or the navigation bar reports a centre the tap misses.
     */
    private fun settle(found: UiObject2, selectors: Array<() -> UiObject2?>): UiObject2 {
        val b = listBounds() ?: return found
        val y = runCatching { found.visibleBounds.centerY() }.getOrNull() ?: return found
        val safeTop = b.top + b.height() / 4
        val safeBottom = b.bottom - b.height() / 6
        if (y in safeTop..safeBottom) return found
        val mid = (b.top + b.bottom) / 2
        val shift = (y - mid).coerceIn(-(b.height() * 4 / 10), b.height() * 4 / 10)
        device.swipe(b.centerX(), mid, b.centerX(), mid - shift, 40)
        Thread.sleep(600)
        return selectors.firstNotNullOfOrNull { s -> runCatching { s() }.getOrNull() } ?: found
    }
}

/**
 * Serves `content://<test package>.recording/<name>` from `<files>/recording/` and records every
 * open mode; answers `datetaken` / `date_added` from [dates] (the Photo Picker's media-id names). Declared in src/androidTest/AndroidManifest.xml.
 */
class RecordingProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    private fun file(uri: Uri): File = File(dir(context!!), uri.lastPathSegment ?: throw FileNotFoundException("no name"))

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        modes.add(mode)
        val f = file(uri)
        if (!f.isFile) throw FileNotFoundException("missing")
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.parseMode(mode))
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val f = file(uri)
        val cols = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val cursor = MatrixCursor(cols)
        val (taken, addedSeconds) = dates[f.name] ?: (null to null)
        if (f.isFile) {
            cursor.addRow(
                cols.map { c ->
                    when (c) {
                        OpenableColumns.DISPLAY_NAME -> f.name
                        OpenableColumns.SIZE -> f.length()
                        "datetaken" -> taken // ms, as MediaStore / PickerMediaColumns
                        "date_added" -> addedSeconds // s, as MediaStore
                        else -> null
                    }
                },
            )
        }
        return cursor
    }

    override fun getType(uri: Uri): String? = when (uri.lastPathSegment?.substringAfterLast('.')?.lowercase()) {
        "jpg" -> "image/jpeg"
        "pdf" -> "application/pdf"
        "mp4" -> "video/mp4"
        else -> null
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0

    companion object {
        /** Every mode any test opened a recording URI with. */
        val modes: MutableList<String> = Collections.synchronizedList(ArrayList())

        /** Capture dates served for a file name: (DATE_TAKEN in ms, DATE_ADDED in s), each optional. */
        val dates: MutableMap<String, Pair<Long?, Long?>> = java.util.concurrent.ConcurrentHashMap()

        fun dir(context: android.content.Context) = File(context.filesDir, "recording").apply { mkdirs() }

        fun uri(context: android.content.Context, name: String): Uri = Uri.parse("content://${context.packageName}.recording/$name")
    }
}
