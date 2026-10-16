// OWNER: ENG-08 (frozen by ENG-06, D-42; amended by INT-06: render-preview requests, rendered ranges;
// by INT-07: workDir, notificationTexts)
//
// Argument checks of the host handlers (ARCH §12.6: handlers validate before posting work). A bad
// argument is a Dart bug, so it fails with `internal` (ARCH §19: UnknownFailure + debug assert);
// empty plan or patch payloads fail with `planInvalid`; output paths outside the engine roots fail
// with `permissionDenied` (ARCH §20.1). Render-preview outputs and rendered-range files must lie
// inside `<cache>/renders/` (`permissionDenied` otherwise); a rendered-range list that is unsorted,
// overlapping or has an empty range is `planInvalid` (D-45). Messages name the argument, never its
// value.

package com.vecvel.danaview.editor.engine.glue

import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.pigeon.EditingModeKindMsg
import com.vecvel.danaview.editor.engine.pigeon.EditingModeMsg
import com.vecvel.danaview.editor.engine.pigeon.EncodeSettingsMsg
import com.vecvel.danaview.editor.engine.export.ExportNotificationTexts
import com.vecvel.danaview.editor.engine.pigeon.ExportNotificationTextsMsg
import com.vecvel.danaview.editor.engine.pigeon.JobKindMsg
import com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.LookSpecMsg
import com.vecvel.danaview.editor.engine.pigeon.LoopMsg
import com.vecvel.danaview.editor.engine.pigeon.MediaRefMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewConfigMsg
import com.vecvel.danaview.editor.engine.pigeon.RenderedRangeMsg
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg
import com.vecvel.danaview.editor.engine.pigeon.ThumbnailRequestMsg
import java.io.File

/** Host argument validation (ARCH §12.6). */
object Check {
    /** Project and export frame rates of v1 (ARCH §5, `FrameRate.supportedProjectRates`). */
    val FRAME_RATES: Set<Long> = setOf(24, 25, 30, 48, 50, 60)

    /** Longest canvas, export or frame side the engine accepts. */
    const val MAX_SIDE = 8192L

    private const val MAX_ID = 256

    fun fail(name: String, why: String): Nothing = throw EngineErrors.invalidArgument(name, why)

    /** A non-empty id without control characters, at most 256 chars. */
    fun id(name: String, value: String) {
        if (value.isEmpty()) fail(name, "empty")
        if (value.length > MAX_ID) fail(name, "too long")
        if (value.any { it.isISOControl() }) fail(name, "control characters")
    }

    /** [value] in [min]..[max]. */
    fun range(name: String, value: Long, min: Long, max: Long) {
        if (value < min || value > max) fail(name, "out of range")
    }

    /** A finite value in 0..1. */
    fun unit(name: String, value: Double) {
        if (!value.isFinite() || value < 0.0 || value > 1.0) fail(name, "not in 0..1")
    }

    /** A supported frame rate. */
    fun fps(name: String, value: Long) {
        if (value !in FRAME_RATES) fail(name, "unsupported frame rate")
    }

    /** A `file://` or `content://` URI, or an absolute path. */
    fun mediaUri(name: String, uri: String) {
        if (uri.isEmpty()) fail(name, "empty")
        if (uri.indexOf('\u0000') >= 0) fail(name, "NUL character")
        val ok = uri.startsWith("content://") || uri.startsWith("file://") || uri.startsWith("/")
        if (!ok) fail(name, "not a file or content URI")
    }

    /** A `content://` URI. */
    fun contentUri(name: String, uri: String) {
        if (!uri.startsWith("content://") || uri.length <= "content://".length) fail(name, "not a content URI")
    }

    /** An absolute path (or file URI). */
    fun absolutePath(name: String, path: String) {
        if (Paths.normalize(path) == null) fail(name, "not an absolute path")
    }

    /** A non-empty plan or patch payload. */
    fun planBytes(name: String, bytes: ByteArray) {
        if (bytes.isEmpty()) throw EngineErrors.invalidPlan("$name is empty")
    }

    /** A non-empty payload. */
    fun bytes(name: String, bytes: ByteArray) {
        if (bytes.isEmpty()) fail(name, "empty")
    }

