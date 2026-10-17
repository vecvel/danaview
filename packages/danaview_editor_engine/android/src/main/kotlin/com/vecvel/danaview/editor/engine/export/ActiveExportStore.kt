// OWNER: AND-11
//
// Persistent export job records (ARCH §12.4 activeJobs, §14.1 step 7, D-22, D-39). One JSON file per
// engine cache root, `<cache>/danaview/editor/export-jobs.json` (outside work/, so the launch wipe
// never touches it), written atomically (temp file + rename) under a per-file lock. Format v1:
//
//   { "v": 1, "jobs": [ {
//       "id": "ex_…",                    job id (ExportCoordinator)
//       "state": "running" | "interrupted" | "completedWhileDetached",
//       "process": "<token>",            the writing process (random per process, PROCESS_TOKEN)
//       "output": "<absolute path>",     the export's output file (inside the engine roots)
//       "whenDetached": "saveToGallery" | "keepForLater",
//       "settings": { container, codec, width, height, fps, videoBitrate, audioBitrate,
//                     audioSampleRate, audioChannels, keyframeIntervalMs, stripLocation },
//       "result": { path, bytes, durationUs, videoEncoderName, hardwareEncoder },   (completed only)
//       "savedToGallery": false, "savedUri": "content://…" | absent,               (completed only)
//       "updatedMs": <epoch ms> } ] }
//
// Life cycle (ExportCoordinator unless noted):
// - start: `begin` → running (this process's token).
// - completion with a Dart listener, failure, cancel: `finish` removes the record (Dart got the
//   terminal event).
// - completion without a Dart listener (D-39): `recordCompletedWhileDetached` (by the coordinator's
//   default handler, or AND-12's ExportService after its MediaStore handoff) → a one-shot record.
// - AND-12's API 35 onTimeout: `markInterrupted` (through ExportCoordinator.interrupt).
// - process death: a running record written by another process token is no longer running; the
//   next `records()` turns it into `interrupted` (persisted) and reports it once until `consume`.
// - `consume(jobId)` removes a one-shot record (interrupted or completedWhileDetached); a running
//   record is never consumed. One-shot records older than 7 days are dropped (the D-39 output
//   exemption ends at the same time, DiskCache.WorkExemptions).
// No titles or other user content are stored; paths stay in the app's private cache.

package com.vecvel.danaview.editor.engine.export

import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.pigeon.DetachedHandoffMsg
import com.vecvel.danaview.editor.engine.pigeon.EncodeSettingsMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportContainerMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportJobRecordMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportJobStateKindMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportResultMsg
import com.vecvel.danaview.editor.engine.pigeon.VideoCodecMsg
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.UUID

