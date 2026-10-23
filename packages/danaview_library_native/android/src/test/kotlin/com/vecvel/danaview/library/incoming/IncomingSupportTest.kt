// OWNER: HOM-21A
//
// JVM tests of the pure incoming-intent helpers (incoming/IncomingSupport.kt): routing of VIEW,
// SEND and SEND_MULTIPLE (documents, images and text to the incoming bridge; video, audio, other
// schemes and unknown VIEW types left to the 1.1 player path), type resolution (intent, provider,
// extension, wildcards, octet-stream), file:// refusals, de-duplication and the item cap,
// malformed intents, text-share names, the pending queue (each batch handed out once), and the
// app manifest's INT-104 filters agreeing with the routing (the 1.1 filters unchanged).

package com.vecvel.danaview.library.incoming

import com.vecvel.danaview.library.pigeon.IncomingActionMsg
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import java.util.TimeZone
import javax.xml.parsers.DocumentBuilderFactory

class IncomingSupportTest {
    private val view = IntentSnapshot.ACTION_VIEW
    private val send = IntentSnapshot.ACTION_SEND
    private val sendMultiple = IntentSnapshot.ACTION_SEND_MULTIPLE

    /** Provider types by URI; anything else answers null. Counts the calls. */
    private class Provider(private val types: Map<String, String?> = emptyMap(), private val throws: Boolean = false) {
        var calls = 0
        fun type(uri: String): String? {
            calls++
            if (throws) throw SecurityException("no grant")
            return types[uri]
        }
    }

    private fun route(s: IntentSnapshot, provider: Provider = Provider(), allowFile: (String) -> Boolean = { true }) =
        IncomingRouting.route(s, provider::type, allowFile)

    private fun incoming(r: IncomingRoute): IncomingRoute.Incoming {
        assertTrue("expected Incoming, got $r", r is IncomingRoute.Incoming)
        return r as IncomingRoute.Incoming
    }

    @Test
    fun viewOfDocumentsTextAndImagesIsClaimed() {
        for (type in IncomingRouting.DOCUMENT_TYPES + listOf("text/plain", "text/csv", "image/jpeg", "image/heic")) {
            val r = incoming(route(IntentSnapshot(view, type = type, data = "content://p/doc/1")))
            assertEquals(IncomingActionMsg.VIEW, r.action)
            assertEquals(listOf(IncomingCandidate("content://p/doc/1", type)), r.items)
        }
        // A file:// document too (old senders).
        val f = incoming(route(IntentSnapshot(view, type = "application/pdf", data = "file:///sdcard/Download/a.pdf")))
        assertEquals("file:///sdcard/Download/a.pdf", f.items.single().uri)
    }

    @Test
    fun videoAudioOtherSchemesAndUnknownViewTypesStayOnThePlayerPath() {
        assertSame(IncomingRoute.Player, route(IntentSnapshot(view, type = "video/mp4", data = "content://p/v/1")))
        assertSame(IncomingRoute.Player, route(IntentSnapshot(view, type = "video/*", data = "file:///sdcard/a.mkv")))
        assertSame(IncomingRoute.Player, route(IntentSnapshot(view, type = "audio/mpeg", data = "content://p/a/1")))
        assertSame(IncomingRoute.Player, route(IntentSnapshot(view, data = "https://example.com/stream.m3u8")))
        assertSame(IncomingRoute.Player, route(IntentSnapshot(view, type = "application/pdf", data = "https://example.com/a.pdf")))
        assertSame(IncomingRoute.Player, route(IntentSnapshot(view, data = "danaview://open?url=https%3A%2F%2Fx")))
        assertSame(IncomingRoute.Player, route(IntentSnapshot(view, data = "rtsp://cam/live")))
        // Unknown type, nothing to tell: the 1.1 behaviour (the player tries it).
        assertSame(IncomingRoute.Player, route(IntentSnapshot(view, type = "application/octet-stream", data = "content://p/x/1")))
        assertSame(IncomingRoute.Player, route(IntentSnapshot(view, data = "content://p/x/1")))
    }