    /** Engine media. */
    fun media(media: ResolvedMediaMsg) {
        mediaUri("media.uri", media.uri)
        id("media.fingerprint", media.fingerprint)
    }

    /** A media reference (stat, quickHash). Android ignores the iOS bookmark. */
    fun mediaRef(media: MediaRefMsg) = mediaUri("media.uri", media.uri)

    /** A writable output path inside the engine roots; `internal` before `initialize`. */
    fun output(name: String, path: String?, paths: Paths?) {
        if (path == null) fail(name, "missing")
        val roots = paths ?: throw EngineErrors.notInitialized()
        roots.requireWritable(path, name)
    }

    /** An existing engine file to hand off (inside the engine roots). */
    fun ownedFile(name: String, path: String, paths: Paths?) = output(name, path, paths)

    /** A file name without separators. */
    fun fileName(name: String, value: String) {
        id(name, value)
        if (value.contains('/') || value.contains('\\') || value == "." || value == "..") fail(name, "not a plain file name")
    }

    /** A directory inside `<cache>/work/` (INT-07 materializePick); `permissionDenied` outside it. */
    fun workDir(name: String, path: String, paths: Paths?): File {
        val roots = paths ?: throw EngineErrors.notInitialized()
        val dir = Paths.normalize(path) ?: fail(name, "not an absolute path")
        if (!Paths.isInside(dir, roots.work)) throw EngineException(EngineErrorCode.permissionDenied, "$name is outside the work directory")
        return dir
    }

    /**
     * INT-07 / M-19: the localized notification texts with every blank or over-256-char string
     * replaced by its English default (never fails: the texts are cosmetic, ExportNotificationTexts).
     */
    fun notificationTexts(t: ExportNotificationTextsMsg): ExportNotificationTextsMsg = ExportNotificationTexts.withFallbacks(t)

    /** A free-text title (notification text): at most 1024 chars. */
    fun title(name: String, value: String) {
        if (value.length > 1024) fail(name, "too long")
    }

    /** Preview configuration. */
    fun previewConfig(config: PreviewConfigMsg) {
        range("canvasWidth", config.canvasWidth, 2, MAX_SIDE)
        range("canvasHeight", config.canvasHeight, 2, MAX_SIDE)
        fps("fps", config.fps)
    }

    /** A playback loop (half-open plan µs range). */
    fun loop(loop: LoopMsg?) {
        if (loop == null) return
        if (loop.startUs < 0 || loop.endUs <= loop.startUs) fail("loop", "empty or negative range")
    }

    /** Editing mode: crop source and matte need an item. */
    fun editingMode(mode: EditingModeMsg) {
        if (mode.kind != EditingModeKindMsg.NORMAL) id("mode.itemId", mode.itemId ?: fail("mode.itemId", "missing"))
    }

    /** Look still specs. */
    fun looks(looks: List<LookSpecMsg>, heightPx: Long) {
        if (looks.isEmpty()) fail("looks", "empty")
        if (looks.size > 64) fail("looks", "too many")
        range("heightPx", heightPx, 1, 4096)
        for (look in looks) {
            id("look.id", look.id)
            mediaUri("look.lutUri", look.lutUri)
            range("look.lutSize", look.lutSize, 2, 65)
            unit("look.intensity", look.intensity)
        }
    }

    /** A thumbnail request. */
    fun thumbnail(request: ThumbnailRequestMsg) {
        media(request.media)
        range("intervalMs", request.intervalMs, 1, 3_600_000)
        range("tileIndex", request.tileIndex, 0, Int.MAX_VALUE.toLong())
        range("heightPx", request.heightPx, 1, 2160)
        range("framesPerTile", request.framesPerTile, 1, 64)
    }

