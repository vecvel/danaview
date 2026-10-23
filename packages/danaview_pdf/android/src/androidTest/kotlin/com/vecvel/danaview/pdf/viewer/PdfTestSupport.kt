// OWNER: HOM-25
//
// Support for the HOM-25 instrumented tests:
// - [Fixtures]: the HOM-27 fixtures (spikes/android_pdf/fixtures/, test assets) copied into the test
//   app's cache, plus files generated for this ticket with PdfBox in the test only: a
//   password-protected copy (AES-128, user + owner password), an owner-password-only copy that
//   forbids copying and printing, a copy with an outline, and damaged files (random bytes,
//   truncated, empty, header only, a PNG renamed .pdf).
// - [FakeTextureRegistry] / [FakeSurfaceProducer]: Flutter's SurfaceProducer contract over an RGBA
//   ImageReader, so the tests read back every frame the texture view draws (the AND-10 pattern of
//   danaview_editor_engine), and can drive the resetInBackground lifecycle.
// - Small helpers: main-thread calls, latches over Pigeon callbacks, pixel probes.

package com.vecvel.danaview.pdf.viewer

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import androidx.test.platform.app.InstrumentationRegistry
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.encryption.AccessPermission
import com.tom_roush.pdfbox.pdmodel.encryption.StandardProtectionPolicy
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.destination.PDPageFitDestination
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.outline.PDDocumentOutline
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.outline.PDOutlineItem
import com.vecvel.danaview.pdf.pigeon.PdfPigeonError
import com.vecvel.danaview.pdf.text.PdfBoxSupport
import io.flutter.view.TextureRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import java.io.File
import java.util.Random
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

const val HOM25_TAG = "HOM25"

object Fixtures {
    const val TEXT_200 = "text_200p.pdf"
    const val MERGE_3 = "merge_partner_3p.pdf"
    const val ANNOTATED_2 = "annotated_2p.pdf"
    const val IMAGES_2 = "image_only_2p.pdf"

    const val USER_PASSWORD = "hom25-user"
    const val OWNER_PASSWORD = "hom25-owner"

    val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

    private val dir: File by lazy {
        File(context.cacheDir, "hom25").apply {
            deleteRecursively()
            mkdirs()
        }
    }

    init {
        PdfBoxSupport.init(InstrumentationRegistry.getInstrumentation().targetContext)
    }

    /** A HOM-27 fixture as a file. */
    fun file(name: String): File {
        val out = File(dir, name)
        if (!out.exists()) {
            InstrumentationRegistry.getInstrumentation().context.assets.open(name).use { input ->
                out.outputStream().use { input.copyTo(it) }
            }
        }
        return out
    }

    fun path(name: String): String = file(name).absolutePath

    /** merge_partner_3p.pdf encrypted with [USER_PASSWORD] (open) and [OWNER_PASSWORD]. */
    val encrypted: File by lazy {
        generated("encrypted_user.pdf") { doc ->
            doc.protect(StandardProtectionPolicy(OWNER_PASSWORD, USER_PASSWORD, AccessPermission()).apply { encryptionKeyLength = 128 })
        }
    }

    /** merge_partner_3p.pdf with only an owner password: opens without one, forbids copying and printing. */
    val restricted: File by lazy {
        generated("encrypted_owner_only.pdf") { doc ->
            val perms = AccessPermission().apply {
                setCanExtractContent(false)
                setCanPrint(false)
            }
            doc.protect(StandardProtectionPolicy(OWNER_PASSWORD, "", perms).apply { encryptionKeyLength = 128 })
        }
    }

    /** text_200p.pdf with a two-level outline: Chapter 1 (p1) > Section 1.1 (p5), Chapter 2 (p100), No target. */
    val withOutline: File by lazy {
        generated("outline_200p.pdf", source = TEXT_200) { doc ->
            val outline = PDDocumentOutline()
            doc.documentCatalog.documentOutline = outline
            fun item(title: String, page: Int?): PDOutlineItem = PDOutlineItem().apply {
                this.title = title
                if (page != null) destination = PDPageFitDestination().apply { setPage(doc.getPage(page)) }
            }
            val ch1 = item("Chapter 1", 0)
            ch1.addLast(item("Section 1.1", 4))
            outline.addLast(ch1)
            outline.addLast(item("Chapter 2", 99))
            outline.addLast(item("No target", null))
        }
    }

    private fun generated(name: String, source: String = MERGE_3, edit: (PDDocument) -> Unit): File {
        val out = File(dir, name)
        PDDocument.load(file(source)).use { doc ->
            edit(doc)
            doc.save(out)
        }
        return out
    }