    @Test
    fun viewTypeComesFromTheIntentThenTheProviderThenTheName() {
        // A concrete intent type: no provider call on the main thread.
        val p = Provider(mapOf("content://p/1" to "video/mp4"))
        incoming(route(IntentSnapshot(view, type = "application/pdf", data = "content://p/1"), p))
        assertEquals(0, p.calls)
        // No type: the provider decides.
        val q = Provider(mapOf("content://p/2" to "image/png"))
        assertEquals("image/png", incoming(route(IntentSnapshot(view, data = "content://p/2"), q)).items.single().mimeType)
        assertSame(IncomingRoute.Player, route(IntentSnapshot(view, data = "content://p/1"), p))
        // octet-stream from both: the extension.
        val o = Provider(mapOf("content://p/3/Budget.XLSX" to "application/octet-stream"))
        assertEquals(
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            incoming(route(IntentSnapshot(view, type = "application/octet-stream", data = "content://p/3/Budget.XLSX"), o)).items.single().mimeType,
        )
        // A provider that throws counts as unknown.
        assertEquals("application/pdf", incoming(route(IntentSnapshot(view, data = "content://p/4/a.pdf"), Provider(throws = true))).items.single().mimeType)
        // A wildcard VIEW type counts by its top level.
        assertEquals(IncomingActionMsg.VIEW, incoming(route(IntentSnapshot(view, type = "image/*", data = "content://p/5"))).action)
    }

    @Test
    fun sendOfOneItem() {
        // Stream, else ClipData, else data.
        val a = incoming(route(IntentSnapshot(send, type = "application/pdf", streams = listOf("content://p/1"), clipUris = listOf("content://p/9"))))
        assertEquals(listOf(IncomingCandidate("content://p/1", "application/pdf")), a.items)
        assertEquals(IncomingActionMsg.SEND, a.action)
        assertEquals("content://p/9", incoming(route(IntentSnapshot(send, type = "image/jpeg", clipUris = listOf("content://p/9")))).items.single().uri)
        // The provider's type wins over a wildcard intent type; a video goes to the player.
        val p = Provider(mapOf("content://p/v" to "video/quicktime", "content://p/i" to "image/heic"))
        assertSame(IncomingRoute.Player, route(IntentSnapshot(send, type = "*/*", streams = listOf("content://p/v")), p))
        assertSame(IncomingRoute.Player, route(IntentSnapshot(send, type = "video/*", streams = listOf("content://p/x")), p))
        assertEquals("image/heic", incoming(route(IntentSnapshot(send, type = "*/*", streams = listOf("content://p/i")), p)).items.single().mimeType)
        // An unknown type is still imported (the file card shows it).
        val u = incoming(route(IntentSnapshot(send, type = "application/zip", streams = listOf("content://p/z"))))
        assertEquals("application/zip", u.items.single().mimeType)
        assertNull(incoming(route(IntentSnapshot(send, type = "*/*", streams = listOf("content://p/q")))).items.single().mimeType)
        // A non-local stream is ignored.
        assertSame(IncomingRoute.Ignore, route(IntentSnapshot(send, type = "image/png", streams = listOf("https://x/y.png"))))
    }

    @Test
    fun sendOfTextBecomesATextItem() {
        val r = incoming(route(IntentSnapshot(send, type = "text/plain", text = "hello\nworld", subject = "Notes")))
        assertTrue(r.items.isEmpty())
        assertEquals("hello\nworld", r.text)
        assertEquals("Notes", r.subject)
        // A stream wins over a caption.
        assertEquals(1, incoming(route(IntentSnapshot(send, type = "image/png", streams = listOf("content://p/1"), text = "caption"))).items.size)
        // Oversized text is cut.
        val long = "x".repeat(IncomingRouting.MAX_TEXT_CHARS + 10)
        assertEquals(IncomingRouting.MAX_TEXT_CHARS, incoming(route(IntentSnapshot(send, type = "text/plain", text = long))).text!!.length)
        // Blank text and nothing else: ignored.
        assertSame(IncomingRoute.Ignore, route(IntentSnapshot(send, type = "text/plain", text = "  ")))
    }