    /** A media job request; output paths must be inside the engine roots. */
    fun job(request: JobRequestMsg, paths: Paths?) {
        media(request.media)
        request.audioStream?.let { range("audioStream", it, 0, 64) }
        when (request.kind) {
            JobKindMsg.WAVEFORM, JobKindMsg.PROXY -> Unit
            JobKindMsg.REVERSE, JobKindMsg.SPEECH_AUDIO -> {
                val start = request.sourceStartUs ?: fail("sourceStartUs", "missing")
                val end = request.sourceEndUs ?: fail("sourceEndUs", "missing")
                if (start < 0 || end <= start) fail("sourceRange", "empty or negative range")
                output("outputPath", request.outputPath, paths)
            }
            JobKindMsg.FREEZE -> {
                val t = request.sourceTimeUs ?: fail("sourceTimeUs", "missing")
                if (t < 0) fail("sourceTimeUs", "negative")
                output("outputPath", request.outputPath, paths)
            }
            JobKindMsg.EXPORT -> fail("kind", "exports start through ExportHostApi")
            JobKindMsg.RENDER_PREVIEW -> fail("kind", "render previews are checked by renderPreview")
        }
    }

    /** Most rendered ranges per session (D-45). */
    const val MAX_RENDERED_RANGES = 10_000

    /** `<cache>/renders` of [paths] (D-45). */
    fun rendersDir(paths: Paths): File = File(paths.cacheRoot, "renders")

    /** A file strictly inside `<cache>/renders/`; `permissionDenied` outside it. */
    fun renderFile(name: String, path: String, paths: Paths?): File {
        val roots = paths ?: throw EngineErrors.notInitialized()
        val file = Paths.normalize(path) ?: fail(name, "not an absolute path")
        val dir = rendersDir(roots)
        if (!Paths.isInside(file, dir)) throw EngineException(EngineErrorCode.permissionDenied, "$name is outside the renders directory")
        if (Paths.isInside(dir, file)) fail(name, "is the renders directory itself")
        return file
    }

    /** A `renderPreview` job request: the range plan payload and an output inside `<cache>/renders/`. */
    fun renderPreview(request: JobRequestMsg, paths: Paths?): Pair<ByteArray, String> {
        if (request.kind != JobKindMsg.RENDER_PREVIEW) fail("kind", "not a renderPreview request")
        val plan = request.plan ?: throw EngineErrors.invalidPlan("plan is missing")
        planBytes("plan", plan)
        val output = request.outputPath ?: fail("outputPath", "missing")
        renderFile("outputPath", output, paths)
        return plan to output
    }

    /** `setRenderedRanges`: non-empty, sorted, non-overlapping ranges with a hash and a file in `<cache>/renders/`. */
    fun renderedRanges(ranges: List<RenderedRangeMsg>, paths: Paths?) {
        if (ranges.size > MAX_RENDERED_RANGES) fail("ranges", "too many")
        var previousEnd = 0L
        ranges.forEachIndexed { i, r ->
            if (r.startUs < 0 || r.endUs <= r.startUs) throw EngineErrors.invalidPlan("ranges[$i] is empty or negative")
            if (r.startUs < previousEnd) throw EngineErrors.invalidPlan("ranges[$i] overlaps or is not sorted")
            previousEnd = r.endUs
            id("ranges[$i].hash", r.hash)
            if (!r.uri.startsWith("file://") && !r.uri.startsWith("/")) fail("ranges[$i].uri", "not a file URI")
            renderFile("ranges[$i].uri", r.uri, paths)
        }
    }

    /** Encode settings (sanity only; AND-11 clamps to capabilities). */
    fun settings(s: EncodeSettingsMsg) {
        range("settings.width", s.width, 2, MAX_SIDE)
        range("settings.height", s.height, 2, MAX_SIDE)
        fps("settings.fps", s.fps)
        range("settings.videoBitrate", s.videoBitrate, 1, 1_000_000_000)
        range("settings.audioBitrate", s.audioBitrate, 1, 10_000_000)
        range("settings.audioSampleRate", s.audioSampleRate, 8_000, 192_000)
        range("settings.audioChannels", s.audioChannels, 1, 8)
        range("settings.keyframeIntervalMs", s.keyframeIntervalMs, 1, 600_000)
    }

    /** Backup exclusion is allowed only inside the editor and speech roots (D-44). */
    fun backupDir(path: String, paths: Paths?) {
        absolutePath("path", path)
        val roots = paths ?: throw EngineErrors.notInitialized()
        if (!roots.isEditorOrSpeechPath(path)) {
            throw EngineException(EngineErrorCode.permissionDenied, "path is outside the editor and speech roots")
        }
    }
}
