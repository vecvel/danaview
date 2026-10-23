// OWNER: HOM-25
//
// Pure text matching for in-document search and text extraction limits (JVM-tested), the Android
// twin of HOM-24's PdfSearcher / PdfTextExtractor rules:
//
// - Case-insensitive search is also diacritic- and width-insensitive (Apple: `.caseInsensitive,
//   .diacriticInsensitive, .widthInsensitive`): both sides are folded (NFKD, combining marks
//   dropped, lower case) and every folded unit maps back to the UTF-16 range of the original code
//   point, so hits report offsets into the page text. Case-sensitive search is literal.
// - The query is trimmed; an empty query or maxHits <= 0 finds nothing.
// - Snippets: [CONTEXT] units around the match, on one line (CR, LF and tab become spaces, which
//   keeps the offsets).
// Nothing here logs a query or document text (rule 30).

package com.vecvel.danaview.pdf.text

import java.text.Normalizer
import java.util.Locale

/** A folded string and, per folded unit, the original UTF-16 range it came from. */
class FoldedText(val text: String, private val starts: IntArray, private val ends: IntArray) {
    /** The original range `[start, end)` of folded units `[from, to)`. */
    fun originalRange(from: Int, to: Int): IntRange {
        val s = starts[from]
        val e = ends[to - 1]
        return s until e
    }

    companion object {
        /** [s] as is (case-sensitive search). */
        fun identity(s: String): FoldedText {
            val starts = IntArray(s.length) { it }
            val ends = IntArray(s.length) { it + 1 }
            return FoldedText(s, starts, ends)
        }

        /** [s] folded for case-, diacritic- and width-insensitive matching. */
        fun fold(s: String): FoldedText {
            val out = StringBuilder(s.length)
            val starts = IntArrayBuilder(s.length)
            val ends = IntArrayBuilder(s.length)
            var i = 0
            while (i < s.length) {
                val cp = s.codePointAt(i)
                val n = Character.charCount(cp)
                val folded = foldCodePoint(cp)
                for (k in folded.indices) {
                    out.append(folded[k])
                    starts.add(i)
                    ends.add(i + n)
                }
                i += n
            }
            return FoldedText(out.toString(), starts.toArray(), ends.toArray())
        }

        private fun foldCodePoint(cp: Int): String {
            if (cp < 0x80) {
                val c = cp.toChar()
                return if (c in 'A'..'Z') (c + 32).toString() else c.toString()
            }
            val decomposed = Normalizer.normalize(String(Character.toChars(cp)), Normalizer.Form.NFKD)
            val lowered = decomposed.lowercase(Locale.ROOT)
            val again = if (lowered == decomposed) lowered else Normalizer.normalize(lowered, Normalizer.Form.NFKD)
            val sb = StringBuilder(again.length)
            var j = 0
            while (j < again.length) {
                val c = again.codePointAt(j)
                when (Character.getType(c)) {
                    Character.NON_SPACING_MARK.toInt(), Character.COMBINING_SPACING_MARK.toInt(), Character.ENCLOSING_MARK.toInt() -> Unit
                    else -> sb.appendCodePoint(c)
                }
                j += Character.charCount(c)
            }
            return sb.toString()
        }
    }

    private class IntArrayBuilder(capacity: Int) {
        private var data = IntArray(maxOf(capacity, 8))
        private var size = 0

        fun add(v: Int) {
            if (size == data.size) data = data.copyOf(size * 2)
            data[size++] = v
        }

        fun toArray(): IntArray = data.copyOf(size)
    }
}

/** One match in a page's text: UTF-16 range and its one-line snippet. */
data class TextMatch(
    val pageIndex: Int,
    val start: Int,
    val length: Int,
    val snippet: String,
    val snippetMatchStart: Int,
)

/** A search query, folded once. */
class TextQuery private constructor(val needle: String, val caseSensitive: Boolean) {
    val isEmpty: Boolean get() = needle.isEmpty()

    /** The matches of this query in [text] (page [pageIndex]), at most [limit]. */
    fun matches(pageIndex: Int, text: String, limit: Int): List<TextMatch> {
        if (isEmpty || text.isEmpty() || limit <= 0) return emptyList()
        val hay = if (caseSensitive) FoldedText.identity(text) else FoldedText.fold(text)
        val out = ArrayList<TextMatch>()
        var from = 0
        while (out.size < limit) {
            val at = hay.text.indexOf(needle, from)
            if (at < 0) break
            val range = hay.originalRange(at, at + needle.length)
            var end = range.last + 1
            // Combining marks after the match belong to its last character ("e" + U+0301).
            if (!caseSensitive) {
                while (end < text.length && isMark(text.codePointAt(end))) end += Character.charCount(text.codePointAt(end))
            }
            out += match(pageIndex, text, range.first, end - range.first)
            from = at + maxOf(1, needle.length)
        }
        return out
    }

    companion object {
        /** Units of context on each side of a match in its snippet (Apple: 40). */
        const val CONTEXT = 40

        fun of(query: String, caseSensitive: Boolean): TextQuery {
            val trimmed = query.trim()
            return TextQuery(if (caseSensitive) trimmed else FoldedText.fold(trimmed).text, caseSensitive)
        }

        private fun isMark(cp: Int): Boolean = when (Character.getType(cp)) {
            Character.NON_SPACING_MARK.toInt(), Character.COMBINING_SPACING_MARK.toInt(), Character.ENCLOSING_MARK.toInt() -> true
            else -> false
        }

        fun match(pageIndex: Int, text: String, start: Int, length: Int): TextMatch {
            val s = maxOf(0, start - CONTEXT)
            val e = minOf(text.length, start + length + CONTEXT)
            val snippet = text.substring(s, e).replace('\r', ' ').replace('\n', ' ').replace('\t', ' ')
            return TextMatch(pageIndex, start, length, snippet, start - s)
        }
    }
}

/** The character limit of an extraction (`maxChars`, -1 for none), applied page by page. */
class TextBudget(private val maxChars: Int) {
    private var used = 0

    /** True once the limit cut a page. */
    var truncated = false
        private set

    /** [text] as far as the limit allows (the cut page is kept, then reading stops). */
    fun take(text: String): String {
        if (maxChars < 0) return text
        if (used + text.length > maxChars) {
            val keep = maxOf(0, maxChars - used)
            truncated = true
            used = maxChars
            return text.substring(0, safeCut(text, keep))
        }
        used += text.length
        return text
    }

    /** Never splits a surrogate pair. */
    private fun safeCut(text: String, at: Int): Int =
        if (at in 1 until text.length && Character.isHighSurrogate(text[at - 1]) && Character.isLowSurrogate(text[at])) at - 1 else at
}