    @Test
    fun sendMultipleClaimsEverythingWithoutAskingProviders() {
        val p = Provider(mapOf("content://p/v" to "video/mp4"))
        val r = incoming(
            route(
                IntentSnapshot(
                    sendMultiple,
                    type = "*/*",
                    streams = listOf("content://p/a.pdf", "content://p/v", "content://p/a.pdf", " ", "https://x/y", "file:///data/data/x/secret.db", "file:///sdcard/b.jpg"),
                ),
                p,
            ) { !it.contains("/data/data/") },
        )
        assertEquals(IncomingActionMsg.SEND_MULTIPLE, r.action)
        assertEquals(listOf("content://p/a.pdf", "content://p/v", "file:///sdcard/b.jpg"), r.items.map { it.uri })
        assertEquals(listOf("application/pdf", null, "image/jpeg"), r.items.map { it.mimeType })
        assertEquals(2, r.dropped)
        assertEquals(0, p.calls)
        // ClipData when EXTRA_STREAM is missing.
        assertEquals(2, incoming(route(IntentSnapshot(sendMultiple, clipUris = listOf("content://p/1", "content://p/2")))).items.size)
        // Capped.
        val many = (1..IncomingRouting.MAX_ITEMS + 7).map { "content://p/$it" }
        val capped = incoming(route(IntentSnapshot(sendMultiple, streams = many)))
        assertEquals(IncomingRouting.MAX_ITEMS, capped.items.size)
        assertEquals(7, capped.dropped)
        // Nothing usable.
        assertSame(IncomingRoute.Ignore, route(IntentSnapshot(sendMultiple, streams = listOf("https://x"))))
        assertSame(IncomingRoute.Ignore, route(IntentSnapshot(sendMultiple)))
    }

    @Test
    fun malformedAndForeignIntentsAreIgnored() {
        assertSame(IncomingRoute.Ignore, route(IntentSnapshot(action = null)))
        assertSame(IncomingRoute.Ignore, route(IntentSnapshot("android.intent.action.MAIN")))
        assertSame(IncomingRoute.Ignore, route(IntentSnapshot(IncomingIntents.ACTION_HANDLED, type = "application/pdf", data = "content://p/1")))
        assertSame(IncomingRoute.Ignore, route(IntentSnapshot(view, type = "application/pdf")))
        assertSame(IncomingRoute.Ignore, route(IntentSnapshot(view, type = "application/pdf", data = "   ")))
        assertSame(IncomingRoute.Ignore, route(IntentSnapshot(send)))
        // A private file:// is refused (claimed, nothing delivered), not handed to the player.
        assertSame(IncomingRoute.Refused, route(IntentSnapshot(view, type = "application/pdf", data = "file:///data/user/0/app/files/library.db")) { false })
        assertSame(IncomingRoute.Refused, route(IntentSnapshot(send, type = "image/png", streams = listOf("file:///x.png"))) { false })
        // A private file:// video is the 1.1 path's, as before.
        assertSame(IncomingRoute.Player, route(IntentSnapshot(view, type = "video/mp4", data = "file:///data/user/0/app/x.mp4")) { false })
        // Odd schemes.
        assertEquals("", IncomingRouting.scheme("no-scheme"))
        assertEquals("", IncomingRouting.scheme(":x"))
        assertEquals("content", IncomingRouting.scheme("CONTENT://p/1"))
    }

    @Test
    fun typesAndKinds() {
        assertNull(IncomingRouting.concreteType(null))
        assertNull(IncomingRouting.concreteType("*/*"))
        assertNull(IncomingRouting.concreteType("image/*"))
        assertNull(IncomingRouting.concreteType("application/octet-stream"))
        assertNull(IncomingRouting.concreteType("pdf"))
        assertEquals("text/plain", IncomingRouting.concreteType(" Text/Plain; charset=utf-8"))
        assertEquals("application/pdf", IncomingRouting.typeFromName("dir/My File.PDF"))
        assertNull(IncomingRouting.typeFromName(".pdf"))
        assertNull(IncomingRouting.typeFromName("noext"))
        assertNull(IncomingRouting.typeFromName("a.unknownext"))
        assertEquals(IncomingKind.DOCUMENT, IncomingRouting.kind("application/vnd.oasis.opendocument.presentation"))
        assertEquals(IncomingKind.TEXT, IncomingRouting.kind("text/*"))
        assertEquals(IncomingKind.VIDEO, IncomingRouting.kind("VIDEO/MP4"))
        assertEquals(IncomingKind.UNKNOWN, IncomingRouting.kind("application/zip"))
        assertEquals(IncomingKind.UNKNOWN, IncomingRouting.kind(null))
    }