    /** Damaged files by kind. */
    fun damaged(kind: String): File {
        val out = File(dir, "damaged_$kind.pdf")
        when (kind) {
            "random" -> out.writeBytes(ByteArray(64 * 1024).also { Random(25).nextBytes(it) })
            "truncated" -> file(TEXT_200).readBytes().let { out.writeBytes(it.copyOf(it.size * 2 / 5)) }
            "empty" -> out.writeBytes(ByteArray(0))
            "header" -> out.writeText("%PDF-1.7\n%âã\n1 0 obj\n<< /Type /Catalog")
            "png" -> out.writeBytes(byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) + ByteArray(2048))
            else -> error(kind)
        }
        return out
    }

    val damagedKinds = listOf("random", "truncated", "empty", "header", "png")

    /** A path that doesn't exist. */
    val missing: String get() = File(dir, "missing.pdf").absolutePath
}

/** Runs [block] on the main thread and returns its result (or rethrows). */
fun <T> onMain(block: () -> T): T {
    val result = AtomicReference<Result<T>>()
    InstrumentationRegistry.getInstrumentation().runOnMainSync { result.set(runCatching(block)) }
    return result.get().getOrThrow()
}

/** Calls a Pigeon async method on the main thread and waits for its callback. */
fun <T> awaitCall(timeoutMs: Long = 30_000, call: ((Result<T>) -> Unit) -> Unit): Result<T> {
    val latch = CountDownLatch(1)
    val result = AtomicReference<Result<T>>()
    InstrumentationRegistry.getInstrumentation().runOnMainSync {
        call { r ->
            result.set(r)
            latch.countDown()
        }
    }
    if (!latch.await(timeoutMs, TimeUnit.MILLISECONDS)) fail("no reply in $timeoutMs ms")
    return result.get()
}

/** The Pigeon error code of a failed [r]. */
fun <T> codeOf(r: Result<T>): String {
    val e = r.exceptionOrNull() ?: fail("expected a failure, got ${r.getOrNull()}").let { "" }
    return (e as? PdfPigeonError)?.code ?: "not a PdfPigeonError: $e"
}

fun assertCode(expected: String, r: Result<*>) = assertEquals(expected, codeOf(r))

/** One frame the fake producer received: RGBA top-down. */
class Frame(val index: Int, val width: Int, val height: Int, val rgba: ByteArray) {
    fun pixel(x: Int, y: Int): Int {
        val i = (y * width + x) * 4
        return Color.argb(rgba[i + 3].toInt() and 0xFF, rgba[i].toInt() and 0xFF, rgba[i + 1].toInt() and 0xFF, rgba[i + 2].toInt() and 0xFF)
    }

    /** Pixels in [x0, x1) × [y0, y1) for which [test] holds. */
    fun count(x0: Int, y0: Int, x1: Int, y1: Int, test: (Int) -> Boolean): Int {
        var n = 0
        for (y in maxOf(0, y0) until minOf(height, y1)) for (x in maxOf(0, x0) until minOf(width, x1)) if (test(pixel(x, y))) n++
        return n
    }
}

fun isDark(c: Int) = Color.red(c) < 110 && Color.green(c) < 110 && Color.blue(c) < 110
fun isWhite(c: Int) = Color.red(c) > 245 && Color.green(c) > 245 && Color.blue(c) > 245
fun isBackground(c: Int) = Math.abs(Color.red(c) - 0xE3) <= 3 && Math.abs(Color.green(c) - 0xE3) <= 3 && Math.abs(Color.blue(c) - 0xE6) <= 3
fun isHighlight(c: Int) = Color.red(c) > 200 && Color.green(c) > 170 && Color.blue(c) < 170

/** Flutter's SurfaceProducer over an ImageReader (file header). */
class FakeSurfaceProducer(private val id: Long) : TextureRegistry.SurfaceProducer {
    private val thread = HandlerThread("fake-producer-$id").apply { start() }
    private val handler = Handler(thread.looper)
    private var w = 1
    private var h = 1
    private var reader: ImageReader? = null
    @Volatile private var callback: TextureRegistry.SurfaceProducer.Callback? = null
    private val count = AtomicInteger()
    val frames: MutableList<Frame> = CopyOnWriteArrayList()

    @Volatile var released = false
        private set

    override fun id(): Long = id

    override fun release() {
        released = true
        val r = synchronized(this) { reader.also { reader = null } }
        handler.post {
            r?.close()
            thread.quitSafely()
        }
    }

