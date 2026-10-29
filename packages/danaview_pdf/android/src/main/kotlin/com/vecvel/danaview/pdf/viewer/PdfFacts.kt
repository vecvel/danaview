// OWNER: HOM-25
//
// What the platform renderer doesn't say about a document, read with PdfBox-Android (read-only):
// the title, encryption and permissions, each page's crop box and /Rotate, and the outline. The
// platform PdfRenderer has no metadata, permission or outline API on any version (HOM-27).
//
// [PdfFacts.read] must run before the text reader touches the document (it zeroes page rotations
// in memory, PdfBoxText.kt). The outline walk is bounded (entries, depth, cycles) because a damaged
// outline can be cyclic or huge. Nothing here logs titles or text (rule 30).
// EXTENDED: HOM-29A ([PdfFacts.annotationPages]: the pages whose annotations the appearance layer
// draws, viewer/PdfAppearanceLayer.kt).

package com.vecvel.danaview.pdf.viewer

import com.tom_roush.pdfbox.cos.COSBase
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.outline.PDOutlineItem
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.outline.PDOutlineNode
import java.util.IdentityHashMap

/** Document facts from the PDF parser. */
data class PdfFacts(
    val title: String?,
    val encrypted: Boolean,
    val allowsCopying: Boolean,
    val allowsPrinting: Boolean,
    val pages: List<PageGeometry>,
    /** Page index → subtypes of its annotations that [PdfAppearanceLayer] may draw (HOM-29A). */
    val annotationPages: Map<Int, Set<String>> = emptyMap(),
) {
    companion object {
        /** The facts of [document] (call before any text is read from it). */
        fun read(document: PDDocument): PdfFacts {
            val pages = ArrayList<PageGeometry>(document.numberOfPages)
            val annotated = HashMap<Int, Set<String>>()
            for (page in document.pages) {
                try {
                    val subtypes = page.annotations.mapNotNullTo(HashSet()) { a -> a.subtype?.takeIf { it in PdfAppearanceLayer.DRAWN } }
                    if (subtypes.isNotEmpty()) annotated[pages.size] = subtypes
                } catch (e: Exception) {
                    // Unreadable annotations: the page shows as the platform draws it.
                }
                val geometry = try {
                    val box = page.cropBox
                    PageGeometry(box.width.toDouble(), box.height.toDouble(), PageGeometry.normalizeRotation(page.rotation))
                } catch (e: RuntimeException) {
                    PageGeometry.LETTER
                }
                pages += geometry
            }
            val title = try {
                document.documentInformation?.title?.trim()?.takeIf { it.isNotEmpty() }
            } catch (e: RuntimeException) {
                null
            }
            val permission = document.currentAccessPermission
            return PdfFacts(
                title = title,
                encrypted = document.isEncrypted,
                allowsCopying = permission.canExtractContent(),
                allowsPrinting = permission.canPrint(),
                pages = pages,
                annotationPages = annotated,
            )
        }
    }
}

/** One outline entry, flattened depth-first. */
data class OutlineEntry(val title: String, val pageIndex: Int, val depth: Int)

/** A node of an outline tree, abstracted for the bounded walk (and its JVM tests). */
interface OutlineSource {
    /** Children in order; [visit] returns false to stop. */
    fun forEachChild(visit: (OutlineSource) -> Boolean)

    val title: String

    /** Target page, or -1. */
    val pageIndex: Int

    /** Identity for cycle detection. */
    val key: Any
}

object OutlineWalker {
    /** The most entries returned (Apple: 5000). */
    const val MAX_ENTRIES = 5000

    /** The deepest level read (Apple: 32). */
    const val MAX_DEPTH = 32

    /** [root]'s descendants depth-first, bounded by [maxEntries], [MAX_DEPTH] and cycles. */
    fun flatten(root: OutlineSource, maxEntries: Int = MAX_ENTRIES): List<OutlineEntry> {
        val out = ArrayList<OutlineEntry>()
        val seen = HashSet<Any>()
        fun walk(node: OutlineSource, depth: Int) {
            if (depth >= MAX_DEPTH) return
            node.forEachChild { child ->
                if (out.size >= maxEntries || !seen.add(child.key)) return@forEachChild false
                out += OutlineEntry(child.title, child.pageIndex, depth)
                walk(child, depth + 1)
                out.size < maxEntries
            }
        }
        seen.add(root.key)
        walk(root, 0)
        return out
    }

    /** The outline of [document] (empty when there is none or it can't be read). */
    fun read(document: PDDocument): List<OutlineEntry> {
        val outline = try {
            document.documentCatalog.documentOutline
        } catch (e: RuntimeException) {
            null
        } ?: return emptyList()
        val pageIndex = IdentityHashMap<COSBase, Int>()
        try {
            var i = 0
            for (page in document.pages) pageIndex[page.cosObject] = i++
        } catch (e: RuntimeException) {
            // Pages that can't be listed have no targets (-1).
        }
        return try {
            flatten(PdfBoxOutlineNode(outline, document, pageIndex))
        } catch (e: RuntimeException) {
            emptyList()
        } catch (e: StackOverflowError) {
            emptyList()
        }
    }

    private class PdfBoxOutlineNode(
        private val node: PDOutlineNode,
        private val document: PDDocument,
        private val pages: IdentityHashMap<COSBase, Int>,
    ) : OutlineSource {
        override fun forEachChild(visit: (OutlineSource) -> Boolean) {
            var child: PDOutlineItem? = node.firstChild
            val local = HashSet<COSBase>()
            while (child != null && local.add(child.cosObject)) {
                if (!visit(PdfBoxOutlineNode(child, document, pages))) return
                child = try {
                    child.nextSibling
                } catch (e: RuntimeException) {
                    null
                }
            }
        }

        override val title: String
            get() = (node as? PDOutlineItem)?.title ?: ""

        override val pageIndex: Int
            get() {
                val item = node as? PDOutlineItem ?: return -1
                return try {
                    val page = item.findDestinationPage(document) ?: return -1
                    pages[page.cosObject] ?: -1
                } catch (e: Exception) {
                    -1
                }
            }

        override val key: Any get() = node.cosObject
    }
}