    @Test
    fun textFileNames() {
        val utc = TimeZone.getTimeZone("UTC")
        // No subject: "Shared text yyyy-MM-dd HHmm" in the given (local) zone, minutes, no seconds (0dc39697).
        assertEquals("Shared text 2023-11-14 2213.txt", IncomingRouting.textFileName(null, 1_700_000_000_000, utc))
        assertEquals("Shared text 2023-11-14 2213.txt", IncomingRouting.textFileName(" \n ", 1_700_000_000_000, utc))
        assertEquals("Shared text 2023-11-15 0343.txt", IncomingRouting.textFileName(null, 1_700_000_000_000, TimeZone.getTimeZone("Asia/Kolkata")))
        assertEquals("Shared text 1970-01-01 0000.txt", IncomingRouting.textFileName("", 0, utc))
        // A subject names it, made safe for a file name.
        assertEquals("Trip notes.txt", IncomingRouting.textFileName("  Trip notes  ", 0, utc))
        assertEquals("My note 1 2.txt", IncomingRouting.textFileName("My note: 1/2", 0, utc))
        assertEquals("a b c.txt", IncomingRouting.textFileName("a/b\\c", 0, utc))
        assertEquals("a b c d e f g.txt", IncomingRouting.textFileName("a*b?c\"d<e>f|g", 0, utc))
        assertEquals("line one line two.txt", IncomingRouting.textFileName("line one\r\n\tline two\u0000\u007f", 0, utc))
        assertEquals("list.TXT", IncomingRouting.textFileName("list.TXT", 0, utc))
        assertEquals("hidden.txt", IncomingRouting.textFileName("..hidden.. ", 0, utc))
        assertEquals("Party 🎉 café.txt", IncomingRouting.textFileName("Party 🎉 café", 0, utc))
        // Only invalid characters (or dots/spaces): the date name.
        assertEquals("Shared text 1970-01-01 0000.txt", IncomingRouting.textFileName("...", 0, utc))
        assertEquals("Shared text 1970-01-01 0000.txt", IncomingRouting.textFileName("/\\:*?\"<>|", 0, utc))
        assertEquals("Shared text 1970-01-01 0000.txt", IncomingRouting.textFileName("\u0001\n . / .", 0, utc))
        // Very long: at most 200 UTF-8 bytes before ".txt", never splitting a character.
        assertEquals("y".repeat(200) + ".txt", IncomingRouting.textFileName("y".repeat(300), 0, utc))
        val emoji = IncomingRouting.textFileName("😀".repeat(100), 0, utc) // 4 bytes each
        assertEquals("😀".repeat(50) + ".txt", emoji)
        val mixed = IncomingRouting.textFileName("a" + "é".repeat(150), 0, utc) // 1 + 2*n bytes
        assertEquals("a" + "é".repeat(99) + ".txt", mixed)
        assertTrue(mixed.toByteArray(Charsets.UTF_8).size <= 204)
        assertEquals("ab", IncomingRouting.cutUtf8("ab😀", 5))
        // Cut, then trailing spaces/dots trimmed again.
        assertEquals("x".repeat(198) + ".txt", IncomingRouting.textFileName("x".repeat(198) + " .zzz", 0, utc))
    }

    @Test
    fun textNameClashesInsideABatch() {
        // Clashes against the library's names are numbered on commit (Dart uniqueName); inside one
        // batch the native side numbers them the same way.
        val n = IncomingRouting.textFileName(null, 0, TimeZone.getTimeZone("UTC"))
        assertEquals(
            listOf("Shared text 1970-01-01 0000.txt", "Shared text 1970-01-01 0000 (2).txt", "Shared text 1970-01-01 0000 (3).txt"),
            com.vecvel.danaview.library.pickers.PickerRequests.uniqueNames(listOf(n, n, n)),
        )
    }

    @Test
    fun privatePaths() {
        val roots = listOf("/data/user/0/com.vecvel.danaview", "/data/data/com.vecvel.danaview/")
        assertTrue(IncomingRouting.isInside("/data/user/0/com.vecvel.danaview/files/library.db", roots))
        assertTrue(IncomingRouting.isInside("/data/data/com.vecvel.danaview", roots))
        assertFalse(IncomingRouting.isInside("/data/user/0/com.vecvel.danaview2/x", roots))
        assertFalse(IncomingRouting.isInside("/storage/emulated/0/Download/a.pdf", roots))
        assertFalse(IncomingRouting.isInside("/x", listOf("", "/")))
    }

