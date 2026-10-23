// OWNER: HOM-25
//
// PdfViewHostApi on Android: texture views (viewer/PdfTextureView.kt) instead of Apple's platform
// views. Dart owns scrolling and zoom (lib/src/pdf_view.dart `_TextureController`), so goToPage,
// setScale, zoomToFit and setDisplayMode only move the native viewport for native callers;
// display modes other than continuous are accepted and laid out as continuous (the Dart texture
// layout is one column). Search runs on the text thread over the document's text source (platform
// text from API 35, PdfBox before; a newer search or cancelSearch cancels the older one between pages); showSearchHit highlights the hit in
// the texture (Dart scrolls to its page). Below API 35 a document's first complete frame starts the
// background pre-warm of its page text (text/PdfTextPrewarm.kt), so a first search finds it ready. Selection is not offered on Android: selectedText is
// null, copySelection false. Page thumbnails render on the documents pool. Unknown view ids answer
// notFound. Nothing is logged (rule 30).

package com.vecvel.danaview.pdf.viewer

import android.os.Build
import com.vecvel.danaview.pdf.glue.PdfErrorCode
import com.vecvel.danaview.pdf.glue.PdfErrors
import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.glue.PdfThreads
import com.vecvel.danaview.pdf.pigeon.PdfDisplayModeMsg
import com.vecvel.danaview.pdf.pigeon.PdfImageMsg
import com.vecvel.danaview.pdf.pigeon.PdfRectMsg
import com.vecvel.danaview.pdf.pigeon.PdfSearchHitMsg
import com.vecvel.danaview.pdf.pigeon.PdfSearchOptionsMsg
import com.vecvel.danaview.pdf.pigeon.PdfSearchResultMsg
import com.vecvel.danaview.pdf.pigeon.PdfTextureViewMsg
import com.vecvel.danaview.pdf.pigeon.PdfTextureViewRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfThumbnailRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfViewHostApi
import com.vecvel.danaview.pdf.pigeon.PdfViewStateMsg
import com.vecvel.danaview.pdf.pigeon.PdfViewportMsg
import com.vecvel.danaview.pdf.text.OpenPdfPrewarmTarget
import com.vecvel.danaview.pdf.text.PdfCancelToken
import com.vecvel.danaview.pdf.text.PdfSearch
import com.vecvel.danaview.pdf.text.TextPrewarmPolicy
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicLong

class PdfViewHostApiImpl(
    private val store: PdfDocumentStore,
    private val textures: TextureRegistry,
    private val threads: PdfThreads,
) : PdfViewHostApi {
    // Main thread only.
    private val views = HashMap<Long, PdfTextureView>()
    private val searches = HashMap<Long, PdfCancelToken>()
    private val nextViewId = AtomicLong(1)

    /** Live texture views (tests). */
    val viewCount: Int get() = views.size

    /** The view [viewId] (tests). */
    fun view(viewId: Long): PdfTextureView = views[viewId] ?: throw PdfErrors.error(PdfErrorCode.notFound, "no such view")

    override fun state(viewId: Long): PdfViewStateMsg = stateOf(view(viewId))

    override fun goToPage(viewId: Long, pageIndex: Long) {
        val v = view(viewId)
        if (pageIndex < 0 || pageIndex >= v.layout.pageCount) throw PdfErrors.error(PdfErrorCode.invalidArgument, "page out of range")
        v.goToPage(pageIndex.toInt())
    }

    override fun setScale(viewId: Long, scale: Double) {
        if (!scale.isFinite() || scale <= 0) throw PdfErrors.error(PdfErrorCode.invalidArgument, "bad scale")
        view(viewId).setScale(scale)
    }

    override fun zoomToFit(viewId: Long) = view(viewId).zoomToFit()

    override fun setDisplayMode(viewId: Long, mode: PdfDisplayModeMsg) {
        view(viewId)
    }

    override fun search(viewId: Long, options: PdfSearchOptionsMsg, callback: (Result<PdfSearchResultMsg>) -> Unit) {
        val v = try {
            view(viewId)
        } catch (e: Exception) {
            return callback(Result.failure(PdfErrors.from(e, "search")))
        }
        searches[viewId]?.cancel()
        val token = PdfCancelToken()
        searches[viewId] = token
        val maxHits = options.maxHits.coerceIn(0, Int.MAX_VALUE.toLong()).toInt()
        threads.submit(threads.text, "search", { r: Result<PdfSearchResultMsg> ->
            if (searches[viewId] === token) searches.remove(viewId)
            callback(r)
        }) {
            val outcome = PdfSearch.search(v.document, options.query, options.caseSensitive, maxHits, token)
            PdfSearchResultMsg(
                hits = outcome.hits.mapIndexed { i, h ->
                    PdfSearchHitMsg(
                        index = i.toLong(),
                        pageIndex = h.match.pageIndex.toLong(),
                        rangeStart = h.match.start.toLong(),
                        rangeLength = h.match.length.toLong(),
                        snippet = h.match.snippet,
                        snippetMatchStart = h.match.snippetMatchStart.toLong(),
                        snippetMatchLength = h.match.length.toLong(),
                        bounds = PdfRectMsg(h.bounds[0].toDouble(), h.bounds[1].toDouble(), h.bounds[2].toDouble(), h.bounds[3].toDouble()),
                    )
                },
                truncated = outcome.truncated,
            )
        }
    }

    override fun cancelSearch(viewId: Long) {
        searches.remove(viewId)?.cancel()
    }

    override fun showSearchHit(viewId: Long, hit: PdfSearchHitMsg) {
        val v = view(viewId)
        if (hit.pageIndex < 0 || hit.pageIndex >= v.layout.pageCount) throw PdfErrors.error(PdfErrorCode.invalidArgument, "page out of range")
        v.setHighlight(hit.pageIndex.toInt(), hit.bounds.x, hit.bounds.y, hit.bounds.width, hit.bounds.height)
    }

    override fun clearSearch(viewId: Long) = view(viewId).clearHighlight()

    override fun selectedText(viewId: Long): String? {
        view(viewId)
        return null
    }

    override fun copySelection(viewId: Long): Boolean {
        view(viewId)
        return false
    }

    override fun clearSelection(viewId: Long) {
        view(viewId)
    }

    override fun pageThumbnail(request: PdfThumbnailRequestMsg, callback: (Result<PdfImageMsg>) -> Unit) {
        threads.submit(threads.documents, "pageThumbnail", callback) {
            val doc = store.get(request.handle)
            val platform = doc.requirePlatform()
            val index = request.pageIndex
            if (index < 0 || index >= doc.pages.size) throw PdfFailure.notFound("no such page")
            val image = PdfPageRenderer.thumbnail(
                platform,
                index.toInt(),
                doc.pages[index.toInt()],
                request.maxWidthPx.coerceIn(0, Int.MAX_VALUE.toLong()).toInt(),
                request.maxHeightPx.coerceIn(0, Int.MAX_VALUE.toLong()).toInt(),
            )
            PdfImageMsg(image.png, image.width.toLong(), image.height.toLong())
        }
    }

    override fun createTextureView(request: PdfTextureViewRequestMsg, callback: (Result<PdfTextureViewMsg>) -> Unit) {
        val result = try {
            Result.success(create(request))
        } catch (e: Throwable) {
            Result.failure(PdfErrors.from(e, "createTextureView"))
        }
        callback(result)
    }

    private fun create(request: PdfTextureViewRequestMsg): PdfTextureViewMsg {
        checkSize(request.widthPx, request.heightPx)
        val doc = store.get(request.handle)
        doc.requirePlatform()
        if (!doc.retain()) throw PdfFailure.notFound("no such document")
        try {
            val layout = TextureLayout(doc.pages)
            val w = request.widthPx.toInt()
            val h = request.heightPx.toInt()
            val first = request.initialPage.coerceIn(0, maxOf(0, layout.pageCount - 1).toLong()).toInt()
            val scale = layout.fitScale(w)
            val maxY = maxOf(0.0, layout.height - h / scale)
            val initial = Viewport(w, h, 0.0, layout.topOf(first).coerceIn(0.0, maxY), scale)
            val producer = textures.createSurfaceProducer(TextureRegistry.SurfaceLifecycle.resetInBackground)
            val view = PdfTextureView(nextViewId.getAndIncrement(), doc, producer, threads.render, initial)
            if (TextPrewarmPolicy.shouldPrewarm(Build.VERSION.SDK_INT, layout.pageCount, doc.text != null)) {
                // Once the first page is on screen; the prewarmer starts one job per document.
                view.onFirstCompleteFrame = {
                    if (!doc.closed) threads.prewarm.schedule(doc.handle, OpenPdfPrewarmTarget(doc))
                }
            }
            try {
                view.start()
            } catch (e: Throwable) {
                producer.release()
                throw e
            }
            views[view.viewId] = view
            return PdfTextureViewMsg(view.viewId, view.textureId, stateOf(view))
        } catch (e: Throwable) {
            threads.render.post { doc.release() }
            throw e
        }
    }

    override fun setTextureViewport(viewId: Long, viewport: PdfViewportMsg) {
        val v = view(viewId)
        checkSize(viewport.widthPx, viewport.heightPx)
        val next = Viewport(viewport.widthPx.toInt(), viewport.heightPx.toInt(), viewport.offsetX, viewport.offsetY, viewport.scale)
        if (!next.isValid) throw PdfErrors.error(PdfErrorCode.invalidArgument, "bad viewport")
        v.setViewport(next)
    }

    override fun disposeTextureView(viewId: Long) {
        val v = views.remove(viewId) ?: throw PdfErrors.error(PdfErrorCode.notFound, "no such view")
        searches.remove(viewId)?.cancel()
        v.dispose()
    }

    /** Disposes every view (plugin detached). */
    fun disposeAll() {
        threads.prewarm.cancelAll()
        searches.values.forEach { it.cancel() }
        searches.clear()
        views.values.toList().forEach { it.dispose() }
        views.clear()
    }

    private fun checkSize(w: Long, h: Long) {
        if (w <= 0 || h <= 0 || w > MAX_TEXTURE_PX || h > MAX_TEXTURE_PX) {
            throw PdfErrors.error(PdfErrorCode.invalidArgument, "texture size out of range")
        }
    }

    private fun stateOf(v: PdfTextureView): PdfViewStateMsg = PdfViewStateMsg(
        viewId = v.viewId,
        pageIndex = v.pageIndex.toLong(),
        pageCount = v.layout.pageCount.toLong(),
        scale = v.viewport.scale,
        minScale = v.minScale,
        maxScale = v.maxScale,
        hasSelection = false,
        displayMode = PdfDisplayModeMsg.CONTINUOUS,
    )

    companion object {
        /** Largest texture edge in pixels. */
        const val MAX_TEXTURE_PX = 8192L
    }
}