    override fun setSize(width: Int, height: Int) {
        w = width
        h = height
    }

    override fun getWidth(): Int = w

    override fun getHeight(): Int = h

    @Synchronized
    override fun getSurface(): Surface {
        val r = reader
        if (r != null && r.width == w && r.height == h) return r.surface
        val old = r
        val next = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 3)
        next.setOnImageAvailableListener({ ir -> read(ir) }, handler)
        reader = next
        if (old != null) handler.post { old.close() }
        return next.surface
    }

    override fun getForcedNewSurface(): Surface = synchronized(this) {
        reader = null
        surface
    }

    override fun setCallback(callback: TextureRegistry.SurfaceProducer.Callback?) {
        this.callback = callback
    }

    override fun scheduleFrame() = Unit

    override fun handlesCropAndRotation(): Boolean = false

    private fun read(ir: ImageReader) {
        val image = try {
            ir.acquireLatestImage()
        } catch (_: IllegalStateException) {
            null
        } ?: return
        try {
            val plane = image.planes[0]
            val buf = plane.buffer
            val out = ByteArray(image.width * image.height * 4)
            for (y in 0 until image.height) {
                buf.position(y * plane.rowStride)
                buf.get(out, y * image.width * 4, image.width * 4)
            }
            frames += Frame(count.incrementAndGet(), image.width, image.height, out)
            while (frames.size > 8) frames.removeAt(0)
        } catch (_: IllegalStateException) {
        } finally {
            image.close()
        }
    }

    /** Frames received so far. */
    val frameCount: Int get() = count.get()

    /** Flutter's trim path: onSurfaceCleanup on the main thread, then the reader is closed. */
    fun simulateCleanup() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            callback?.onSurfaceCleanup()
            val closing = synchronized(this) { reader.also { reader = null } }
            handler.post { closing?.close() }
        }
    }

    /** Flutter's resume path: a new reader, then onSurfaceAvailable on the main thread. */
    fun simulateAvailable() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            surface
            callback?.onSurfaceAvailable()
        }
    }

    /** The last frame once no new frame arrived for [quietMs] (the frame a finished render pass left). */
    fun settledFrame(quietMs: Long = 250, timeoutMs: Long = 20_000): Frame {
        val deadline = System.currentTimeMillis() + timeoutMs
        var seen = -1
        var since = System.currentTimeMillis()
        while (System.currentTimeMillis() < deadline) {
            val n = count.get()
            if (n != seen) {
                seen = n
                since = System.currentTimeMillis()
            } else if (n > 0 && System.currentTimeMillis() - since >= quietMs) {
                return frames.last()
            }
            Thread.sleep(10)
        }
        error("frames never settled")
    }

    /** Waits until a frame newer than #[after] of [width] × [height] arrived; returns it. */
    fun awaitFrame(after: Int, width: Int = -1, height: Int = -1, timeoutMs: Long = 20_000): Frame {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            frames.lastOrNull()?.let { if (it.index > after && (width < 0 || it.width == width) && (height < 0 || it.height == height)) return it }
            Thread.sleep(5)
        }
        error("no frame after #$after in $timeoutMs ms")
    }
}

/** A TextureRegistry that only makes [FakeSurfaceProducer]s. */
class FakeTextureRegistry : TextureRegistry {
    private val ids = AtomicLong(500)
    val producers: MutableList<FakeSurfaceProducer> = CopyOnWriteArrayList()

    override fun createSurfaceProducer(lifecycle: TextureRegistry.SurfaceLifecycle): TextureRegistry.SurfaceProducer =
        FakeSurfaceProducer(ids.incrementAndGet()).also { producers += it }

    override fun createSurfaceTexture(): TextureRegistry.SurfaceTextureEntry = throw UnsupportedOperationException()

    override fun registerSurfaceTexture(surfaceTexture: android.graphics.SurfaceTexture): TextureRegistry.SurfaceTextureEntry =
        throw UnsupportedOperationException()

    override fun createImageTexture(): TextureRegistry.ImageTextureEntry = throw UnsupportedOperationException()
}

/** Waits until [view] drew a complete frame after [after] complete frames; returns the count. */
fun awaitComplete(view: PdfTextureView, after: Int, timeoutMs: Long = 20_000): Int {
    val deadline = System.currentTimeMillis() + timeoutMs
    while (System.currentTimeMillis() < deadline) {
        val n = view.completeFrameCount
        if (n > after) return n
        Thread.sleep(2)
    }
    error("no complete frame in $timeoutMs ms")
}