/** Persistent export job records (file header). Thread-safe. */
class ActiveExportStore(
    /** The JSON file (normally `<cacheRoot>/export-jobs.json`). */
    val file: File,
    /** This process's token; records of other tokens in state running are interrupted. */
    private val processToken: String = PROCESS_TOKEN,
    private val nowMs: () -> Long = System::currentTimeMillis,
) {
    /** Persisted record states. */
    enum class State(val wire: String) {
        RUNNING("running"),
        INTERRUPTED("interrupted"),
        COMPLETED_WHILE_DETACHED("completedWhileDetached"),
        ;

        companion object {
            fun of(wire: String): State? = entries.firstOrNull { it.wire == wire }
        }
    }

    /** One record. */
    data class Record(
        val jobId: String,
        val state: State,
        val process: String,
        val output: String,
        val whenDetached: DetachedHandoffMsg,
        val settings: EncodeSettingsMsg?,
        val result: ExportResultMsg? = null,
        val savedToGallery: Boolean = false,
        val savedUri: String? = null,
        val updatedMs: Long,
    ) {
        /** The record as `ExportHostApi.activeJobs` reports it. */
        fun toMsg(): ExportJobRecordMsg = ExportJobRecordMsg(
            jobId = jobId,
            state = when (state) {
                State.RUNNING -> ExportJobStateKindMsg.RUNNING
                State.INTERRUPTED -> ExportJobStateKindMsg.INTERRUPTED
                State.COMPLETED_WHILE_DETACHED -> ExportJobStateKindMsg.COMPLETED_WHILE_DETACHED
            },
            result = if (state == State.COMPLETED_WHILE_DETACHED) result else null,
            savedToGallery = state == State.COMPLETED_WHILE_DETACHED && savedToGallery,
            savedUri = if (state == State.COMPLETED_WHILE_DETACHED) savedUri else null,
            settings = settings,
        )
    }

    private val lock: Any = synchronized(LOCKS) { LOCKS.getOrPut(file.absoluteFile.invariantSeparatorsPath) { Any() } }

    /** Records a started job (running, this process). */
    fun begin(jobId: String, output: File, settings: EncodeSettingsMsg?, whenDetached: DetachedHandoffMsg) = update { jobs ->
        jobs.removeAll { it.jobId == jobId }
        jobs += Record(jobId, State.RUNNING, processToken, output.absolutePath, whenDetached, settings, updatedMs = nowMs())
    }

    /** Removes the running record of [jobId] (the terminal event reached Dart). One-shot records stay. */
    fun finish(jobId: String) = update { jobs -> jobs.removeAll { it.jobId == jobId && it.state == State.RUNNING } }

    /** Turns [jobId] into a one-shot interrupted record (API 35 onTimeout, AND-12). */
    fun markInterrupted(jobId: String) = update { jobs ->
        val i = jobs.indexOfFirst { it.jobId == jobId }
        if (i >= 0) jobs[i] = jobs[i].copy(state = State.INTERRUPTED, result = null, updatedMs = nowMs())
    }

    /**
     * Records that [jobId] completed with no Dart listener (D-39): [result] describes the kept file
     * (null when the file is gone, e.g. moved into the gallery), [savedUri] the gallery item. Called
     * by ExportCoordinator's default handler or by AND-12's ExportService. A job without a running
     * record gets a new one (output from [result]).
     */
    fun recordCompletedWhileDetached(jobId: String, result: ExportResultMsg?, savedToGallery: Boolean, savedUri: String?) = update { jobs ->
        val i = jobs.indexOfFirst { it.jobId == jobId }
        val base = if (i >= 0) jobs[i] else Record(jobId, State.RUNNING, processToken, result?.path.orEmpty(), DetachedHandoffMsg.SAVE_TO_GALLERY, null, updatedMs = nowMs())
        val done = base.copy(state = State.COMPLETED_WHILE_DETACHED, result = result, savedToGallery = savedToGallery, savedUri = savedUri, updatedMs = nowMs())
        if (i >= 0) jobs[i] = done else jobs += done
    }

    /** The record of [jobId], or null. */
    fun record(jobId: String): Record? = synchronized(lock) { reconcile(read()).first.firstOrNull { it.jobId == jobId } }

    /**
     * Every record, after turning running records of dead processes into interrupted ones (which
     * is persisted) and dropping one-shot records older than 7 days.
     */
    fun records(): List<Record> = synchronized(lock) {
        val (jobs, changed) = reconcile(read())
        if (changed) write(jobs)
        jobs
    }

    /** [records] as `activeJobs` messages. */
    fun recordMsgs(): List<ExportJobRecordMsg> = records().map { it.toMsg() }

    /** Removes the one-shot record of [jobId]; returns it (null when there was none). */
    fun consume(jobId: String): Record? = synchronized(lock) {
        val (jobs, _) = reconcile(read())
        val record = jobs.firstOrNull { it.jobId == jobId && it.state != State.RUNNING } ?: return@synchronized null
        jobs.remove(record)
        write(jobs)
        record
    }

    private fun update(block: (MutableList<Record>) -> Unit) = synchronized(lock) {
        val jobs = reconcile(read()).first
        block(jobs)
        write(jobs)
    }

    private fun reconcile(jobs: MutableList<Record>): Pair<MutableList<Record>, Boolean> {
        var changed = false
        val now = nowMs()
        val out = ArrayList<Record>(jobs.size)
        for (r in jobs) {
            if (r.state != State.RUNNING && now - r.updatedMs > ONE_SHOT_LIFETIME_MS) {
                changed = true
                continue
            }
            if (r.state == State.RUNNING && r.process != processToken) {
                out += r.copy(state = State.INTERRUPTED, updatedMs = now)
                changed = true
            } else {
                out += r
            }
        }
        return out to changed
    }

    private fun read(): MutableList<Record> {
        if (!file.isFile) return ArrayList()
        return try {
            val root = JSONObject(file.readText())
            if (root.optInt("v", 0) != VERSION) return ArrayList()
            val array = root.optJSONArray("jobs") ?: return ArrayList()
            val out = ArrayList<Record>()
            for (i in 0 until array.length()) decode(array.optJSONObject(i))?.let { out += it }
            out
        } catch (e: JSONException) {
            ArrayList()
        } catch (e: IOException) {
            ArrayList()
        }
    }

    private fun write(jobs: List<Record>) {
        val root = JSONObject().put("v", VERSION).put("jobs", JSONArray().apply { jobs.forEach { put(encode(it)) } })
        val dir = file.absoluteFile.parentFile ?: return
        dir.mkdirs()
        val temp = File(dir, ".${file.name}.tmp")
        try {
            temp.writeText(root.toString())
            if (!temp.renameTo(file)) {
                file.delete()
                if (!temp.renameTo(file)) temp.delete()
            }
        } catch (e: IOException) {
            temp.delete()
        }
    }

    companion object {
        /** File name under the cache root. */
        const val FILE_NAME = "export-jobs.json"

        /** Format version. */
        const val VERSION = 1

        /** One-shot records live 7 days (D-39). */
        const val ONE_SHOT_LIFETIME_MS = 7L * 24 * 3600 * 1000

        /** This process's token (a new random value in every process). */
        val PROCESS_TOKEN: String = UUID.randomUUID().toString()

        private val LOCKS = HashMap<String, Any>()

        /** The store of [paths] (`<cacheRoot>/export-jobs.json`). */
        fun of(paths: Paths): ActiveExportStore = ActiveExportStore(File(paths.cacheRoot, FILE_NAME))

        // ---- JSON ----

        internal fun encode(r: Record): JSONObject = JSONObject()
            .put("id", r.jobId)
            .put("state", r.state.wire)
            .put("process", r.process)
            .put("output", r.output)
            .put("whenDetached", if (r.whenDetached == DetachedHandoffMsg.KEEP_FOR_LATER) "keepForLater" else "saveToGallery")
            .put("updatedMs", r.updatedMs)
            .put("savedToGallery", r.savedToGallery)
            .apply {
                r.settings?.let { put("settings", encodeSettings(it)) }
                r.result?.let { put("result", encodeResult(it)) }
                r.savedUri?.let { put("savedUri", it) }
            }

        internal fun decode(o: JSONObject?): Record? {
            if (o == null) return null
            val id = o.optString("id").ifEmpty { return null }
            val state = State.of(o.optString("state")) ?: return null
            return try {
                Record(
                    jobId = id,
                    state = state,
                    process = o.optString("process"),
                    output = o.optString("output"),
                    whenDetached = if (o.optString("whenDetached") == "keepForLater") DetachedHandoffMsg.KEEP_FOR_LATER else DetachedHandoffMsg.SAVE_TO_GALLERY,
                    settings = o.optJSONObject("settings")?.let(::decodeSettings),
                    result = o.optJSONObject("result")?.let(::decodeResult),
                    savedToGallery = o.optBoolean("savedToGallery", false),
                    savedUri = if (o.has("savedUri")) o.optString("savedUri").ifEmpty { null } else null,
                    updatedMs = o.optLong("updatedMs", 0L),
                )
            } catch (e: JSONException) {
                null
            }
        }

        private fun encodeSettings(s: EncodeSettingsMsg): JSONObject = JSONObject()
            .put("container", if (s.container == ExportContainerMsg.MOV) "mov" else "mp4")
            .put("codec", if (s.codec == VideoCodecMsg.HEVC) "hevc" else "h264")
            .put("width", s.width)
            .put("height", s.height)
            .put("fps", s.fps)
            .put("videoBitrate", s.videoBitrate)
            .put("audioBitrate", s.audioBitrate)
            .put("audioSampleRate", s.audioSampleRate)
            .put("audioChannels", s.audioChannels)
            .put("keyframeIntervalMs", s.keyframeIntervalMs)
            .put("stripLocation", s.stripLocation)

        private fun decodeSettings(o: JSONObject): EncodeSettingsMsg = EncodeSettingsMsg(
            container = if (o.getString("container") == "mov") ExportContainerMsg.MOV else ExportContainerMsg.MP4,
            codec = if (o.getString("codec") == "hevc") VideoCodecMsg.HEVC else VideoCodecMsg.H264,
            width = o.getLong("width"),
            height = o.getLong("height"),
            fps = o.getLong("fps"),
            videoBitrate = o.getLong("videoBitrate"),
            audioBitrate = o.getLong("audioBitrate"),
            audioSampleRate = o.getLong("audioSampleRate"),
            audioChannels = o.getLong("audioChannels"),
            keyframeIntervalMs = o.getLong("keyframeIntervalMs"),
            stripLocation = o.getBoolean("stripLocation"),
        )

        private fun encodeResult(r: ExportResultMsg): JSONObject = JSONObject()
            .put("path", r.path)
            .put("bytes", r.bytes)
            .put("durationUs", r.durationUs)
            .put("videoEncoderName", r.videoEncoderName)
            .put("hardwareEncoder", r.hardwareEncoder)

        private fun decodeResult(o: JSONObject): ExportResultMsg = ExportResultMsg(
            path = o.getString("path"),
            bytes = o.getLong("bytes"),
            durationUs = o.getLong("durationUs"),
            videoEncoderName = o.getString("videoEncoderName"),
            hardwareEncoder = o.getBoolean("hardwareEncoder"),
        )
    }
}