    @Test
    fun queueHandsEachBatchOutOnce() {
        val q = IncomingQueue<Pair<String, Int>> { it.first }
        q.add("a" to 1)
        q.add("b" to 2)
        assertEquals(2, q.pendingCount)
        assertEquals(listOf("a" to 1, "b" to 2), q.takePending())
        assertTrue(q.takePending().isEmpty())
        assertEquals(2, q.outstandingCount)
        // A taken batch added again is not handed out twice.
        q.add("a" to 1)
        assertTrue(q.takePending().isEmpty())
        q.add("c" to 3)
        // Acknowledging a pending (event-delivered) batch removes it before it is taken.
        assertEquals("c" to 3, q.acknowledge("c"))
        assertTrue(q.takePending().isEmpty())
        assertEquals("a" to 1, q.acknowledge("a"))
        assertNull(q.acknowledge("a"))
        assertNull(q.acknowledge("zzz"))
        assertEquals(1, q.outstandingCount)
    }

    // ---------------------------------------------------------------------------------------------
    // The app manifest (android/app/src/main/AndroidManifest.xml)

    private class Filter(val actions: List<String>, val categories: List<String>, val schemes: List<String>, val types: List<String>)

    private fun manifestFilters(): List<Filter> {
        // The module directory is packages/danaview_library_native/android.
        val manifest = File("../../../android/app/src/main/AndroidManifest.xml")
        assertTrue("app manifest at ${manifest.absolutePath}", manifest.isFile)
        val doc = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }.newDocumentBuilder().parse(manifest)
        val ns = "http://schemas.android.com/apk/res/android"
        val activities = doc.getElementsByTagName("activity")
        val main = (0 until activities.length).map { activities.item(it) as Element }.single { it.getAttributeNS(ns, "name") == ".MainActivity" }
        // The INT-104 filters live on the flag-gated alias of MainActivity (8d8fdf87): both count.
        val aliases = doc.getElementsByTagName("activity-alias")
        val owners = listOf(main) + (0 until aliases.length).map { aliases.item(it) as Element }
            .filter { it.getAttributeNS(ns, "targetActivity") == ".MainActivity" }
        val filters = owners.flatMap { o -> o.getElementsByTagName("intent-filter").let { l -> (0 until l.length).map { l.item(it) as Element } } }
        return filters.map { f ->
            fun attrs(tag: String, attr: String): List<String> {
                val nodes = f.getElementsByTagName(tag)
                return (0 until nodes.length).mapNotNull { (nodes.item(it) as Element).getAttributeNS(ns, attr).takeIf { a -> a.isNotEmpty() } }
            }
            Filter(attrs("action", "name"), attrs("category", "name"), attrs("data", "scheme"), attrs("data", "mimeType"))
        }
    }

    @Test
    fun manifestDeclaresInt104FiltersAndKeepsThe11Ones() {
        val filters = manifestFilters()
        val default = "android.intent.category.DEFAULT"
        val browsable = "android.intent.category.BROWSABLE"
        val docTypes = IncomingRouting.DOCUMENT_TYPES + listOf("text/*", "image/*")

        val viewDocs = filters.single { it.actions == listOf(view) && "application/pdf" in it.types }
        assertEquals(listOf(default, browsable), viewDocs.categories)
        assertEquals(listOf("file", "content"), viewDocs.schemes)
        assertEquals(docTypes, viewDocs.types)

        for (action in listOf(send, sendMultiple)) {
            val f = filters.single { it.actions == listOf(action) }
            assertEquals(listOf(default), f.categories)
            assertTrue(f.schemes.isEmpty())
            assertEquals(docTypes + "video/*", f.types)
        }

        // 1.1 (P-7): video and audio VIEW filters and danaview://, unchanged.
        for (media in listOf("video/*", "audio/*")) {
            val f = filters.single { it.actions == listOf(view) && it.types == listOf(media) }
            assertEquals(listOf(default, browsable), f.categories)
            assertEquals(listOf("file", "content", "http", "https"), f.schemes)
        }
        val scheme = filters.single { it.schemes == listOf("danaview") }
        assertEquals(listOf(view), scheme.actions)
        assertTrue(scheme.types.isEmpty())
        assertEquals(1, filters.count { it.actions == listOf("android.intent.action.MAIN") })
        assertEquals(7, filters.size)

        // Every declared type routes where the plan says: documents, text, images to the bridge.
        for (type in docTypes) {
            assertTrue(type, route(IntentSnapshot(view, type = type, data = "content://p/1")) is IncomingRoute.Incoming)
        }
    }
}
