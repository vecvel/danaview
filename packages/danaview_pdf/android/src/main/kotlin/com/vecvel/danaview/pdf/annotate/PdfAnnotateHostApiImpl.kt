// OWNER: HOM-29A
//
// PdfAnnotateHostApi (HOM-29 amendment, pigeons/pdf_api.dart) on Android, as
// darwin/Classes/Annotate/PdfAnnotateHostApiImpl.swift:
//
// - setAnnotateMode(viewId, mode): the texture view enters annotate mode (null leaves it and
//   removes the preview). The mode's input matters natively only for `place` (the selected stamp's
//   resize handle); the touches themselves never reach a texture, so the Dart texture view turns
//   them into the PdfAnnotateEventsApi events (lib/src/pdf_texture_annotate.dart).
// - showAnnotations(viewId, items, selectedId): replaces the preview drawn over the tiles
//   (viewer/PdfAnnotatePreview.kt); the file is never written.
// - selectionLines(viewId): always empty - Android's texture viewer has no text selection
//   (capabilities.selection false), so the Dart markup tools have nothing to mark.
// - save(request): a tool job (`tool: annotate`, cancelled by PdfToolsHostApi.cancel) on the tools
//   pool (glue/PdfToolsHostApiImpl.run), answering on the main thread.
//
// Unknown view ids answer notFound. Main thread only. Nothing is logged (rule 30).

package com.vecvel.danaview.pdf.annotate

import com.vecvel.danaview.pdf.glue.PdfErrors
import com.vecvel.danaview.pdf.glue.PdfToolsHostApiImpl
import com.vecvel.danaview.pdf.pigeon.PdfAnnotateHostApi
import com.vecvel.danaview.pdf.pigeon.PdfAnnotateInputMsg
import com.vecvel.danaview.pdf.pigeon.PdfAnnotateItemMsg
import com.vecvel.danaview.pdf.pigeon.PdfAnnotateModeMsg
import com.vecvel.danaview.pdf.pigeon.PdfAnnotateSaveRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfPageRectsMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolResultMsg
import com.vecvel.danaview.pdf.viewer.PdfTextureView
import com.vecvel.danaview.pdf.viewer.PreviewState

class PdfAnnotateHostApiImpl(
    /** The texture view [viewId] (throws a notFound Pigeon error for an unknown id). */
    private val view: (viewId: Long) -> PdfTextureView,
    private val tools: PdfToolsHostApiImpl,
) : PdfAnnotateHostApi {
    // Main thread only: the mode of each view in annotate mode.
    private val modes = HashMap<Long, PdfAnnotateModeMsg>()

    /** The annotate mode of [viewId], or null (tests). */
    fun mode(viewId: Long): PdfAnnotateModeMsg? = modes[viewId]

    override fun setAnnotateMode(viewId: Long, mode: PdfAnnotateModeMsg?) {
        val v = try {
            view(viewId)
        } catch (e: Exception) {
            modes.remove(viewId)
            throw e
        }
        if (mode == null) {
            modes.remove(viewId)
            v.setPreview(PreviewState.NONE)
        } else {
            modes[viewId] = mode
            v.setPreview(v.preview.copy(placeMode = mode.input == PdfAnnotateInputMsg.PLACE))
        }
    }

    override fun showAnnotations(viewId: Long, items: List<PdfAnnotateItemMsg>, selectedId: String?) {
        val v = view(viewId)
        val preview = try {
            items.map(PdfAnnotator::item)
        } catch (e: Exception) {
            throw PdfErrors.from(e, "showAnnotations")
        }
        v.setPreview(PreviewState(modes[viewId]?.input == PdfAnnotateInputMsg.PLACE, preview, selectedId))
    }

    override fun selectionLines(viewId: Long): List<PdfPageRectsMsg> {
        view(viewId)
        return emptyList()
    }

    override fun save(request: PdfAnnotateSaveRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) =
        tools.run(request.jobId, PdfToolKindMsg.ANNOTATE, "annotate", callback) { PdfAnnotator.save(request, it) }
}
